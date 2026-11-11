# Trace why `lore push` fails to authenticate on Windows, and say how to fix it.
# The Windows counterpart of trace-auth.sh (client checks only; run --server from the server).
#
# cd to the root of the working tree that won't push, then run:
#   powershell -ExecutionPolicy Bypass -File <deploy-dir>\scripts\trace-auth.ps1
#   powershell -ExecutionPolicy Bypass -File <deploy-dir>\scripts\trace-auth.ps1 -Push
# Without -Push the push is a dry run: it authenticates but doesn't upload, so it can't
# show a missing `write` permission.
#
# Output goes to a new folder under %TEMP%, printed at the end. Access tokens are replaced
# with <JWT redacted> before anything is written, and only their decoded claims are kept.
# Read the report before you share it: it names your user ID. Exits 1 when it finds a cause.
[CmdletBinding()]
param([switch]$Push)

$ErrorActionPreference = 'Continue'
$DeployDir = Split-Path -Parent $PSScriptRoot

function Get-TomlFirstString([string]$Key) {
  $toml = Join-Path $DeployDir 'config\local.toml'
  if (-not (Test-Path $toml)) { return '' }
  $line = Select-String -Path $toml -Pattern "^\s*$Key\s*=" | Select-Object -First 1
  if ($line -and $line.Line -match '"([^"]*)"') { return $Matches[1] }
  return ''
}
$ExpectedIss = if ($env:EXPECTED_ISS) { $env:EXPECTED_ISS } else { Get-TomlFirstString 'jwt_issuer' }
$ExpectedAud = if ($env:EXPECTED_AUD) { $env:EXPECTED_AUD } else { Get-TomlFirstString 'jwt_audience' }

$Out = if ($env:TRACE_DIR) { $env:TRACE_DIR } else {
  Join-Path $env:TEMP ('lore-auth-trace.' + [IO.Path]::GetRandomFileName().Replace('.', ''))
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Report = Join-Path $Out 'report.txt'
Set-Content -Path $Report -Value '' -Encoding UTF8

$Findings = New-Object System.Collections.Generic.List[string]
$JwtPattern = 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*'

function Say([string]$Text) { Write-Host $Text; Add-Content -Path $Report -Value $Text -Encoding UTF8 }
function Section([string]$Title) { Say ''; Say "=== $Title ===" }
function Finding([string]$Text) { $Findings.Add($Text); Say "!! $Text" }
function Redact([string]$Text) { return [regex]::Replace($Text, $JwtPattern, '<JWT redacted>') }

# Runs a native command; its output is redacted before it reaches $Out\<label>.log, then shown.
function Run([string]$Label, [string]$Exe, [string[]]$CmdArgs) {
  $file = Join-Path $Out "$Label.log"
  Say ("PS> $Exe " + ($CmdArgs -join ' '))
  $lines = & $Exe @CmdArgs 2>&1 | ForEach-Object { Redact "$_" }
  $rc = $LASTEXITCODE
  Set-Content -Path $file -Value $lines -Encoding UTF8
  $lines | Select-Object -First 60 | ForEach-Object { Say "    $_" }
  Say "    (exit $rc, full output: $file)"
  return $rc
}

function Show-Diagnosis {
  Section 'Diagnosis'
  if ($Findings.Count -eq 0) {
    Say 'No known cause found. Run trace-auth.sh --server on the server too, and compare both'
    Say 'reports with the table in deploy/docs/AUTH0.md#troubleshooting.'
  } else {
    $i = 1
    foreach ($f in $Findings) { Say "$i. $f"; $i++ }
  }
  Say ''
  Say "Report: $Report"
  if ($Findings.Count -eq 0) { exit 0 } else { exit 1 }
}

# Flags stored logins whose `Expires:` time in `lore auth list` has passed. A login past it
# can no longer be refreshed, so every call that needs a token fails until `lore login`.
function Test-AuthList([string]$ServerUrl) {
  [void](Run 'auth-list' 'lore' @('auth', 'list'))
  $expired = 0
  foreach ($line in Get-Content (Join-Path $Out 'auth-list.log')) {
    if ($line -match '^\s*Expires:\s*(.+?)\s*$') {
      # "Sat, 7 Nov 2026 18:38:13 +0000": .NET wants the offset as +00:00.
      $text = $Matches[1] -replace '([+-]\d\d)(\d\d)$', '$1:$2'
      $when = [DateTimeOffset]::MinValue
      if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
          [Globalization.DateTimeStyles]::None, [ref]$when) -and $when -lt [DateTimeOffset]::UtcNow) {
        $expired++
      }
    }
  }
  if ($expired -gt 0) {
    $hint = if ($ServerUrl) { $ServerUrl } else { '<lores://server:41337>' }
    Finding "$expired stored login(s) in 'lore auth list' are past their Expires time, so the CLI can't refresh them and every authenticated call fails. Log in again: lore login $hint"
  }
}

