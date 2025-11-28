Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'ssh.ps1')
. (Join-Path $PSScriptRoot 'lib' 'ui.ps1')

function Read-Secret {
  param([Parameter(Mandatory = $true)][string]$Prompt)
  Write-Info "$Prompt"
  Write-Host -NoNewline '> '
  $builder = [System.Text.StringBuilder]::new()
  while ($true) {
    $key = [System.Console]::ReadKey($true)
    if ($key.Key -eq 'Enter') { break }
    if ($key.Key -eq 'Backspace') {
      if ($builder.Length -gt 0) {
        $builder.Length -= 1
        Write-Host -NoNewline "`b `b"
      }
      continue
    }
    $null = $builder.Append($key.KeyChar)
    Write-Host -NoNewline '*'
  }
  Write-Host
  return $builder.ToString()
}

function Escape-SingleQuote {
  param([Parameter(Mandatory = $true)][string]$Text)
  $replacement = '''"''"'''   # literal 5 chars: ' " ' " '
  return $Text -replace "'", $replacement
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

  Write-Host "Installing public key to $User@$Server (password auth will be prompted once)..."
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

# 1) Check dependencies
Require-Command 'ssh'
Require-Command 'scp'
Require-Command 'ssh-keygen'

# 2) Ask for SSH connection details
$sshhost = Read-Prompt -Message 'SSH host'
$portInput = Prompt-Value -Message 'SSH port' -Default '22'
$port = [int]$portInput
$user = Read-Prompt -Message 'SSH user'
$password = Read-Secret -Prompt 'SSH password (used once; then key auth)'
$remoteDir = Prompt-Value -Message 'Remote deploy directory [/opt/political-dashboard]' -Default '/opt/political-dashboard'

# 3) Ensure keypair locally and install pubkey remotely (one-time password)
$pubKeyPath = Ensure-LocalSshKey
Install-PublicKeyRemote -User $user -Server $sshhost -Port $port -PublicKeyPath $pubKeyPath

# 4) Test SSH connectivity (should use key now)
if (-not (Test-SshConnection -User $user -Server $sshhost -Port $port)) {
  Write-Warn 'SSH connection failed after key install. Aborting.'
  exit 1
}
Write-Info 'SSH connection via key OK.'

# 5) Create/update local .env.deploy
$createEnv = Join-Path $PSScriptRoot 'tasks' 'create_env.ps1'
& $createEnv

# 6) Ask deployment method (placeholder)
$method = Read-Prompt -Message 'Deployment method? [git|rsync|archive]'
Write-Info "Selected method: $method"

# 7) Prepare remote host (idempotent)
$remoteTasksDir = "/tmp/pol-dashboard-tasks"
Invoke-SshScript -User $user -Server $sshhost -Port $port -Script "mkdir -p '$remoteTasksDir'"

$prepScriptPath = Join-Path $PSScriptRoot 'ssh_tasks' 'prepare_remote.sh'
$remotePrepPath = "$remoteTasksDir/prepare_remote.sh"
Copy-RemoteScript -LocalPath $prepScriptPath -RemotePath $remotePrepPath -User $user -Server $sshhost -Port $port

$envAssignments = @(
  "REMOTE_DIR='$(Escape-SingleQuote $remoteDir)'"
  "TARGET_DIR='$(Escape-SingleQuote $remoteDir)'"
  "SUDO='sudo -S'"
) -join ' '

# Provide sudo password via stdin to avoid interactive prompts (sudo -S)
$sudoPwdEscaped = Escape-SingleQuote $password
$remoteCmd = "cd '$remoteTasksDir' && chmod +x 'prepare_remote.sh' && echo '$sudoPwdEscaped' | SUDO='sudo -S' $envAssignments bash 'prepare_remote.sh'"
Invoke-SshScript -User $user -Server $sshhost -Port $port -Script $remoteCmd

Write-Host 'Remote preparation complete.' -ForegroundColor Green
