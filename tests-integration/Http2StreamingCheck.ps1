# =============================================================================
# Http2StreamingCheck.ps1 - live check of streaming responses over HTTP/2 and
# HTTP/1.1 on a TLS listener (run ELEVATED).
# =============================================================================
# HTTP.sys negotiates HTTP/2 only on TLS listeners (ALPN), and binding a TLS
# certificate (netsh http add sslcert) needs administrator rights - which is why
# this check is not part of the standard tests/ suite. It:
#   1. builds demo/07.Sse (unless -SkipBuild),
#   2. creates a temporary self-signed certificate for "localhost" in
#      LocalMachine\My and binds it to 127.0.0.1:<Port> (netsh http add sslcert),
#   3. starts SseDemo on https://127.0.0.1:<Port>/sse/ (elevated, so no URL
#      reservation is needed),
#   4. reads /sse/ once over HTTP/2 and once over HTTP/1.1 with .NET HttpClient
#      (exact protocol version, the temporary certificate is accepted by
#      thumbprint) and asserts:
#        - HTTP/2:   the response really is HTTP/2, carries no Transfer-Encoding
#                    and the body is exactly the SSE events - no chunk framing
#                    bytes (hex sizes, CRLF) leaked into it;
#        - HTTP/1.1: Transfer-Encoding: chunked, the decoded body is the same,
#                    and the raw TLS stream carries the exact chunk framing.
#   5. stops the demo and removes EVERYTHING it created: the sslcert binding
#      and the certificate including its private key - also on failure.
#
# It never touches a binding it did not create: if 127.0.0.1:<Port> already has
# an sslcert binding, it stops before changing anything.
#
# USAGE (elevated PowerShell 7):
#   ./tests-integration/Http2StreamingCheck.ps1
#   ./tests-integration/Http2StreamingCheck.ps1 -Port 44399 -Platform Win32
#   ./tests-integration/Http2StreamingCheck.ps1 -NoTls   # plumbing self-test:
#       plain http on 127.0.0.1, HTTP/1.1 only, no elevation, no certificate
#
# Exit code 0 = all checks passed, 1 = a check failed or the setup failed.
# =============================================================================

#Requires -Version 7.0