# ---------------------------------------------------------------------------
if (-not (Get-Command lore -ErrorAction SilentlyContinue)) { Write-Error 'lore not found on PATH'; exit 1 }

Section 'Client: version and environment'
[void](Run 'version' 'lore' @('--version'))
Say ("Windows clock (UTC): " + [DateTime]::UtcNow.ToString('u'))
# setx and the System dialog set variables at User or Machine scope, which outlive the shell
# they were set in and are easy to forget.
foreach ($v in 'LORE_ACCESS_TOKEN', 'LORE_IDENTITY_TOKEN', 'LORE_AUTH_MODE', 'LORE_AUTH_PATH',
               'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY') {
  $scopes = @()
  foreach ($scope in 'Process', 'User', 'Machine') {
    if ([Environment]::GetEnvironmentVariable($v, $scope)) { $scopes += $scope }
  }
  if ($scopes.Count -gt 0) { Say "$v is set ($($scopes -join ', ') scope)" } else { Say "$v is unset" }
  if ($scopes.Count -gt 0 -and $v -in 'LORE_ACCESS_TOKEN', 'LORE_IDENTITY_TOKEN') {
    $fix = if ($scopes -contains 'Machine') { "[Environment]::SetEnvironmentVariable('$v', `$null, 'Machine') in an admin PowerShell" } else { "[Environment]::SetEnvironmentVariable('$v', `$null, 'User')" }
    Finding "$v is set ($($scopes -join ', ') scope); every lore command uses it instead of your stored login. If it's stale, remove it: $fix, then open a new terminal."
  }
}
if ($env:LORE_AUTH_PATH) { Say '    LORE_AUTH_PATH points the CLI at another token store; a login made without it is not seen.' }
if ($env:HTTPS_PROXY) { Say '    HTTPS_PROXY is used for the Auth0 login and refresh; a dead proxy makes refresh fail.' }
[void](Run 'winhttp-proxy' 'netsh' @('winhttp', 'show', 'proxy'))

Section 'Client: token store'
$StoreDir = if ($env:LORE_AUTH_PATH) { $env:LORE_AUTH_PATH } else { Join-Path $env:LOCALAPPDATA 'Epic Games\lore\config' }
$StoreFile = Join-Path $StoreDir 'tokenstore.toml'
if (Test-Path $StoreFile) {
  $item = Get-Item $StoreFile
  Say "$StoreFile (last written $($item.LastWriteTime.ToString('u')))"
  try { [IO.File]::Open($StoreFile, 'Open', 'ReadWrite', 'None').Close() }
  catch { Finding "Can't open $StoreFile for writing ($($_.Exception.Message)). A refreshed token can't be saved. Close other lore processes, check the file isn't read-only, and that OneDrive or antivirus isn't locking it." }
} else {
  Say "$StoreFile doesn't exist: this Windows user has never logged in (or LORE_AUTH_PATH differs)."
}

Section 'Client: repository remote'
$Remote = (& lore repository config get remote_url 2>$null | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0) { $Remote = '' }
if (-not $Remote -and (Test-Path '.lore\config.toml')) {
  $line = Select-String -Path '.lore\config.toml' -Pattern '^\s*remote_url\s*=' | Select-Object -First 1
  if ($line -and $line.Line -match '"([^"]*)"') { $Remote = $Matches[1] }
}
Say ("remote_url = " + $(if ($Remote) { $Remote } else { '<none>' }))
if (-not $Remote) {
  Finding "No remote_url here ($PWD is not a Lore working tree). cd to the root of the working tree that won't push and run this script by its path. The connection, token and push checks were skipped because they need the repository."
  Section 'Client: stored identities'
  Test-AuthList ''
  Show-Diagnosis
}
if ($Remote -like 'lore://*') { Finding 'remote_url uses lore://, which sends tokens without TLS. Use lores:// for this server.' }
$Uri = [Uri]($Remote -replace '^lores?://', 'https://')
$TargetHost = $Uri.Host.Trim('[', ']')
$Port = if ($Remote -match '^[a-z]+://(\[[^\]]+\]|[^/:]+):(\d+)') { [int]$Matches[2] } else { 41337 }
$ServerUrl = ($Remote -replace '^([a-z]+://[^/]+).*$', '$1')

