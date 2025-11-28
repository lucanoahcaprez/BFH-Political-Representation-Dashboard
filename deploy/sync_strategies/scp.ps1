Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\lib\ui.ps1')
. (Join-Path $PSScriptRoot '..\lib\util.ps1')

function Get-DefaultLocalRoot {
  param([Parameter(Mandatory = $true)][string]$DeployRoot)

  $candidate = $DeployRoot
  $composeHere = Join-Path $candidate 'docker-compose.yml'
  if (-not (Test-Path $composeHere)) {
    $parent = Split-Path -Parent $candidate
    $composeParent = Join-Path $parent 'docker-compose.yml'
    if (Test-Path $composeParent) {
      $candidate = $parent
    }
  }

  return $candidate
}

function Invoke-SyncStrategy {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Context
  )

  Require-Command 'scp'

  $defaultRoot = Get-DefaultLocalRoot -DeployRoot $Context.DeployRoot
  $localRoot = $null
  do {
    $input = Read-Value -Message 'Local project root' -Default $defaultRoot
    if (-not (Test-Path $input)) {
      Write-Warn "Path not found: $input"
      continue
    }

    $resolved = (Resolve-Path $input).ProviderPath
    $compose = Join-Path $resolved 'docker-compose.yml'
    if (-not (Test-Path $compose)) {
      Write-Warn "docker-compose.yml not found in $resolved"
      continue
    }

    $localRoot = $resolved
  } until ($localRoot)

  $requiredItems = @('backend', 'frontend', 'docker-compose.yml', 'docker-compose.prod.yml', '.env.deploy')
  foreach ($item in $requiredItems) {
    $path = Join-Path $localRoot $item
    if (-not (Test-Path $path)) {
      Throw-Die "Required item missing at $path"
    }
  }

  $remoteDir = $Context.RemoteDir
  $sshTarget = "$($Context.User)@$($Context.Server)"

  # Ensure remote directory exists before copying.
  $mkdirArgs = @(
    '-p', $Context.Port,
    '-o', 'StrictHostKeyChecking=accept-new',
    $sshTarget,
    "mkdir -p '$remoteDir'"
  )
  $mkdirProc = Start-Process -FilePath 'ssh' -ArgumentList $mkdirArgs -NoNewWindow -Wait -PassThru
  if ($mkdirProc.ExitCode -ne 0) {
    Throw-Die "ssh mkdir failed with code $($mkdirProc.ExitCode)"
  }

  $destination = "$sshTarget`:$remoteDir/"
  $scpArgs = @(
    '-P', $Context.Port,
    '-o', 'StrictHostKeyChecking=accept-new',
    '-r',
    (Join-Path $localRoot 'backend'),
    (Join-Path $localRoot 'frontend'),
    (Join-Path $localRoot 'docker-compose.yml'),
    (Join-Path $localRoot 'docker-compose.prod.yml'),
    (Join-Path $localRoot '.env.deploy'),
    $destination
  )

  $proc = Start-Process -FilePath 'scp' -ArgumentList $scpArgs -NoNewWindow -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    Throw-Die "scp exited with code $($proc.ExitCode)"
  }

  Write-Success "Copied project assets to $destination"
}
