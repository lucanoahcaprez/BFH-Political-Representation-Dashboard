[CmdletBinding()]
param(
  [switch]$Shutdown,
  [int]$ConnectTimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import helper modules (compatible with Windows PowerShell 5.1 and PowerShell 7)
. (Join-Path $PSScriptRoot 'lib\ssh.ps1')
. (Join-Path $PSScriptRoot 'lib\ui.ps1')

function Write-DeployHeader {
  param(
    [string]$LogDir
  )
  $divider = '=' * 68
  $scriptName = Split-Path -Leaf $PSCommandPath
  @"
$divider
  Political Representation Dashboard - Remote Deployment
  Authors : Elia Bucher, Luca Noah Caprez, Pascal Feller (BFH student project)
  License : MIT (see LICENSE)
  Logs    : $LogDir (per-run file announced below)
  Usage   : .\$scriptName [-Shutdown] [-ConnectTimeoutSeconds <int>]
            -Shutdown stops the existing remote docker-compose stack, then exits.
  Steps   :
    1) Check local SSH/scp prerequisites and reachability
    2) Prepare the remote host (helper scripts, packages, Docker)
    3) Sync project files and deployment env vars
    4) Deploy docker-compose and print URLs/log paths
$divider
"@ | Write-Host
}

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$null = Write-DeployHeader -LogDir $logDir
Write-Info 'Starting remote deployment script.'
$logFile = Join-Path $logDir ("deploy-remote-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Set-UiLogFile -Path $logFile
Set-UiInfoVisibility -Visible:$true
Write-Info "Logging to $logFile"

$remoteTasksDir = "/tmp/pol-dashboard-tasks"
$checkScriptName = 'check_remote_compose.sh'
$shutdownScriptName = 'shutdown_remote_compose.sh'
$checkSudoScriptName = 'check_sudo.sh'

function ConvertTo-EscapedSingleQuote {
  param([Parameter(Mandatory = $true)][string]$Text)
  $replacement = '''"''"'''   # literal 5 chars: ' " ' " '
  return $Text -replace "'", $replacement
}

function ConvertFrom-SecureStringPlainText {
  param([System.Security.SecureString]$SecureText)
  if (-not $SecureText) { return $null }
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureText)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
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
      '-q',
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
      $temp,
      "$User@$Server`:$RemotePath"
    )
    $proc = Start-Process -FilePath 'scp' -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
      New-Error "scp exited with code $($proc.ExitCode)"
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
    New-Error $message
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
    [System.Security.SecureString]$SudoPassword = $null
  )

  $envAssignments = @("REMOTE_DIR='$(ConvertTo-EscapedSingleQuote $RemoteDir)'")
  if ($SudoCmd) { $envAssignments += "SUDO_CMD='$(ConvertTo-EscapedSingleQuote $SudoCmd)'" }
  if ($SudoPassword) {
    $plainSudo = ConvertFrom-SecureStringPlainText -SecureText $SudoPassword
    $envAssignments += "SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $plainSudo)'"
  }
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
    [Parameter(Mandatory = $true)][System.Security.SecureString]$SudoPassword,
    [int]$MaxAttempts = 3
  )

  $password = ConvertFrom-SecureStringPlainText -SecureText $SudoPassword
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $envAssignments = @("SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $password)'") -join ' '
    $cmd = "cd '$RemoteTasksDir' && chmod +x '$checkSudoScriptName' && $envAssignments bash '$checkSudoScriptName'"
    $result = Invoke-SshScriptOutput -User $User -Server $Server -Port $Port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $cmd

    if ($result -match '^ok:') {
      return ConvertTo-SecureString $password -AsPlainText -Force
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
    New-Error "Unsupported deployment method '$Method' (missing $strategyPath)"
  }

  # Remove any previously loaded strategy entrypoint to avoid stale definitions.
  if (Get-Command -Name 'Invoke-SyncStrategy' -CommandType Function -ErrorAction SilentlyContinue) {
    Remove-Item "function:Invoke-SyncStrategy" -ErrorAction SilentlyContinue
  }

  . $strategyPath

  $strategyFn = Get-Command -Name 'Invoke-SyncStrategy' -CommandType Function -ErrorAction SilentlyContinue
  if (-not $strategyFn) {
    New-Error "Sync strategy '$Method' missing entrypoint Invoke-SyncStrategy"
  }

  Invoke-SyncStrategy -Context $Context
}

