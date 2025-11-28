Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UiLogFile = $null
$script:ShowInfoOnConsole = $true

function Set-UiLogFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $script:UiLogFile = $Path
}

function Set-UiInfoVisibility {
  param([bool]$Visible = $true)
  $script:ShowInfoOnConsole = $Visible
}

function Write-ColoredPrompt {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ConsoleColor]$Color = [ConsoleColor]::Cyan
  )

  Write-Host $Message -ForegroundColor $Color -NoNewline
  Write-Host ' ' -NoNewline
}

function Write-LogLine {
  param(
    [Parameter(Mandatory = $true)][string]$Level,
    [Parameter(Mandatory = $true)][string]$Message,
    [System.Nullable[ConsoleColor]]$Color = $null,
    [bool]$ForceConsole = $false
  )

  $line = "[$(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")] [$Level] [$ENV:COMPUTERNAME] $Message"
  if ($script:UiLogFile) {
    Add-Content -Path $script:UiLogFile -Value $line
  }

  $shouldWrite = $ForceConsole -or $script:ShowInfoOnConsole -or $Level -ne 'INFO'
  if ($shouldWrite) {
    if ($null -ne $Color) {
      Write-Host $line -ForegroundColor $Color
    } else {
      Write-Host $line
    }
  }
}

# Prompt for arbitrary input and return the response.
function Read-Prompt {
  param(
    [Parameter(Mandatory = $true)][string]$Message
  )
  Write-ColoredPrompt -Message $Message -Color 'Cyan'
  Read-Host
}

# Yes/no confirmation. Returns $true on yes, $false otherwise.
function Confirm-Action {
  param(
    [string]$Message = "Proceed?"
  )
  $prompt = "$Message [y/N]"
  Write-ColoredPrompt -Message $prompt -Color 'Cyan'
  $response = Read-Host
  return $response -match '^(?i:y(es)?)$'
}

# Info message to stdout.
function Write-Info {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  $text = $Message -join ' '
  Write-LogLine -Level 'INFO' -Message $text
}

# success message
function Write-Success {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  $text = $Message -join ' '
  Write-LogLine -Level 'SUCCESS' -Message $text -Color 'Green' -ForceConsole:$true
}
# Warning message to stderr with standard formatting.
function Write-Warn {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  $text = $Message -join ' '
  Write-LogLine -Level 'WARN' -Message $text -Color 'Yellow' -ForceConsole:$true
}

# Prompt with optional default value.
function Read-Value {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Default = $null
  )

  $prompt = if ($null -ne $Default -and $Default -ne '') { "$Message [$Default]" } else { $Message }
  $color = if ($null -ne $Default -and $Default -ne '') { 'Gray' } else { 'Cyan' }
  Write-ColoredPrompt -Message $prompt -Color $color
  $input = Read-Host
  if ([string]::IsNullOrWhiteSpace($input) -and $null -ne $Default) { return $Default }
  return $input
}

function Read-Choice {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [Parameter(Mandatory = $true)][string[]]$Options
  )

  $validOptions = $Options | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  if (-not $validOptions -or $validOptions.Count -eq 0) {
    throw "Read-Choice requires at least one non-empty option."
  }
  $display = $validOptions -join '|'
  $inputValidated = $false
  while (!$inputValidated) {
    Write-ColoredPrompt -Message $Message -Color 'Cyan'
    $inputValue = Read-Host
    $inputValue = if ($null -eq $inputValue) { '' } else { $inputValue.Trim() }
    $match = $validOptions | Where-Object { $_.Equals($inputValue, 'InvariantCultureIgnoreCase') }
    if ($match) {
      $inputValidated = $true
      return $match
    }else{
      Write-Warn "Invalid choice. Allowed: $display"
    }
  }
}

# Prompt with masked values
function Read-Secret {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-ColoredPrompt -Message $Message -Color 'Cyan'
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
