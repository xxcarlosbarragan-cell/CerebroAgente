# Cerebro Agent 2.3 - servidor local ligero y actualizacion OTA.
# PowerShell 5.1 / Windows 10+; se preservan las URLs y el contrato GET /api/data.
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TestLocal = ($env:CEREBRO_PORTABLE_LOCAL_TEST -eq '1')
$script:DriveRoot = [System.IO.Path]::GetPathRoot($script:Root)
function Test-PortableDrive {
    if ($script:TestLocal) { return $true }
    try {
        $device = New-Object System.IO.DriveInfo($script:DriveRoot)
        return ($device.DriveType -eq [System.IO.DriveType]::Removable -and $device.IsReady)
    } catch { return $false }
}
if (-not (Test-PortableDrive)) {
    Write-Host 'Conecta una memoria USB y ejecuta Cerebro Agent desde ella.'
    exit 2
}
$script:LastClient = [DateTime]::UtcNow
$script:StopRequested = $false

function Buscar-Actualizaciones {
    # Direcciones oficiales existentes: no modificar.
    $urlVersion = "https://raw.githubusercontent.com/xxCarlosbarragan-cell/CerebroAgente/main/version.txt"
    $urlScript = "https://raw.githubusercontent.com/xxCarlosbarragan-cell/CerebroAgente/main/CerebroAgent.ps1"
    $urlHtml = "https://raw.githubusercontent.com/xxCarlosbarragan-cell/CerebroAgente/main/interfaz.html"

    $versionPath = Join-Path $script:Root 'version.txt'
    # Valor de recuperacion para el primer inicio de v2.3 desde la v2.2 sin archivo version.txt.
    $versionLocal = 2.3
    if (Test-Path -LiteralPath $versionPath) {
        try {
            $versionLocal = [double]::Parse(
                ([System.IO.File]::ReadAllText($versionPath)).Trim(),
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        } catch { $versionLocal = 2.3 }
    }

    # Ensure v2.2 OTA upgrades also receive the canonical version.txt file.
    # Only create the missing file; never delete legacy user files.
    if (-not (Test-Path -LiteralPath $versionPath)) {
        try {
            [System.IO.File]::WriteAllText(
                $versionPath, '2.3' + [Environment]::NewLine,
                (New-Object System.Text.UTF8Encoding($false))
            )
        } catch {
            Write-Warning ('No se pudo crear version.txt: ' + $_.Exception.Message)
        }
    }

    $tempScript = $null
    $tempHtml = $null
    try {
        $response = Invoke-RestMethod -Uri $urlVersion -UseBasicParsing -TimeoutSec 6
        $remoteText = ([string]$response).Trim()
        $versionRemote = [double]::Parse($remoteText, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($versionRemote -le $versionLocal) { return }
        Write-Host "Cerebro Agent: instalando version $remoteText desde GitHub..."

        $tempScript = Join-Path $script:Root ([System.IO.Path]::GetRandomFileName() + '.ps1.tmp')
        $tempHtml = Join-Path $script:Root ([System.IO.Path]::GetRandomFileName() + '.html.tmp')
        Invoke-WebRequest -Uri $urlScript -OutFile $tempScript -UseBasicParsing -TimeoutSec 20
        Invoke-WebRequest -Uri $urlHtml -OutFile $tempHtml -UseBasicParsing -TimeoutSec 20

        # Comprobaciones basicas de archivos completos; no sustituyen una firma digital.
        $newScript = Get-Content -LiteralPath $tempScript -Raw -Encoding UTF8
        $newHtml = Get-Content -LiteralPath $tempHtml -Raw -Encoding UTF8
        if (($newScript -notmatch 'Get-FastSnapshot') -or
            ($newScript -notmatch 'HttpListener') -or
            ($newHtml -notmatch '<html') -or
            ($newHtml -notmatch '</html>')) {
            throw 'Descarga incompleta o formato inesperado: se cancela la actualizacion.'
        }

        $htmlPath = Join-Path $script:Root 'interfaz.html'
        # Guardar en RAM para recuperar los archivos anteriores si la copia falla.
        $oldScript = [System.IO.File]::ReadAllBytes($PSCommandPath)
        $oldHtml = $null
        if (Test-Path -LiteralPath $htmlPath) {
            $oldHtml = [System.IO.File]::ReadAllBytes($htmlPath)
        }
        try {
            [System.IO.File]::Copy($tempHtml, $htmlPath, $true)
            [System.IO.File]::Copy($tempScript, $PSCommandPath, $true)
            [System.IO.File]::WriteAllText(
                $versionPath, $remoteText + [Environment]::NewLine,
                (New-Object System.Text.UTF8Encoding($false))
            )
        } catch {
            [System.IO.File]::WriteAllBytes($PSCommandPath, $oldScript)
            if ($null -ne $oldHtml) {
                [System.IO.File]::WriteAllBytes($htmlPath, $oldHtml)
            }
            throw
        }

        Write-Host 'Actualizacion descargada; reiniciando servidor local.'
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    } catch {
        Write-Warning ("OTA no disponible: " + $_.Exception.Message)
    } finally {
        if ($tempScript -and (Test-Path -LiteralPath $tempScript)) { Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue }
        if ($tempHtml -and (Test-Path -LiteralPath $tempHtml)) { Remove-Item -LiteralPath $tempHtml -Force -ErrorAction SilentlyContinue }
    }
}

# OTA deshabilitada en portable: requiere autorizacion antes de actualizar.
# Buscar-Actualizaciones
# REGLA DE RENDIMIENTO: no consultar Win32_PerfFormattedData_PerfDisk_PhysicalDisk.
# La lectura se limita a CPU y RAM, tal como en la version 2.2.
function Get-FastSnapshot {
    $cpuPct = $null
    $ramPct = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.TotalVisibleMemorySize -gt 0) {
            $ramPct = [math]::Round((1.0 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100.0, 0)
        }
    } catch { }
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average
        if ($null -ne $cpu.Average) { $cpuPct = [math]::Round($cpu.Average, 0) }
    } catch { }
    return @{ cpu = $cpuPct; ram = $ramPct }
}