param(
    [int]$Port        = 44399,
    [string]$Platform = 'Win64',
    [string]$Config   = 'Debug',
    [switch]$SkipBuild,
    [switch]$NoTls
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$ipPort   = "127.0.0.1:$Port"
$scheme   = if ($NoTls) { 'http' } else { 'https' }
$prefix   = "${scheme}://127.0.0.1:$Port/sse/"

# The exact body SseDemo streams: ten ticks, then the "done" event (LF only).
$expectedBody = ((1..10 | ForEach-Object { "data: tick $_`n`n" }) -join '') +
    "event: done`ndata: stream finished`n`n"

$script:failures = 0
function Write-Check([bool]$AOk, [string]$AText) {
    if ($AOk) {
        Write-Host "  [PASS] $AText" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $AText" -ForegroundColor Red
        $script:failures++
    }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Certificate check for the temporary certificate, compiled (not a script
# block): HttpClient's HTTP/2 path runs the TLS handshake on a thread-pool
# thread, where a PowerShell script block cannot run ("no runspace available").
if (-not ('DXHttpSysCheckTls' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class DXHttpSysCheckTls {
    public static string Thumbprint;
    public static bool Validate(object sender, X509Certificate certificate, X509Chain chain,
        SslPolicyErrors errors) {
        return certificate != null && !string.IsNullOrEmpty(Thumbprint) &&
            string.Equals(certificate.GetCertHashString(), Thumbprint, StringComparison.OrdinalIgnoreCase);
    }
}
'@
}
$certCallback = [System.Delegate]::CreateDelegate(
    [System.Net.Security.RemoteCertificateValidationCallback],
    [DXHttpSysCheckTls].GetMethod('Validate'))

# GET AUrl with HttpClient, forcing exactly AVersion (no downgrade/upgrade).
# Asynchronous send: SocketsHttpHandler has no synchronous HTTP/2 path.
function Invoke-VersionedGet([string]$AUrl, [version]$AVersion) {
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.SslOptions.RemoteCertificateValidationCallback = $certCallback
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new('GET', $AUrl)
        $request.Version       = $AVersion
        $request.VersionPolicy = [System.Net.Http.HttpVersionPolicy]::RequestVersionExact
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        [pscustomobject]@{
            Status           = [int]$response.StatusCode
            Version          = $response.Version
            ChunkedHeader    = $response.Headers.TransferEncodingChunked
            TransferEncoding = ($response.Headers.TransferEncoding | ForEach-Object { $_.Value }) -join ','
            ContentType      = "$($response.Content.Headers.ContentType)"
            Body             = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
    } finally {
        $client.Dispose()
    }
}

# GET /sse/ over a raw (TLS) stream with HTTP/1.1, returning the undecoded bytes
# as text so the chunk framing on the wire can be asserted.
function Invoke-RawHttp11Get {
    $tcp = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
    try {
        $stream = $tcp.GetStream()
        if (-not $NoTls) {
            $ssl = [System.Net.Security.SslStream]::new($stream, $false, $certCallback)
            $options = [System.Net.Security.SslClientAuthenticationOptions]::new()
            $options.TargetHost = 'localhost'
            $options.ApplicationProtocols = [System.Collections.Generic.List[System.Net.Security.SslApplicationProtocol]]@(
                [System.Net.Security.SslApplicationProtocol]::Http11)
            $ssl.AuthenticateAsClient($options)
            $stream = $ssl
        }
        $stream.ReadTimeout = 60000
        $request = "GET /sse/ HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`nConnection: close`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $buffer = [byte[]]::new(8192)
        $all = [System.IO.MemoryStream]::new()
        while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $all.Write($buffer, 0, $n)
        }
        [Text.Encoding]::UTF8.GetString($all.ToArray())
    } finally {
        $tcp.Dispose()
    }
}

# Builds the expected HTTP/1.1 chunked body from the events SseDemo sends.
function Get-ExpectedChunkedBody {
    $events = (1..10 | ForEach-Object { "data: tick $_`n`n" }) +
        @("event: done`ndata: stream finished`n`n")
    (($events | ForEach-Object {
        ('{0:X}' -f [Text.Encoding]::UTF8.GetByteCount($_)) + "`r`n" + $_ + "`r`n"
    }) -join '') + "0`r`n`r`n"
}

Write-Host '============================================='
Write-Host '| DX.HttpSys - HTTP/2 streaming live check  |'
Write-Host '============================================='

if (-not $NoTls -and -not (Test-Elevated)) {
    Write-Host 'This check must run elevated: binding a TLS certificate to a port' -ForegroundColor Red
    Write-Host '(netsh http add sslcert) needs administrator rights. Use -NoTls for' -ForegroundColor Red
    Write-Host 'the unelevated plumbing self-test (HTTP/1.1 over plain http only).' -ForegroundColor Red
    exit 1
}

# 1. Build the demo.
if (-not $SkipBuild) {
    & (Join-Path $repoRoot 'build-scripts\DelphiBuildDPROJ.ps1') `
        -ProjectFile (Join-Path $repoRoot 'demo\07.Sse\SseDemo.dproj') `
        -Config $Config -Platform $Platform | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host 'SseDemo build failed' -ForegroundColor Red; exit 1 }
}
$exe = Join-Path $repoRoot "build\$Platform\$Config\SseDemo.exe"
if (-not (Test-Path $exe)) { Write-Host "Not found: $exe" -ForegroundColor Red; exit 1 }

# Removes a certificate created by this script from its store, together with
# its persisted private key (CNG). Returns $true on success.
function Remove-TemporaryCertificate([System.Security.Cryptography.X509Certificates.X509Certificate2]$ACert,
                                     [string]$AStorePath) {
    $rsa = $null
    try {
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($ACert)
        Remove-Item -Path (Join-Path $AStorePath $ACert.Thumbprint) -Force
        if ($rsa -is [System.Security.Cryptography.RSACng]) { $rsa.Key.Delete() }
        return $true
    } catch {
        Write-Host "Could not remove certificate $($ACert.Thumbprint): $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    } finally {
        if ($rsa) { $rsa.Dispose() }
    }
}

# Runs one group of checks; an exception fails the group but not the others.
function Invoke-CheckGroup([string]$ATitle, [scriptblock]$AChecks) {
    Write-Host "${ATitle}:"
    try {
        & $AChecks
    } catch {
        Write-Check $false "$ATitle failed: $($_.Exception.Message)"
    }
}

$certStore  = 'Cert:\LocalMachine\My'
$cert       = $null
$bound      = $false
$demo       = $null
try {
    # 2. Temporary certificate + sslcert binding (TLS only).
    if (-not $NoTls) {
        $existing = netsh http show sslcert ipport=$ipPort 2>&1 | Out-String
        if ($existing -match '(?i)certificate hash|zertifikathash') {
            throw "An sslcert binding for $ipPort already exists - choose another -Port (nothing was changed)."
        }
        $cert = New-SelfSignedCertificate -DnsName 'localhost' -CertStoreLocation $certStore `
            -FriendlyName 'DX.HttpSys Http2StreamingCheck (temporary)' -NotAfter (Get-Date).AddDays(1) `
            -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy NonExportable
        [DXHttpSysCheckTls]::Thumbprint = $cert.Thumbprint
        Write-Host "Temporary certificate $($cert.Thumbprint) created in $certStore"
        $appId = '{' + [guid]::NewGuid().ToString() + '}'
        # "add" fails (error 183) on an existing binding, so it never replaces one.
        $out = netsh http add sslcert ipport=$ipPort certhash=$($cert.Thumbprint) appid=$appId certstorename=MY 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "netsh http add sslcert failed: $out" }
        $bound = $true
        Write-Host "sslcert binding $ipPort added"
    }

    # 3. Start the demo; a line on its stdin stops it.
    $psi = [System.Diagnostics.ProcessStartInfo]::new($exe, $prefix)
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $demo = [System.Diagnostics.Process]::Start($psi)
    $line = $demo.StandardOutput.ReadLine()
    if ($null -eq $line -or $line -notmatch 'listening') {
        $err = $demo.StandardError.ReadToEnd()
        throw "SseDemo did not start: $line $err"
    }
    Write-Host "SseDemo (PID $($demo.Id)): $line"

    # 4a. HTTP/2 (TLS only).
    if (-not $NoTls) {
        Invoke-CheckGroup 'HTTP/2' {
            $r2 = Invoke-VersionedGet $prefix ([version]'2.0')
            Write-Check ($r2.Status -eq 200) "status 200 (got $($r2.Status))"
            Write-Check ($r2.Version -eq [version]'2.0') `
                "negotiated HTTP/2 (got HTTP/$($r2.Version); HTTP/2 disabled via EnableHttp2Tls=0 or disablehttp2?)"
            Write-Check (-not $r2.ChunkedHeader -and -not $r2.TransferEncoding) `
                "no Transfer-Encoding header (got '$($r2.TransferEncoding)')"
            Write-Check ($r2.ContentType -like 'text/event-stream*') "content-type text/event-stream (got '$($r2.ContentType)')"
            Write-Check ($r2.Body -ceq $expectedBody) 'body is exactly the SSE events (no chunk framing bytes)'
            if ($r2.Body -cne $expectedBody) {
                Write-Host '    received body (escaped):'
                Write-Host ('    ' + ($r2.Body -replace "`r", '\r' -replace "`n", '\n'))
            }
        }
    }

    # 4b. HTTP/1.1 (decoded by HttpClient).
    Invoke-CheckGroup 'HTTP/1.1' {
        $r1 = Invoke-VersionedGet $prefix ([version]'1.1')
        Write-Check ($r1.Status -eq 200) "status 200 (got $($r1.Status))"
        Write-Check ($r1.Version -eq [version]'1.1') "HTTP/1.1 (got HTTP/$($r1.Version))"
        Write-Check ($r1.ChunkedHeader -eq $true) 'Transfer-Encoding: chunked'
        Write-Check ($r1.Body -ceq $expectedBody) 'decoded body is exactly the SSE events'
    }

    # 4c. HTTP/1.1 raw wire: the exact chunk framing.
    Invoke-CheckGroup 'HTTP/1.1 raw wire' {
        $raw = Invoke-RawHttp11Get
        $split = $raw.IndexOf("`r`n`r`n")
        $rawBody = if ($split -ge 0) { $raw.Substring($split + 4) } else { '' }
        Write-Check ($rawBody -ceq (Get-ExpectedChunkedBody)) 'raw HTTP/1.1 body carries the exact chunk framing'
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $script:failures++
} finally {
    # 5. Clean up everything this script created.
    if ($demo) {
        try {
            if (-not $demo.HasExited) {
                $demo.StandardInput.WriteLine()
                if (-not $demo.WaitForExit(10000)) { $demo.Kill() }
            }
        } catch {
            Write-Host "Could not stop SseDemo cleanly: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        $demo.Dispose()
    }
    if ($bound) {
        $out = netsh http delete sslcert ipport=$ipPort 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Host "sslcert binding $ipPort removed"
        } else {
            Write-Host "Could not remove the sslcert binding ${ipPort}: $out" -ForegroundColor Yellow
            $script:failures++
        }
    }
    if ($cert) {
        if (Remove-TemporaryCertificate $cert $certStore) {
            Write-Host "Temporary certificate $($cert.Thumbprint) removed (incl. private key)"
        } else {
            $script:failures++
        }
    }
}

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) check(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
exit 0
