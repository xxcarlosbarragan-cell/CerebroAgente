$ErrorActionPreference = 'SilentlyContinue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- 1. MOTOR DE AUTO-ACTUALIZACIÓN EN LA NUBE ---
function Buscar-Actualizaciones {
    # REEMPLAZA "TuUsuario" en estas 3 líneas con tu nombre de usuario real de GitHub
    $urlVersion = "https://raw.githubusercontent.com/
xxcarlosbarragan-cell/CerebroAgente/main/version.txt"
    $urlScript  = "https://raw.githubusercontent.com/
xxcarlosbarragan-cell/CerebroAgente/main/CerebroAgent.ps1"
    $urlHtml    = "https://raw.githubusercontent.com/
xxcarlosbarragan-cell/CerebroAgente/main/interfaz.html"
    
    $versionLocal = 2.0

    try {
        Write-Host "Buscando actualizaciones en el servidor..."
        $versionRemotaTexto = Invoke-RestMethod -Uri $urlVersion -UseBasicParsing
        $versionRemota = [double]$versionRemotaTexto.Trim()
        
        if ($versionRemota -gt $versionLocal) {
            Write-Host "¡Nueva version encontrada: v$versionRemota! Descargando e instalando..."
            
            Invoke-WebRequest -Uri $urlScript -OutFile $PSCommandPath -UseBasicParsing
            Invoke-WebRequest -Uri $urlHtml -OutFile (Join-Path $script:Root "interfaz.html") -UseBasicParsing
            
            Write-Host "Actualizacion exitosa. Reiniciando Cerebro Agent..."
            Start-Sleep -Seconds 2
            
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            exit
        } else {
            Write-Host "Cerebro Agent esta actualizado (v$versionLocal)."
        }
    } catch {
        Write-Host "No hay conexion al servidor o el enlace es incorrecto. Iniciando en modo local."
    }
}

Buscar-Actualizaciones


# --- 2. MOTOR TÁCTICO DE SENSORES ---
function Get-FastSnapshot {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $totalGB = [math]::Round(([double]$os.TotalVisibleMemorySize / 1048576.0), 2)
    $freeGB = [math]::Round(([double]$os.FreePhysicalMemory / 1048576.0), 2)
    $ramPct = if ($totalGB -gt 0) { [math]::Round((1.0 - $freeGB / $totalGB) * 100.0, 0) } else { 0 }

    $cpuObj = Get-CimInstance Win32_Processor
    $cpuPct = if ($null -ne $cpuObj) { [math]::Round(($cpuObj.LoadPercentage | Measure-Object -Average).Average, 0) } else { 0 }

    $diskPct = 0
    $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    if ($null -ne $perf) { $diskPct = [math]::Min(100, [math]::Max(0, [int]$perf.PercentDiskTime)) }

    return @{ cpu = $cpuPct; ram = $ramPct; disk = $diskPct }
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
            $html = Get-Content -Raw -Path $htmlPath
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
        } else {
            $buffer = [System.Text.Encoding]::UTF8.GetBytes("Falta archivo interfaz.html")
        }
        $res.ContentType = "text/html"
    }
    $res.ContentLength64 = $buffer.Length
    $res.OutputStream.Write($buffer, 0, $buffer.Length)
    $res.Close()
}