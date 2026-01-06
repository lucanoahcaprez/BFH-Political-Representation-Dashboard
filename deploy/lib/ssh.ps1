Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/util.ps1"

# Ensure ssh is present before use.
Test-Command 'ssh'

# Check if SSH connectivity works. Returns $true/$false.
function Test-SshConnection {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [switch]$PublicKeyOnly
  )

  $authModes = if ($PublicKeyOnly) { 'publickey' } else { 'publickey,password' }

  $arguments = @(
    '-p', $Port,
    '-o', "PreferredAuthentications=$authModes",
    '-o', 'LogLevel=ERROR',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'BatchMode=yes',
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
    "$User@$Server",
    'exit 0'
  )

  $process = Start-Process -FilePath 'ssh' -ArgumentList $arguments -NoNewWindow -Wait -PassThru
  return ($process.ExitCode -eq 0)
}

# Execute a remote script via SSH. Throws on failure.
function Invoke-SshScript {
  param(
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [Parameter(Mandatory)][string]$Script,
    [string]$LogFile=$LogFile
  )

  $tmpOut = Join-Path $env:TEMP ("ssh-out-{0}.log" -f ([guid]::NewGuid()))
  $tmpErr = Join-Path $env:TEMP ("ssh-err-{0}.log" -f ([guid]::NewGuid()))

  $arguments = @(
    '-p', $Port,
    '-o', 'PreferredAuthentications=publickey,password',
    '-o', 'LogLevel=ERROR',
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
    '-o', 'StrictHostKeyChecking=accept-new',
    "$User@$Server",
    "set -euo pipefail; $Script"
  )

  try {
    $p = Start-Process -FilePath 'ssh' -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError  $tmpErr

    # Append both streams to your real log (preserves order per-stream, not interleaved)
    if (Test-Path $tmpOut) { Get-Content -LiteralPath $tmpOut | Add-Content -LiteralPath $LogFile }
    if (Test-Path $tmpErr) { Get-Content -LiteralPath $tmpErr | Add-Content -LiteralPath $LogFile }

    if ($p.ExitCode -ne 0) {
      New-Error "ssh exited with code $($p.ExitCode)"
    }
  }
  finally {
    Remove-Item -LiteralPath $tmpOut, $tmpErr -ErrorAction SilentlyContinue
  }
}

# invoke ssh script with output
function Invoke-SshScriptOutput {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [Parameter(Mandatory = $true)][string]$Script
  )

  $arguments = @(
    '-p', $Port,
    '-o', 'PreferredAuthentications=publickey,password',
    '-o', 'LogLevel=ERROR',
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
    '-o', 'StrictHostKeyChecking=accept-new',
    "$User@$Server",
    "set -euo pipefail; $Script"
  )
  $output = & ssh @arguments
  
  if ($LASTEXITCODE -ne 0) {
    New-Error "ssh exited with code $LASTEXITCODE"
  }
  return $output
}
