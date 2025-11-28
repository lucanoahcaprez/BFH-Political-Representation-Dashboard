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
  Require-Command 'robocopy'

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

  # Prepare staging directory to exclude node_modules before copying.
  $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("deploy-sync-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $staging | Out-Null

  try {
    function Copy-WithExcludeNodeModules {
      param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
      )

      # TODO: Explain why we used robocopy
      New-Item -ItemType Directory -Path $Destination -Force | Out-Null
      $args = @($Source, $Destination, '/MIR', '/XD', 'node_modules')
      $proc = Start-Process -FilePath 'robocopy' -ArgumentList $args -NoNewWindow -Wait -PassThru
      # Robocopy exit codes: 0-7 are success/acceptable, >7 indicate failure.
      if ($proc.ExitCode -gt 7) {
        Throw-Die "robocopy failed ($($proc.ExitCode)) while copying $Source"
      }
    }

    Copy-WithExcludeNodeModules -Source (Join-Path $localRoot 'backend') -Destination (Join-Path $staging 'backend')
    Copy-WithExcludeNodeModules -Source (Join-Path $localRoot 'frontend') -Destination (Join-Path $staging 'frontend')
    Copy-Item -Path (Join-Path $localRoot 'docker-compose.yml') -Destination $staging -Force
    Copy-Item -Path (Join-Path $localRoot 'docker-compose.prod.yml') -Destination $staging -Force
    Copy-Item -Path (Join-Path $localRoot '.env.deploy') -Destination $staging -Force

    $destination = "$sshTarget`:$remoteDir/"
    $scpArgs = @(
      '-P', $Context.Port,
      '-o', 'StrictHostKeyChecking=accept-new',
      '-r',
      (Join-Path $staging 'backend'),
      (Join-Path $staging 'frontend'),
      (Join-Path $staging 'docker-compose.yml'),
      (Join-Path $staging 'docker-compose.prod.yml'),
      (Join-Path $staging '.env.deploy'),
      $destination
    )

    $proc = Start-Process -FilePath 'scp' -ArgumentList $scpArgs -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
      Throw-Die "scp exited with code $($proc.ExitCode)"
    }

    Write-Success "Copied project assets (excluding node_modules) to $destination"
  }
  finally {
    if (Test-Path $staging) {
      Remove-Item -Recurse -Force $staging
    }
  }
}
