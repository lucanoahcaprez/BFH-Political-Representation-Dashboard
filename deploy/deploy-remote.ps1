Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib' 'ssh.ps1')


function Read-Secret {
  param([Parameter(Mandatory = $true)][string]$Prompt)
  Write-Host -NoNewline "$Prompt : "
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

# thank you GPT 5.1
function Escape-SingleQuote {
  param([Parameter(Mandatory = $true)][string]$Text)

  $replacement = '''"''"'''   # this is the literal 5 chars: ' " ' " '

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
    [System.IO.File]::WriteAllText($temp, $content, [System.Text.Encoding]::UTF8)
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

# 1) Check dependencies
Require-Command 'ssh'
Require-Command 'scp'

# 2) Ask for SSH connection details
$sshhost = Read-Host -Prompt 'SSH host'
$portInput = Read-Host -Prompt 'SSH port [22]'
if ([string]::IsNullOrWhiteSpace($portInput)) { $port = 22 } else { $port = [int]$portInput }
$user = Read-Host -Prompt 'SSH user'
# $password = Read-Secret -Prompt 'SSH password (not used if keys are set up)'

# 3) Test SSH connectivity
if (-not (Test-SshConnection -User $user -Server $sshhost -Port $port)) {
  Write-Host 'SSH connection failed. Aborting.' -ForegroundColor Red
  exit 1
}
Write-Host 'SSH connection OK.' -ForegroundColor Green

$remoteDir = Read-Host -Prompt 'Remote deploy directory (e.g., /opt/political-dashboard)'
# 4) Create/update local .env.deploy
$createEnv = Join-Path $PSScriptRoot 'tasks' 'create_env.ps1'
& $createEnv

# 5) Ask deployment method (placeholder)
$method = Read-Host -Prompt 'Deployment method? [git|rsync|archive]'
Write-Host "Selected method: $method"

# 6) Prepare remote host (idempotent)
$remoteTasksDir = "/tmp/pol-dashboard-tasks"
Invoke-SshScript -User $user -Server $sshhost -Port $port -Script "mkdir -p '$remoteTasksDir'"

$prepScriptPath = Join-Path $PSScriptRoot 'ssh_tasks' 'prepare_remote.sh'
$remotePrepPath = "$remoteTasksDir/prepare_remote.sh"
Copy-RemoteScript -LocalPath $prepScriptPath -RemotePath $remotePrepPath -User $user -Server $sshhost -Port $port

$envAssignments = @(
  "REMOTE_DIR='$(Escape-SingleQuote $remoteDir)'"
) -join ' '

$remoteCmd = "$envAssignments bash '$remotePrepPath'"
Invoke-SshScript -User $user -Server $sshhost -Port $port -Script $remoteCmd

Write-Host 'Remote preparation complete.' -ForegroundColor Green
