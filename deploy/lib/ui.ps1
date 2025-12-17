Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Preserve existing logger settings if the module is dot-sourced multiple times.
if (-not (Get-Variable -Name UiLogFile -Scope Script -ErrorAction SilentlyContinue)) {
  $script:UiLogFile = $null
}
if (-not (Get-Variable -Name ShowInfoOnConsole -Scope Script -ErrorAction SilentlyContinue)) {
  $script:ShowInfoOnConsole = $true
}

function Set-UiLogFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $script:UiLogFile = $Path
}

function Set-UiInfoVisibility {
  param([bool]$Visible = $true)
  $script:ShowInfoOnConsole = $Visible
}

function Write-Section {
  param([Parameter(Mandatory = $true)][string]$Title)
  $line = '-' * 64
  Write-Host ''
  Write-Host $line
  Write-Host "> $Title"
  Write-Host $line
}

function Write-ColoredPrompt {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ConsoleColor]$Color = [ConsoleColor]::Cyan
  )

  Write-Host "$Message`:" -ForegroundColor $Color -NoNewline
  Write-Host ' ' -NoNewline
}

function Write-LogLine {
  param(
    [Parameter(Mandatory = $true)][string]$Level,
    [Parameter(Mandatory = $true)][string]$Message,
    [System.Nullable[ConsoleColor]]$Color = $null,
    [bool]$ForceConsole = $false
  )

  $safeMessage = $Message -replace "SUDO_PASSWORD='[^']*'", "SUDO_PASSWORD='***'" -replace "SUDO_PASSWORD=[^ ]*", 'SUDO_PASSWORD=***'
  $line = "[$(Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")] [$ENV:COMPUTERNAME] [$Level] $safeMessage"
  if ($script:UiLogFile) {
    Add-Content -Path $script:UiLogFile -Value $line
  }

  $shouldWrite = $ForceConsole -or $script:ShowInfoOnConsole -or $Level -ne 'INFO'
  if ($shouldWrite) {
    $prefix = switch ($Level) {
      'INFO'    { '-' }
      'SUCCESS' { '[OK]' }
      'WARN'    { '[WARN]' }
      'ERROR'   { '[ERR]' }
      default   { $Level }
    }
    $consoleLine = "$prefix $safeMessage"
    if ($null -ne $Color) {
      Write-Host $consoleLine -ForegroundColor $Color
    } else {
      Write-Host $consoleLine
    }
    # Flush input buffer (Enter key leftover)
    while ([Console]::KeyAvailable) {
      [Console]::ReadKey($true) | Out-Null
    }
  }
}

# require prompt (null values not allowed)
function Read-RequiredValue{
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Default = $null
  )
  while ($true) {
    $value = Read-Value -Message $Message -Default $Default
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    Write-Warn 'Please enter a value.'
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

function Write-Error {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Message)
  $text = $Message -join ' '
  Write-LogLine -Level 'ERROR' -Message $text -Color 'Red' -ForceConsole:$true
}


# Prompt with optional default value.
function Read-Value {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [string]$Default = $null
  )

  $prompt = if ($null -ne $Default -and $Default -ne '') { "$Message [$Default]" } else { $Message }
  Write-ColoredPrompt -Message $prompt -Color 'Cyan'
  $inputValue = Read-Host
  if ([string]::IsNullOrWhiteSpace($inputValue) -and $null -ne $Default) { return $Default }
  return $inputValue
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
  # Flush input buffer (Enter key leftover) - credits: GPT 5.1
  while ([Console]::KeyAvailable) {
      [Console]::ReadKey($true) | Out-Null
  }
  return $builder.ToString()
}