# 1) Check dependencies
Write-Info "check local prerequisites (ssh, scp, ssh-keygen) on $ENV:COMPUTERNAME"
Test-Command 'ssh'
Test-Command 'scp'
Test-Command 'ssh-keygen'

# 2) Ask for SSH connection details
Write-Section "Connection"
$sshhost = Read-RequiredValue -Message 'Remote host (IP or DNS)'
$portInput = Read-Value -Message 'SSH port' -Default '22'
$port = [int]$portInput
$user = Read-RequiredValue -Message 'SSH user (root skips sudo prompts)'
$isRootUser = ($user -eq 'root')

# 3) Try SSH with an existing key first; only install/generate on fallback.
$keyInfo = Test-LocalSshKey
$defaultKeyPath = $keyInfo.PrivatePath
$pubKeyPath = $keyInfo.PublicPath
$hasLocalKey = -not $keyInfo.Generated
$connectedWithKey = $false

if ($hasLocalKey) {
  Write-Info "Testing ssh connection with existing key at $defaultKeyPath"
  $connectedWithKey = Test-SshConnection -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -PublicKeyOnly
}

if (-not $connectedWithKey) {
  Write-Info 'SSH key authentication not available; falling back to password to install key.'
  Write-Info "Ensure local sshkey is present"
  Write-Info "Try to install public-key on $sshhost"
  Install-PublicKeyRemote -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -PublicKeyPath $pubKeyPath

  Write-Info 'Testing ssh connection with key after install'
  if (-not (Test-SshConnection -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -PublicKeyOnly)) {
    Write-Error 'SSH connection failed after key install. Aborting.'
    exit 1
  }
  Write-Success 'SSH connection with key OK.'
} else {
  Write-Success 'SSH connection with existing key OK.'
}

# 5) Copy all necesarry remote task scripts
Write-Info "Creating remote task directory ($remoteTasksDir)"
Invoke-SshScript -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script "mkdir -p '$remoteTasksDir'"
Write-Info "Copy remote tasks to $remoteTasksDir"
Initialize-RemoteTaskScripts -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir


# 6) Prompt for further informations (skip sudo if connecting as root)
$sudoPassword = $null
if (-not $isRootUser) {
  Write-Section "Sudo access"
  Write-Info 'Needed to install packages and manage Docker on the remote host.'
  do {
    $sudoPasswordPlain = Read-Secret -Message 'Remote sudo password'
    if ([string]::IsNullOrWhiteSpace($sudoPasswordPlain)) {
      Write-Warn 'Password cannot be empty. Please enter a value.'
    }
  } until (-not [string]::IsNullOrWhiteSpace($sudoPasswordPlain))
  $sudoPassword = ConvertTo-SecureString $sudoPasswordPlain -AsPlainText -Force
  $sudoPassword = Test-RemoteSudo -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir -SudoPassword $sudoPassword
  Write-Success "SUDO password ok."
} else {
  Write-Info 'Connected as root; skipping sudo password prompt.'
}

# 7) Prompt for remote directory and optional shutdown
Write-Section "Remote target"
Write-Info "Choose remote deploy directory. Thats where your web application files will live. We create the directory for you if it is missing."
$remoteDir = Read-Value -Message 'Remote deploy directory' -Default '/opt/political-dashboard'

Write-Info "Prepare remote helper directory $remoteTasksDir"

