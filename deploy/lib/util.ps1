Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Throw with a consistent error message format.
function Throw-Die {
  param(
    [string]$Message = "unknown error"
  )
  throw "error: $Message"
}

# Ensure a command is present on PATH.
function Require-Command {
  param(
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Throw-Die "missing required command: $Name"
  }
}
