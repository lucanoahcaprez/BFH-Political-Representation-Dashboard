Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import helper modules (compatible with Windows PowerShell 5.1 and PowerShell 7)
. (Join-Path $PSScriptRoot 'lib\ssh.ps1')
. (Join-Path $PSScriptRoot 'lib\ui.ps1')

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir ("deploy-remote-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Set-UiLogFile -Path $logFile
Set-UiInfoVisibility -Visible:$false
Write-Success "Logging deployment details to $logFile"

function Escape-SingleQuote {
  param([Parameter(Mandatory = $true)][string]$Text)
  $replacement = '''"''"'''   # literal 5 chars: ' " ' " '
  return $Text -replace "'", $replacement
}

function Read-EnvDeployValues {
  param([Parameter(Mandatory = $true)][string]$Path)
  $result = @{}
  if (-not (Test-Path $Path)) { return $result }
  foreach ($line in Get-Content -Path $Path) {
    if ($line -match '^\s*$' -or $line -match '^\s*#') { continue }
    $parts = $line.Split('=', 2, [System.StringSplitOptions]::None)
    if ($parts.Count -eq 2) {
      $key = $parts[0].Trim()
      $val = $parts[1].Trim()
      if ($key) { $result[$key] = $val }
    }
  }
  return $result
}

function Get-AppUrl {
  param(
    [hashtable]$EnvValues,
    [string]$DefaultFrontendPort = '8080',
    [string]$Server = $null
  )

  $domain = $EnvValues['APP_DOMAIN']
  $frontendPort = if ($EnvValues.ContainsKey('FRONTEND_PORT')) { $EnvValues['FRONTEND_PORT'] } else { $DefaultFrontendPort }

  if ([string]::IsNullOrWhiteSpace($domain) -or $domain -eq 'localhost') {
    if (-not [string]::IsNullOrWhiteSpace($Server)) {
      return "http://$Server`:$frontendPort"
    }
    return "http://localhost:$frontendPort"
  }
  return "https://$domain"
}

function Get-RemoteScript {
  param([Parameter(Mandatory = $true)][string]$Path)
  $raw = Get-Content -Path $Path -Raw -Encoding UTF8
  return $raw -replace "`r`n", "`n"
}

function Copy-RemoteScript {
  param(
    [Parameter(Mandatory = $true)][string]$LocalPath,
    [Parameter(Mandatory = $true)][string]$RemotePath,
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22
  )

  $temp = [System.IO.Path]::GetTempFileName()
  try {
    $content = Get-RemoteScript -Path $LocalPath
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($temp, $content, $utf8NoBom)
    $args = @(
      '-P', $Port,
      '-o', 'StrictHostKeyChecking=accept-new',
      $temp,
      "$User@$Server`:$RemotePath"
    )
    $proc = Start-Process -FilePath 'scp' -ArgumentList $args -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
      Throw-Die "scp exited with code $($proc.ExitCode)"
    }
  } finally {
    if (Test-Path $temp) { Remove-Item $temp -Force }
  }
}

function Ensure-LocalSshKey {
  $keyPath = Join-Path $HOME '.ssh\id_ed25519'
  if (-not (Test-Path $keyPath)) {
    Write-Host "Generating SSH key at $keyPath"
    ssh-keygen -t ed25519 -N '' -f $keyPath | Out-Null
  }
  return "$keyPath.pub"
}

function Install-PublicKeyRemote {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [Parameter(Mandatory = $true)][string]$PublicKeyPath
  )

  $pubKey = (Get-Content -Path $PublicKeyPath -Raw).TrimEnd("`r","`n")
  $escapedPub = $pubKey.Replace("'", "''")
  $remoteCmd = @"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
grep -qxF '$escapedPub' ~/.ssh/authorized_keys || echo '$escapedPub' >> ~/.ssh/authorized_keys
"@

  $args = @(
    '-p', $Port,
    '-o', 'PreferredAuthentications=password',
    '-o', 'PubkeyAuthentication=no',
    '-o', 'StrictHostKeyChecking=accept-new',
    "$User@$Server",
    $remoteCmd
  )
  $proc = Start-Process -FilePath 'ssh' -ArgumentList $args -NoNewWindow -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    Throw-Die "failed to install SSH key (ssh exited with $($proc.ExitCode))"
  }
}

function Invoke-DeploymentSync {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][hashtable]$Context
  )

  $strategyPath = Join-Path $PSScriptRoot "sync_strategies\$Method.ps1"
  if (-not (Test-Path $strategyPath)) {
    Throw-Die "Unsupported deployment method '$Method' (missing $strategyPath)"
  }

  # Remove any previously loaded strategy entrypoint to avoid stale definitions.
  if (Get-Command -Name 'Invoke-SyncStrategy' -CommandType Function -ErrorAction SilentlyContinue) {
    Remove-Item "function:Invoke-SyncStrategy" -ErrorAction SilentlyContinue
  }

  . $strategyPath

  $strategyFn = Get-Command -Name 'Invoke-SyncStrategy' -CommandType Function -ErrorAction SilentlyContinue
  if (-not $strategyFn) {
    Throw-Die "Sync strategy '$Method' missing entrypoint Invoke-SyncStrategy"
  }

  Invoke-SyncStrategy -Context $Context
}

# 1) Check dependencies
Write-Info "Checking dependency on $ENV:COMPUTERNAME"
Require-Command 'ssh'
Require-Command 'scp'
Require-Command 'ssh-keygen'

