Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Prompt for arbitrary input and return the response.
function Read-Prompt {
  param(
    [Parameter(Mandatory = $true)][string]$Message
  )
  Read-Host -Prompt $Message
}

# Yes/no confirmation. Returns $true on yes, $false otherwise.
function Confirm-Action {
  param(
    [string]$Message = "Proceed?"
  )
  $response = Read-Host -Prompt "$Message [y/N]"
  return $response -match '^(?i:y(es)?)$'
}

# Info message to stdout.
function Write-Info {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  Write-Host "[INFO] $($Message -join ' ')"
}

# Warning message to stderr with standard formatting.
function Write-Warn {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  Write-Warning ($Message -join ' ')
}

# Prompt with optional default value.
function Prompt-Value {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Default = $null
  )

  $prompt = if ($null -ne $Default -and $Default -ne '') { "$Message [$Default]" } else { $Message }
  $input = Read-Host -Prompt $prompt
  if ([string]::IsNullOrWhiteSpace($input) -and $null -ne $Default) { return $Default }
  return $input
}
