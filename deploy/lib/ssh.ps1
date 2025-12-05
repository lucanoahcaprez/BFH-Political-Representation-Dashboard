Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/util.ps1"

# Ensure ssh is present before use.
Require-Command 'ssh'

# Check if SSH connectivity works. Returns $true/$false.
function Test-SshConnection {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20
  )

  $args = @(
    '-p', $Port,
    '-o', 'PreferredAuthentications=publickey,password',
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
    "$User@$Server",
    'exit 0'
  )

  $process = Start-Process -FilePath 'ssh' -ArgumentList $args -NoNewWindow -Wait -PassThru
  return ($process.ExitCode -eq 0)
}

# Execute a remote script via SSH. Throws on failure.
function Invoke-SshScript {
  param(
    [Parameter(Mandatory = $true)][string]$User,
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 22,
    [int]$ConnectTimeoutSeconds = 20,
    [Parameter(Mandatory = $true)][string]$Script
  )

  $args = @(
    '-p', $Port,
    '-o', 'PreferredAuthentications=publickey,password',
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
    '-o', 'StrictHostKeyChecking=accept-new',
    "$User@$Server",
    "set -euo pipefail; $Script"
  )

  $process = Start-Process -FilePath 'ssh' -ArgumentList $args -NoNewWindow -Wait -PassThru
  if ($process.ExitCode -ne 0) {
    Throw-Die "ssh exited with code $($process.ExitCode)"
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

  $args = @(
    '-p', $Port,
    '-o', 'PreferredAuthentications=publickey,password',
    '-o', "ConnectTimeout=$ConnectTimeoutSeconds",
    '-o', 'StrictHostKeyChecking=accept-new',
    "$User@$Server",
    "set -euo pipefail; $Script"
  )

  $output = & ssh @args
  if ($LASTEXITCODE -ne 0) {
    Throw-Die "ssh exited with code $LASTEXITCODE"
  }
  return $output
}
