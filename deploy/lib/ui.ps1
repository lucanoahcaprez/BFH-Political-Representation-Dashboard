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
  Write-Host "[$(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")] [INFO] [$ENV:COMPUTERNAME] $($Message -join ' ')"
}

# success message
function Write-Success {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  Write-Host "[$(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")] [SUCCESS] [$ENV:COMPUTERNAME] $($Message -join ' ')" -ForegroundColor Green
}
# Warning message to stderr with standard formatting.
function Write-Warn {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  Write-Host "[$(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")] [INFO] [$ENV:COMPUTERNAME] $($Message -join ' ')" -ForegroundColor Yellow
}

# Prompt with optional default value.
function Read-Value {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Default = $null
  )

  $prompt = if ($null -ne $Default -and $Default -ne '') { "$Message [$Default]" } else { $Message }
  $input = Read-Host -Prompt $prompt
  if ([string]::IsNullOrWhiteSpace($input) -and $null -ne $Default) { return $Default }
  return $input
}

# Prompt with masked values
function Read-Secret {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "$Message"
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