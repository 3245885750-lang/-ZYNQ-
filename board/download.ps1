param(
    [string]$XsdbPath = '',
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$radarRoot = $PSScriptRoot
try {
    $radarManifest = Get-Content -LiteralPath (Join-Path $radarRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($radarFile in $radarManifest.files.PSObject.Properties) {
        $radarPayload = Join-Path $radarRoot $radarFile.Name
        if (!(Test-Path -LiteralPath $radarPayload -PathType Leaf)) { throw "Missing file: $radarPayload" }
        $radarHasher = [System.Security.Cryptography.SHA256]::Create()
        $radarFileStream = [IO.File]::OpenRead($radarPayload)
        try { $radarHash = ([BitConverter]::ToString($radarHasher.ComputeHash($radarFileStream))).Replace('-','').ToLowerInvariant() }
        finally { $radarFileStream.Dispose(); $radarHasher.Dispose() }
        if ($radarHash -ne $radarFile.Value) { throw "File checksum mismatch: $($radarFile.Name). Extract the original package again." }
    }
    Write-Host 'PACKAGE_FILES_OK: matching bitstream, ELF and PS initialization.'
    if ($VerifyOnly) { Write-Host 'VERIFY_ONLY: no board access.'; exit 0 }

    if (!$XsdbPath) {
        $radarCandidates = New-Object System.Collections.Generic.List[string]
        $radarFound = Get-Command xsdb.bat -ErrorAction SilentlyContinue
        if ($radarFound) { $radarCandidates.Add($radarFound.Source) }
        foreach ($radarInstall in @($env:XILINX_VITIS, $env:XILINX_SDK)) {
            if ($radarInstall) { $radarCandidates.Add((Join-Path $radarInstall 'bin\xsdb.bat')) }
        }
        foreach ($radarDrive in @('C:','D:','E:','F:','G:')) {
            if (!(Test-Path -LiteralPath ($radarDrive+'\') -ErrorAction SilentlyContinue)) { continue }
            foreach ($radarParent in @('AMD','Xilinx','FPGA')) {
                $radarBase = Join-Path ($radarDrive+'\') $radarParent
                foreach ($radarPattern in @('2026.1\Vitis\bin\xsdb.bat','Vitis\2026.1\bin\xsdb.bat','Vitis\*\bin\xsdb.bat','*\Vitis\bin\xsdb.bat')) {
                    foreach ($radarEntry in @(Get-Item -Path (Join-Path $radarBase $radarPattern) -ErrorAction SilentlyContinue)) {
                        $radarCandidates.Add($radarEntry.FullName)
                    }
                }
            }
        }
        $XsdbPath = $radarCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (!$XsdbPath) { $XsdbPath = (Read-Host 'Paste the full path to installed Vitis bin\xsdb.bat').Trim().Trim('"') }
    }
    if (!(Test-Path -LiteralPath $XsdbPath -PathType Leaf)) { throw 'XSDB not found. Install AMD Vitis/JTAG drivers or pass -XsdbPath with the actual path.' }
    $radarXsdb = (Resolve-Path -LiteralPath $XsdbPath).Path
    Write-Host "Using XSDB: $radarXsdb"
    $radarLogDir = Join-Path $radarRoot 'logs'
    New-Item -ItemType Directory -Path $radarLogDir -Force | Out-Null
    $radarTmp = Join-Path $radarLogDir 'tmp'
    New-Item -ItemType Directory -Path $radarTmp -Force | Out-Null
    $env:TMP = $radarTmp
    $env:TEMP = $radarTmp
    function Test-RadarServer {
        $radarSocket = New-Object Net.Sockets.TcpClient
        try {
            $radarAttempt = $radarSocket.BeginConnect('127.0.0.1',3121,$null,$null)
            if (!$radarAttempt.AsyncWaitHandle.WaitOne(400)) { return $false }
            $radarSocket.EndConnect($radarAttempt)
            return $true
        } catch { return $false } finally { $radarSocket.Close() }
    }
    if (!(Test-RadarServer)) {
        $radarBin = Split-Path -Parent $radarXsdb
        $radarHwServer = Join-Path $radarBin 'unwrapped\win64.o\hw_server.exe'
        if (!(Test-Path -LiteralPath $radarHwServer)) { throw "No local hw_server at $radarHwServer. Start AMD hw_server or supply the Vitis bin\xsdb.bat path." }
        Start-Process -FilePath $radarHwServer -ArgumentList @('-s','tcp::3121') -WindowStyle Hidden -WorkingDirectory $radarLogDir | Out-Null
        $radarServerReady = $false
        for ($radarTry=0; $radarTry -lt 30; $radarTry++) {
            if (Test-RadarServer) { $radarServerReady=$true; break }
            Start-Sleep -Milliseconds 200
        }
        if (!$radarServerReady) { throw 'hw_server did not start on localhost:3121.' }
    }
    # Fresh, non-secret per-boot identity; do not reuse a fixed recorded nonce.
    $radarRandom = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $radarBytes = New-Object byte[] 8; $radarRandom.GetBytes($radarBytes) } finally { $radarRandom.Dispose() }
    $radarHi = [BitConverter]::ToUInt32($radarBytes,0)
    $radarLo = [BitConverter]::ToUInt32($radarBytes,4)
    if (($radarHi -eq 0) -and ($radarLo -eq 0)) { $radarLo=1 }
    $radarTclPath = (Join-Path $radarRoot 'download.tcl').Replace('\','/')
    if ($radarTclPath -match '[{}\r\n]') { throw 'Move this package to a folder without braces or line breaks in its path.' }
    $radarBootstrap = Join-Path $radarLogDir 'launch.tcl'
    # XSDB can load its first script using the Windows codepage. Keep that
    # bootstrap ASCII, decode the Unicode path explicitly, and source as UTF8.
    $radarEncodedPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($radarTclPath))
    $radarSourceCommand = 'source -encoding utf-8 [encoding convertfrom utf-8 [binary decode base64 {'+$radarEncodedPath+'}]]'
    $radarBody = ('set nonce_hi 0x{0:x8}' -f $radarHi), ('set nonce_lo 0x{0:x8}' -f $radarLo), $radarSourceCommand
    [IO.File]::WriteAllText($radarBootstrap, ($radarBody -join "`n")+"`n", (New-Object Text.UTF8Encoding($false)))
    $radarLog = Join-Path $radarLogDir ('download_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.log')
    Write-Host 'Downloading and starting the board. Keep power and JTAG connected.'
    $radarPreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $radarXsdb $radarBootstrap 2>&1 | Tee-Object -FilePath $radarLog
    $radarExit = $LASTEXITCODE
    $ErrorActionPreference = $radarPreviousPreference
    $radarText = Get-Content -LiteralPath $radarLog -Raw
    if (($radarExit -ne 0) -or ($radarText -notmatch 'DOWNLOAD_OK')) { throw "Download/start checks failed. Send this log: $radarLog" }
    Write-Host 'READY: board running. Keep the original PC receiver on UDP9000 with v3 support.'
    Write-Host 'This is volatile JTAG download. Download again after board power loss.'
    Write-Host "Log: $radarLog"
    exit 0
} catch {
    Write-Host ('FAILED: '+$_.Exception.Message) -ForegroundColor Red
    exit 1
}