Section "Client: reachability of ${TargetHost}:$Port"
$tcp = New-Object Net.Sockets.TcpClient
$tcpOk = $false
try { $tcpOk = $tcp.ConnectAsync($TargetHost, $Port).Wait(5000) -and $tcp.Connected } catch { $tcpOk = $false }
if (-not $tcpOk) {
  $tcp.Dispose()
  Finding "Can't open a TCP connection to ${TargetHost}:$Port. This is a network problem, not auth: check the server is up, the address is right, and Windows Firewall or a VPN isn't blocking it."
} else {
  Say '    connected'
  # Validate the certificate the way Windows does; the CLI trusts the Windows root store too.
  $chainInfo = @{ Errors = 'None'; Detail = '' }
  $callback = {
    param($sender, $cert, $chain, $errors)
    $chainInfo.Errors = "$errors"
    $chainInfo.Detail = ($chain.ChainStatus | ForEach-Object { $_.StatusInformation.Trim() }) -join '; '
    $chainInfo.Subject = $cert.Subject
    $chainInfo.Issuer = $cert.Issuer
    return $true
  }
  try {
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $callback)
    $ssl.AuthenticateAsClient($TargetHost)
    Say "    subject: $($chainInfo.Subject)"
    Say "    issuer:  $($chainInfo.Issuer)"
    Say "    Windows chain check: $($chainInfo.Errors) $($chainInfo.Detail)"
    if ($chainInfo.Errors -match 'RemoteCertificateChainErrors') {
      Finding "Windows doesn't trust the server certificate ($($chainInfo.Detail)). Install the LAN CA in an admin PowerShell: certutil -addstore -f Root lore-home-ca.pem (HOME-LAN.md section 4)."
    }
    if ($chainInfo.Errors -match 'RemoteCertificateNameMismatch') {
      Finding "The server certificate doesn't name '$TargetHost'. Connect by a name or IP the certificate covers (HOME-LAN.md)."
    }
    $ssl.Dispose()
  } catch {
    Say "    TLS handshake failed: $($_.Exception.InnerException.Message) $($_.Exception.Message)"
  } finally { $tcp.Dispose() }
}

Section 'Client: stored identities'
Test-AuthList $ServerUrl
if ((Run 'auth-info' 'lore' @('auth', 'info')) -ne 0) {
  Finding "'lore auth info' failed: no usable stored login. Run: lore login $ServerUrl"
}

