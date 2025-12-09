Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Throw with a consistent error message format.
function New-Error {
  param(
    [string]$Message = "unknown error"
  )
  throw "error: $Message"
}

# Ensure a command is present on PATH.
function Test-Command {
  param(
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    New-Error "missing required command: $Name"
  }
}


# read env values

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

# ensure local ssh key
function Test-LocalSshKey {
  $keyPath = Join-Path $HOME '.ssh\id_ed25519'
  if (-not (Test-Path $keyPath)) {
    Write-Host "Generating SSH key at $keyPath"
    ssh-keygen -t ed25519 -N '' -f $keyPath | Out-Null
  }
  return "$keyPath.pub"
}