$port = 5050
$url = "http://localhost:$port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)
try {
    $listener.Start()
    Start-Process $url
    while ($listener.IsListening -and -not $script:StopRequested) {
        if (-not (Test-PortableDrive)) { break }
        if (([DateTime]::UtcNow - $script:LastClient).TotalSeconds -gt 120) { break }
        $pending = $listener.BeginGetContext($null, $null)
        while (-not $pending.AsyncWaitHandle.WaitOne(4000)) {
            if (-not (Test-PortableDrive) -or
                ([DateTime]::UtcNow - $script:LastClient).TotalSeconds -gt 120) {
                $script:StopRequested = $true
                break
            }
        }
        if ($script:StopRequested) { $pending.AsyncWaitHandle.Close(); break }
        $context = $listener.EndGetContext($pending)
        $pending.AsyncWaitHandle.Close()
        $script:LastClient = [DateTime]::UtcNow
        $res = $context.Response
        try {
            if ($context.Request.Url.AbsolutePath -eq '/api/stop' -and $context.Request.HttpMethod -eq 'POST') {
                $script:StopRequested = $true
                $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"stopped":true}')
                $res.ContentType = 'application/json; charset=utf-8'
            } elseif ($context.Request.Url.AbsolutePath -eq '/api/data') {
                $data = Get-FastSnapshot
                $json = ConvertTo-Json -InputObject $data -Compress
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
                $res.ContentType = 'application/json; charset=utf-8'
                $res.Headers.Add('Cache-Control', 'no-store')
            } else {
                $htmlPath = Join-Path $script:Root 'interfaz.html'
                if (Test-Path -LiteralPath $htmlPath) {
                    # Codificacion UTF-8 necesaria para emojis y caracteres especiales.
                    $html = Get-Content -Raw -Path $htmlPath -Encoding UTF8
                } else {
                    $html = 'Falta archivo interfaz.html'
                }
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
                $res.ContentType = 'text/html; charset=utf-8'
                $res.Headers.Add('Cache-Control', 'no-store')
            }
            $res.ContentLength64 = $buffer.Length
            $res.OutputStream.Write($buffer, 0, $buffer.Length)
        } catch {
            Write-Warning ("Solicitud local: " + $_.Exception.Message)
        } finally {
            $res.Close()
        }
    }
} finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
