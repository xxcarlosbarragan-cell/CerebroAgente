$ErrorActionPreference = 'SilentlyContinue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- 1. MOTOR DE AUTO-ACTUALIZACIÓN EN LA NUBE ---
function Buscar-Actualizaciones {
    $urlVersion = "https://raw.githubusercontent.com/xxCarlosbarragan-cell/CerebroAgente/main/version.txt"
    $urlScript  = "https://raw.githubusercontent.com/xxCarlosbarragan-cell/CerebroAgente/main/CerebroAgent.ps1"
    $urlHtml    = "https://raw.githubusercontent.com/xxCarlosbarragan-cell/CerebroAgente/main/interfaz.html"
    
    $versionLocal = 2.2

    try {
        Write-Host "Buscando actualizaciones..."
        $versionRemotaTexto = Invoke-RestMethod -Uri $urlVersion -UseBasicParsing
        $versionRemota = [double]$versionRemotaTexto.Trim()
        
        if ($versionRemota -gt $versionLocal) {
            Write-Host "¡Nueva version v$versionRemota! Instalando..."
            Invoke-WebRequest -Uri $urlScript -OutFile $PSCommandPath -UseBasicParsing
            Invoke-WebRequest -Uri $urlHtml -OutFile (Join-Path $script:Root "interfaz.html") -UseBasicParsing
            Start-Sleep -Seconds 2
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            exit
        }
    } catch {}
}

Buscar-Actualizaciones

# --- 2. MOTOR TÁCTICO ULTRARRÁPIDO ---
function Get-FastSnapshot {
    $cpuPct = 0; $ramPct = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $ramPct = [math]::Round((1.0 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100.0, 0)
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average
        $cpuPct = [math]::Round($cpu.Average, 0)
    } catch {}
    return @{ cpu = $cpuPct; ram = $ramPct }
}

$port = 5050
$url = "http://localhost:$port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)
$listener.Start()

Start-Process $url

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $req = $context.Request
    $res = $context.Response

    if ($req.Url.AbsolutePath -eq "/api/data") {
        $data = Get-FastSnapshot
        $json = ConvertTo-Json -InputObject $data
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
        $res.ContentType = "application/json"
    } else {
        $htmlPath = Join-Path $script:Root "interfaz.html"
        if (Test-Path $htmlPath) {
            # LA CORRECCIÓN CLAVE: Forzar a PowerShell a leer en UTF-8
            $html = Get-Content -Raw -Path $htmlPath -Encoding UTF8
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
        } else {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes("Falta archivo interfaz.html")
        }
        # LA CORRECCIÓN CLAVE: Decirle al navegador que use UTF-8
        $res.ContentType = "text/html; charset=utf-8"
    }
    $res.ContentLength64 = $buffer.Length
    $res.OutputStream.Write($buffer, 0, $buffer.Length)
    $res.Close()
}