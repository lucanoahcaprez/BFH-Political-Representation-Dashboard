[CmdletBinding()]
param(
  [switch]$Shutdown,
  [int]$ConnectTimeoutSeconds = 20,
  [int]$ConnectDelaySeconds = 1
)

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

$remoteTasksDir = "/tmp/pol-dashboard-tasks"
$checkScriptName = 'check_remote_compose.sh'
$shutdownScriptName = 'shutdown_remote_compose.sh'
$checkSudoScriptName = 'check_sudo.sh'

function ConvertTo-EscapedSingleQuote {
  param([Parameter(Mandatory = $true)][string]$Text)
  $replacement = '''"''"'''   # literal 5 chars: ' " ' " '
  return $Text -replace "'", $replacement
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
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20
  )

  $temp = [System.IO.Path]::GetTempFileName()
  try {
    $content = Get-RemoteScript -Path $LocalPath
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($temp, $content, $utf8NoBom)
    $arguments = @(
      '-P', $Port,
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
      $temp,
      "$User@$Server`:$RemotePath"
    )
    $proc = Start-Process -FilePath 'scp' -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
      Throw-Die "scp exited with code $($proc.ExitCode)"
    }
  } finally {
    if (Test-Path $temp) { Remove-Item $temp -Force }
  }
}

function Install-PublicKeyRemote {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
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

  $arguments = @(
    '-p', $Port,
    '-o', 'PreferredAuthentications=password',
    '-o', 'PubkeyAuthentication=no',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
    "$User@$Server",
    $remoteCmd
  )
  $proc = Start-Process -FilePath 'ssh' -ArgumentList $arguments -NoNewWindow -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    $message = "failed to install SSH key (ssh exited with $($proc.ExitCode))"
    Write-Error $message
    Throw-Die $message
  }
}

function Initialize-RemoteTaskScripts {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [Parameter(Mandatory = $true)][string]$RemoteTasksDir,
    [string]$LocalTasksDir = (Join-Path $PSScriptRoot 'ssh_tasks')
  )

  Invoke-SshScript -User $User -Server $Server -Port $Port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script "mkdir -p '$RemoteTasksDir'"

  $scripts = Get-ChildItem -Path $LocalTasksDir -File
  foreach ($script in $scripts) {
    $remotePath = "$RemoteTasksDir/$($script.Name)"
    Copy-RemoteScript -LocalPath $script.FullName -RemotePath $remotePath -User $User -Server $Server -Port $Port -ConnectTimeoutSeconds $ConnectTimeoutSeconds
  }
}

function Test-RemoteComposePresent {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [Parameter(Mandatory = $true)][string]$RemoteTasksDir,
    [Parameter(Mandatory = $true)][string]$RemoteDir
  )

  $checkCmd = "cd '$RemoteTasksDir' && chmod +x '$checkScriptName' && REMOTE_DIR='$(ConvertTo-EscapedSingleQuote $RemoteDir)' bash '$checkScriptName'"
  $output = Invoke-SshScriptOutput -User $User -Server $Server -Port $Port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $checkCmd
  return ($output -match 'present')
}

function Stop-RemoteCompose {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [Parameter(Mandatory = $true)][string]$RemoteTasksDir,
    [Parameter(Mandatory = $true)][string]$RemoteDir,
    [string]$SudoCmd = $null,
    [string]$SudoPassword = $null
  )

  $envAssignments = @("REMOTE_DIR='$(ConvertTo-EscapedSingleQuote $RemoteDir)'")
  if ($SudoCmd) { $envAssignments += "SUDO_CMD='$(ConvertTo-EscapedSingleQuote $SudoCmd)'" }
  if ($SudoPassword) { $envAssignments += "SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $SudoPassword)'" }
  $envPrefix = $envAssignments -join ' '
  $shutdownCmd = "cd '$RemoteTasksDir' && chmod +x '$shutdownScriptName' && $envPrefix bash '$shutdownScriptName'"
  Invoke-SshScript -User $User -Server $Server -Port $Port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $shutdownCmd
}

function Test-RemoteSudo {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [Parameter(Mandatory = $true)][string]$RemoteTasksDir,
    [Parameter(Mandatory = $true)][string]$SudoPassword,
    [int]$MaxAttempts = 3
  )

  $password = $SudoPassword
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $envAssignments = @("SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $password)'") -join ' '
    $cmd = "cd '$RemoteTasksDir' && chmod +x '$checkSudoScriptName' && $envAssignments bash '$checkSudoScriptName'"
    $result = Invoke-SshScriptOutput -User $User -Server $Server -Port $Port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $cmd

    if ($result -match '^ok:') {
      return $password
    }

    if ($result -match 'not_in_sudoers') {
      Write-Error 'User is not in sudoers. Aborting.'
      exit 1
    }
    if ($result -match 'missing_sudo') {
      Write-Error 'sudo is not available on the remote host. Aborting.'
      exit 1
    }

    if ($result -match 'bad_password') {
      if ($attempt -lt $MaxAttempts) {
        Write-Warn 'Incorrect sudo password. Please try again.'
        $password = Read-Secret -Message 'SUDO password'
        continue
      }
      Write-Error 'Incorrect sudo password. Aborting.'
      exit 1
    }
    if ($result -match 'missing_password') {
      Write-Error 'Sudo password missing. Aborting.'
      exit 1
    }

    Write-Error "Failed to validate sudo access (remote reported: $result). Aborting."
    exit 1
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
Install-PublicKeyRemote -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -PublicKeyPath $pubKeyPath