Section "Client: access token claims (the token itself isn't saved)"
$tokenOut = (& lore auth info --with-access-token 2>&1 | ForEach-Object { "$_" }) -join "`n"
$tokenRc = $LASTEXITCODE
$m = [regex]::Match($tokenOut, $JwtPattern)
if ($tokenRc -ne 0) {
  $err = ((Redact $tokenOut) -split "`n" | Select-Object -Last 3) -join ' '
  Finding "Couldn't get an access token for this repository: $err - if this is an auth error, run: lore login $ServerUrl"
} elseif (-not $m.Success) {
  if ($tokenOut -match 'access token') {
    Finding "The access token isn't a JWT: Auth0 issued an opaque token because no audience was sent. Set the tenant's Default Audience (AUTH0.md step 3), then: lore login $ServerUrl"
  } else {
    Finding "No access token stored for this repository. Run: lore login $ServerUrl"
  }
} else {
  try {
    $p = $m.Value.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $p += '=' * ((4 - $p.Length % 4) % 4)
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    $aud = @($claims.aud)
    $perms = @($claims.lore_permissions)
    if ($perms.Count -eq 1 -and $perms[0] -is [string]) { $perms = $perms[0].Split(',') | ForEach-Object { $_.Trim() } }
    # Same rule as lore-credential acceptable_root_domains / domain_in_root_domains.
    $roots = @($claims.root_domains) + @($claims.'https://lore.org/claims/root_domains') | Where-Object { $_ }
    if ($roots.Count -eq 0) {
      $roots = $aud | Where-Object { $_ -like 'https://*' } | ForEach-Object { ([Uri]$_).Host }
    }
    $hostOk = $false
    foreach ($r in $roots) {
      $apex = $r.TrimStart('.')
      if ($TargetHost -eq $apex -or $TargetHost.EndsWith(".$apex")) { $hostOk = $true }
    }
    $expiresIn = [int64]$claims.exp - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $summary = [ordered]@{
      iss = $claims.iss; aud = $aud; sub = $claims.sub; exp = $claims.exp; expires_in_s = $expiresIn
      lore_permissions = $perms; domains_token_may_go_to = @($roots)
    }
    $json = $summary | ConvertTo-Json
    Set-Content -Path (Join-Path $Out 'claims.json') -Value $json -Encoding UTF8
    $json -split "`n" | ForEach-Object { Say "    $_" }
    if ($ExpectedIss -and $claims.iss -ne $ExpectedIss) { Finding "Token iss is '$($claims.iss)', server expects '$ExpectedIss'. Log in again against the right tenant, or fix jwt_issuer." }
    if ($ExpectedAud -and $aud -notcontains $ExpectedAud) { Finding "Token aud is '$($aud -join ', ')', not '$ExpectedAud'. Set the Auth0 Default Audience (AUTH0.md step 3), then log in again." }
    if ($perms -notcontains 'write') { Finding "Token lore_permissions is [$($perms -join ', ')]: no write, so push is denied. Check app_metadata.lore_permissions includes write and the post-login Action is deployed; then log in again." }
    if (-not $hostOk) { Finding "Host '$TargetHost' is not covered by the domains the token may be sent to ($($roots -join ', ')), so the CLI withholds it. Add the host to LORE_HOSTS in the Auth0 Action, then log in again." }
  } catch {
    Say "Couldn't decode the token claims: $($_.Exception.Message)"
  }
}
Remove-Variable tokenOut, m -ErrorAction SilentlyContinue

Section 'Client: traced push'
$pushArgs = if ($Push) { @('--log-level', 'trace', 'push') } else { @('--log-level', 'trace', '--dry-run', 'push') }
$pushRc = Run 'push-trace' 'lore' $pushArgs
$pushLog = Get-Content (Join-Path $Out 'push-trace.log')
$authLines = $pushLog | Select-String -Pattern 'unauthenticated|permission|denied|forbidden|names no domain|certificate|UnknownIssuer|not connected|disconnected|token exchange|os error' | Select-Object -First 40
if ($authLines) { Say '    auth-related lines:'; $authLines | ForEach-Object { Say "      $($_.Line)" } }
if ($pushLog -match 'names no domain') { Finding "The CLI withheld the token: it names no domain covering this host. Add the host to LORE_HOSTS in the Auth0 Action, then: lore login $ServerUrl" }
if ($pushLog -match 'certificate|UnknownIssuer') { Finding 'TLS failure: lore does not trust the server certificate. Install the LAN CA in an admin PowerShell: certutil -addstore -f Root lore-home-ca.pem (HOME-LAN.md section 4).' }
if ($pushLog -match 'no certificates loaded from the OS trust store') { Finding 'lore could not read the Windows certificate store, so a LAN CA installed there is not seen. Run lore from a normal (not restricted or sandboxed) user session.' }
if (-not $Push -and $pushRc -eq 0) { Finding "The dry-run push authenticated, but a dry run doesn't upload, so it can't show a missing write permission or a protected branch. Rerun with -Push." }

Section 'Client: CLI log file'
[void](Run 'logfile' 'lore' @('logfile', 'info'))
$loc = Get-Content (Join-Path $Out 'logfile.log') | Where-Object { $_ -match 'Location:\s*(.+)$' } | Select-Object -First 1
if ($loc -match 'Location:\s*(.+)$' -and (Test-Path $Matches[1].Trim())) {
  $logPath = $Matches[1].Trim()
  $latest = if ((Get-Item $logPath).PSIsContainer) { Get-ChildItem $logPath -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1 } else { Get-Item $logPath }
  if ($latest) {
    Get-Content $latest.FullName -Tail 400 | ForEach-Object { Redact $_ } | Set-Content (Join-Path $Out 'cli-logfile-tail.log') -Encoding UTF8
    Say "    last 400 lines of $($latest.Name) copied to $(Join-Path $Out 'cli-logfile-tail.log')"
  }
}

Show-Diagnosis