# 2) Ask for SSH connection details
Write-Info "Read connection details for ssh"
$sshhost = Read-Value -Message 'SSH host'
$portInput = Read-Value -Message 'SSH port' -Default '22'
$port = [int]$portInput
$user = Read-Value -Message 'SSH user'

# 3) Ensure keypair locally and install pubkey remotely (one-time password)
Write-Info "Ensure local sshkey is present"
$pubKeyPath = Ensure-LocalSshKey
Write-Info "Try to install public-key on $sshhost"
Install-PublicKeyRemote -User $user -Server $sshhost -Port $port -PublicKeyPath $pubKeyPath

# 4) Test SSH connectivity (should use key now)
Write-Info 'Testing ssh connection with key'
if (-not (Test-SshConnection -User $user -Server $sshhost -Port $port)) {
  Write-Warn 'SSH connection failed after key install. Aborting.'
  exit 1
}
Write-Success 'SSH connection with key OK.'

# 5) Prompt for further informations
Write-Info 'Prompting for further informations'
do {
$sudoPassword = Read-Secret -Message 'SUDO password'
  if ([string]::IsNullOrWhiteSpace($sudoPassword)) {
    Write-Warn 'Password cannot be empty. Please enter a value.'
  }
} until (-not [string]::IsNullOrWhiteSpace($sudoPassword))
$remoteDir = Read-Value -Message 'Remote deploy directory [/opt/political-dashboard]' -Default '/opt/political-dashboard'


# 6) Create/update local .env.deploy
Write-Info 'Gather input for creation of .env.deploy'
$useEnvDefaults = Confirm-Action -Message 'Use default environment values (ports 8080/3000/5432, postgres user, empty domain)?'
$createEnv = Join-Path $PSScriptRoot 'tasks\create_env.ps1'
$global:EnvFile = & $createEnv -UseDefaults:$useEnvDefaults
$envDeployPath = Join-Path (Get-Location) '.env.deploy'
if (-not (Test-Path $envDeployPath)) {
  # Fallback to script root in case the working directory differs.
  $envDeployPath = Join-Path $PSScriptRoot '.env.deploy'
}
$envValues = Read-EnvDeployValues -Path $envDeployPath

# 7) Ask deployment method (placeholder)
$method = Read-Choice -Message 'Deployment method? [local|git|archive]' -Options @('local', 'git', 'archive')
Write-Info "Selected method: $method"

# 8) Prepare remote host (idempotent)
$remoteTasksDir = "/tmp/pol-dashboard-tasks"
Invoke-SshScript -User $user -Server $sshhost -Port $port -Script "mkdir -p '$remoteTasksDir'"

$prepScriptPath = Join-Path $PSScriptRoot 'ssh_tasks\prepare_remote.sh'
$remotePrepPath = "$remoteTasksDir/prepare_remote.sh"
Copy-RemoteScript -LocalPath $prepScriptPath -RemotePath $remotePrepPath -User $user -Server $sshhost -Port $port
 
$prepEnvAssignments = @(
  "REMOTE_DIR='$(Escape-SingleQuote $remoteDir)'"
  'SUDO=''sudo -S -p ""'''
  "SUDO_PASSWORD='$(Escape-SingleQuote $sudoPassword)'"
) -join ' '

# Provide sudo password via stdin to avoid interactive prompts (sudo -S)
$remoteCmd = "cd '$remoteTasksDir' && chmod +x 'prepare_remote.sh' && $prepEnvAssignments bash 'prepare_remote.sh'"
Invoke-SshScript -User $user -Server $sshhost -Port $port -Script $remoteCmd

Write-Success 'Remote preparation complete.'

# 9) Sync project using selected strategy
$syncContext = @{
  Method     = $method
  User       = $user
  Server     = $sshhost
  Port       = $port
  RemoteDir  = $remoteDir
  DeployRoot = $PSScriptRoot
}
Invoke-DeploymentSync -Method $method -Context $syncContext
Write-Success "Sync via '$method' completed."

# 10) Deploy application on remote host
$deployScriptPath = Join-Path $PSScriptRoot 'ssh_tasks\deploy.sh'
$remoteDeployPath = "$remoteTasksDir/deploy.sh"
Copy-RemoteScript -LocalPath $deployScriptPath -RemotePath $remoteDeployPath -User $user -Server $sshhost -Port $port

$deployEnvAssignments = @(
  "REMOTE_DIR='$(Escape-SingleQuote $remoteDir)'"
  'SUDO=''sudo -S -p ""'''
  "SUDO_PASSWORD='$(Escape-SingleQuote $sudoPassword)'"
) -join ' '

$deployCmd = "cd '$remoteTasksDir' && chmod +x 'deploy.sh' && $deployEnvAssignments bash 'deploy.sh'"
Invoke-SshScript -User $user -Server $sshhost -Port $port -Script $deployCmd
Write-Success 'Remote deploy executed.'

# 11) Surface useful info to the user
$remoteLogDir = '/var/log/political-dashboard'
$appUrl = Get-AppUrl -EnvValues $envValues -Server $sshhost

Write-Success "Local log file: $logFile"
Write-Success "Remote logs: $remoteLogDir/prepare_remote.log, $remoteLogDir/deploy.log (host: $sshhost)"
Write-Success "Application URL: $appUrl"
