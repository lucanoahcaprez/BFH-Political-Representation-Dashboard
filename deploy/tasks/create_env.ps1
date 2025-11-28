Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Import helper modules (compatible with Windows PowerShell 5.1 and PowerShell 7)
. (Join-Path $PSScriptRoot '..\lib\ui.ps1')

$EnvFile = Join-Path (Get-Location) '.env.deploy'

function Mask-Value {
  param([string]$Name, [string]$Value)
  if ($Name -match 'PASSWORD' -or $Name -match 'SECRET' -or $Name -match 'TOKEN') {
    if ($Value.Length -le 4) { return '****' }
    return ('*' * ([Math]::Max(4, $Value.Length - 2))) + $Value.Substring($Value.Length - 2)
  }
  return $Value
}

# Collect values
$APP_DOMAIN = Read-Value -Message 'Domain (empty or localhost for http://localhost)' -Default ''
$FRONTEND_PORT = Read-Value -Message 'Frontend port' -Default '8080'
$BACKEND_PORT = Read-Value -Message 'Backend port' -Default '3000'
$DB_PORT = Read-Value -Message 'Database port' -Default '5432'
$POSTGRES_USER = Read-Value -Message 'Postgres user' -Default 'postgres'

do {
  $POSTGRES_PASSWORD = Read-Secret -Message 'Postgres password'
  if ([string]::IsNullOrWhiteSpace($POSTGRES_PASSWORD)) {
    Write-Warn 'Password cannot be empty. Please enter a value.'
  }
} until (-not [string]::IsNullOrWhiteSpace($POSTGRES_PASSWORD))

$POSTGRES_DB = 'political_dashboard'
$DATABASE_URL = "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"
$FRONTEND_IMAGE = 'political-dashboard-frontend'
$BACKEND_IMAGE = 'political-dashboard-backend'

$values = [ordered]@{
  APP_DOMAIN        = $APP_DOMAIN
  FRONTEND_PORT     = $FRONTEND_PORT
  BACKEND_PORT      = $BACKEND_PORT
  DB_PORT           = $DB_PORT
  POSTGRES_USER     = $POSTGRES_USER
  POSTGRES_PASSWORD = $POSTGRES_PASSWORD
  POSTGRES_DB       = $POSTGRES_DB
  DATABASE_URL      = $DATABASE_URL
  FRONTEND_IMAGE    = $FRONTEND_IMAGE
  BACKEND_IMAGE     = $BACKEND_IMAGE
}

Write-Info "`nSummary:"
foreach ($entry in $values.GetEnumerator()) {
  $val = if ($null -eq $entry.Value) { '' } else { $entry.Value }
  Write-Host ("  {0} = {1}" -f $entry.Key, (Mask-Value -Name $entry.Key -Value $val))
}

$confirm = Confirm-Action -Message "`nWrite to .env.deploy?"
if (-not $confirm) {
  Write-Warn 'Aborted. No file written.'
  exit 0
}

if (Test-Path $EnvFile) {
  $overwrite = Confirm-Action -Message ".env.deploy already exists. Overwrite?"
  if (-not $overwrite) {
    Write-Warn 'Aborted. Existing file left untouched.'
    exit 0
  }
}

$content = @"
APP_DOMAIN=$APP_DOMAIN
FRONTEND_PORT=$FRONTEND_PORT
BACKEND_PORT=$BACKEND_PORT
DB_PORT=$DB_PORT
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
DATABASE_URL=$DATABASE_URL
FRONTEND_IMAGE=$FRONTEND_IMAGE
BACKEND_IMAGE=$BACKEND_IMAGE
"@

Set-Content -Path $EnvFile -Value $content -Encoding UTF8
Write-Info ".env.deploy written to $EnvFile"