# 4) Test SSH connectivity (should use key now)
Write-Info 'Testing ssh connection with key'
if (-not (Test-SshConnection -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds)) {
  Write-Error 'SSH connection failed after key install. Aborting.'
  exit 1
}

Write-Success 'SSH connection with key OK.'

# 5) Copy all necesarry remote task scripts
Write-Info "Create remote task directory ($remoteTasksDir)"
Invoke-SshScript -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script "mkdir -p '$remoteTasksDir'"
Write-Info "Copy remote tasks to $remoteTasksDir"
Initialize-RemoteTaskScripts -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir


# 6) Prompt for further informations
Write-Info 'Prompting for further informations'
do {
  $sudoPassword = Read-Secret -Message 'SUDO password'
  if ([string]::IsNullOrWhiteSpace($sudoPassword)) {
    Write-Warn 'Password cannot be empty. Please enter a value.'
  }
} until (-not [string]::IsNullOrWhiteSpace($sudoPassword))
$sudoPassword = Test-RemoteSudo -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir -SudoPassword $sudoPassword
Write-Success "SUDO password ok."

# 7) Prompt for remote directory and optional shutdown
$remoteDir = Read-Value -Message 'Remote deploy directory [/opt/political-dashboard]' -Default '/opt/political-dashboard'

Write-Info "Prepare remote helper directory $remoteTasksDir"

# 8) Check if user wants to shutdown existing docker stack
if ($Shutdown) {
  Write-Info "Checking for existing docker-compose files in $remoteDir"
  $hasCompose = Test-RemoteComposePresent -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir -RemoteDir $remoteDir
  
  if ($hasCompose) {
    Write-Info "Stopping existing docker-compose stack in $remoteDir"
    Stop-RemoteCompose -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir -RemoteDir $remoteDir -SudoPassword $sudoPassword
    Write-Success "Remote docker-compose stack stopped."
    
  } else {
    Write-Info "No docker-compose files found in $remoteDir"
  }
  Write-Success 'Shutdown flag completed. Exiting.'
  exit 0
}


# 9) Create/update local .env.deploy
Write-Info 'Gather input for creation of .env.deploy'
$useEnvDefaults = Confirm-Action -Message 'Use default environment values (ports 8080/3000/5432, postgres user)?'
$createEnv = Join-Path $PSScriptRoot 'tasks\create_env.ps1'
$envFile = & $createEnv -UseDefaults:$useEnvDefaults
$envDeployPath = Join-Path (Get-Location) '.env.deploy'
if (-not (Test-Path $envDeployPath)) {
  # Fallback to script root in case the working directory differs.
  $envDeployPath = Join-Path $PSScriptRoot '.env.deploy'
}
$envValues = Read-EnvDeployValues -Path $envDeployPath

# 10) Ask deployment method (placeholder)
$method = Read-Choice -Message 'Deployment method? [local|git]' -Options @('local', 'git', 'archive')
Write-Info "Selected method: $method"


$hasExistingCompose = Test-RemoteComposePresent -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir -RemoteDir $remoteDir

if ($hasExistingCompose) {
  $action = Read-Choice -Message "Existing docker-compose found in $remoteDir. [redeploy|cancel]" -Options @('redeploy', 'cancel')
  if ($action -eq 'cancel') {
    Write-Warn 'Deployment cancelled by user.'
    exit 0
  }
}

# 11) Prepare remote host
Write-Info 'Prepare remote host'

$prepEnvAssignments = @(
  "REMOTE_DIR='$(ConvertTo-EscapedSingleQuote $remoteDir)'"
  'SUDO=''sudo -S -p ""'''
  "SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $sudoPassword)'"
) -join ' '

# Provide sudo password via stdin to avoid interactive prompts (sudo -S)
$remoteCmd = "cd '$remoteTasksDir' && chmod +x 'prepare_remote.sh' && $prepEnvAssignments bash 'prepare_remote.sh'"
Write-Info "Prepare remote: execute ssh command - $remoteCmd"
Invoke-SshScript -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $remoteCmd
Write-Success 'Remote preparation complete.'


# 12) Sync project using selected strategy
$syncContext = @{
  Method     = $method
  User       = $user
  Server     = $sshhost
  Port       = $port
  RemoteDir  = $remoteDir
  DeployRoot = $PSScriptRoot
  EnvFile    = $envFile
}
Invoke-DeploymentSync -Method $method -Context $syncContext
Write-Success "Sync via '$method' completed."


# 13) Deploy application on remote host
$deployEnvAssignments = @(
  "REMOTE_DIR='$(ConvertTo-EscapedSingleQuote $remoteDir)'"
  'SUDO=''sudo -S -p ""'''
  "SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $sudoPassword)'"
) -join ' '

$deployCmd = "cd '$remoteTasksDir' && chmod +x 'deploy.sh' && $deployEnvAssignments bash 'deploy.sh'"
Invoke-SshScript -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $deployCmd
Write-Success 'Remote deploy executed.'

# 14) Surface useful info to the user
$remoteLogDir = '/var/log/political-dashboard'
$appUrl = Get-AppUrl -EnvValues $envValues -Server $sshhost

Write-Success "Local log file: $logFile"
Write-Success "Remote logs: $remoteLogDir/prepare_remote.log, $remoteLogDir/deploy.log (host: $sshhost)"
Write-Success "Application URL: $appUrl"