# 8) Check if user wants to shutdown existing docker stack
if ($Shutdown) {
  Write-Section "Shutdown"
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
Write-Section "Environment file"
Write-Info "In docker-compose, an environment file centralizes configuration like ports, domains, and credentials so containers stay configurable without editing compose YAML."
Write-Info "We will create .env.deploy locally and copy it alongside the application files on the remote host so the stack reads consistent settings."
Write-Info "Step: Create or confirm deployment environment values (.env.deploy)"
Write-Info "Action: confirm defaults or customize ports/app domain used by docker-compose."
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
# TODO: cleanup dont read the options
# $method = Read-Choice -Message 'Step: Deployment method? [local|git|archive]' -Options @('local', 'git', 'archive')
# Write-Info "Selected method: $method"
$method = "local"

$hasExistingCompose = Test-RemoteComposePresent -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -RemoteTasksDir $remoteTasksDir -RemoteDir $remoteDir

if ($hasExistingCompose) {
  Write-Section "Existing deployment found"
  Write-Info "We found an already existing docker stack in $remoteDir. You can choose if you want to redeploy with the current files or cancel the deployment"
  $action = Read-Choice -Message "Type 'redeploy' or 'cancel'" -Options @('redeploy', 'cancel')
  if ($action -eq 'cancel') {
    Write-Warn 'Deployment cancelled by user.'
    exit 0
  }
}

# 11) Prepare remote host
Write-Section "Prepare remote host"
Write-Info 'Installing prerequisites (docker, docker-compose, curl, git) if necessary'
$sudoPasswordPlain = ConvertFrom-SecureStringPlainText -SecureText $sudoPassword

$prepEnvAssignments = @("REMOTE_DIR='$(ConvertTo-EscapedSingleQuote $remoteDir)'")
if (-not $isRootUser) {
  $prepEnvAssignments += 'SUDO=''sudo -S -p ""'''
  if ($sudoPasswordPlain) {
    $prepEnvAssignments += "SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $sudoPasswordPlain)'"
  }
}
$prepEnvAssignments = $prepEnvAssignments -join ' '

# Provide sudo password via stdin to avoid interactive prompts (sudo -S)
$remoteCmd = "cd '$remoteTasksDir' && chmod +x 'prepare_remote.sh' && $prepEnvAssignments bash 'prepare_remote.sh' > /dev/null 2>&1"
Write-Info "Prepare remote: running prepare_remote.sh quietly (details in $logFile)"
Invoke-SshScript -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $remoteCmd
Write-Success 'Remote preparation complete.'


# 12) Sync project using selected strategy
Write-Section "Sync and deploy"

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
$deployEnvAssignments = @("REMOTE_DIR='$(ConvertTo-EscapedSingleQuote $remoteDir)'")
if (-not $isRootUser) {
  $deployEnvAssignments += 'SUDO=''sudo -S -p ""'''
  if ($sudoPasswordPlain) {
    $deployEnvAssignments += "SUDO_PASSWORD='$(ConvertTo-EscapedSingleQuote $sudoPasswordPlain)'"
  }
}
$deployEnvAssignments = $deployEnvAssignments -join ' '

$deployCmd = "cd '$remoteTasksDir' && chmod +x 'deploy.sh' && $deployEnvAssignments bash 'deploy.sh' > /dev/null 2>&1"
Write-Info "Deploy docker stack on remote machine in $remoteDir"
Invoke-SshScript -User $user -Server $sshhost -Port $port -ConnectTimeoutSeconds $ConnectTimeoutSeconds -Script $deployCmd
Write-Success 'Remote deploy executed.'

# 14) Surface useful info to the user
Write-Section "Summary"
$remoteLogDir = '/var/log/political-dashboard'
$appUrl = Get-AppUrl -EnvValues $envValues -Server $sshhost

Write-Info @"

  Project files  : $sshhost`:$remoteDir
  Remote logs    : $sshhost`:$remoteLogDir/prepare_remote.log and deploy.log
  Local log file : $logFile
  Application    : $appUrl
Rerun this script anytime; use -Shutdown to stop and remove the remote docker-compose stack.
"@
