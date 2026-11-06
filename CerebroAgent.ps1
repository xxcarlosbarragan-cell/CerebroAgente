# Cerebro Agent 2.0 - Windows PowerShell 5.1 / Windows 10
# Diagnostico y vigilancia local. Sin reparaciones automaticas, red ni privilegios permanentes.
# Ejecutar desde Iniciar_Cerebro_Agent.cmd, con autorizacion del propietario.

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DataDir = Join-Path $env:LOCALAPPDATA 'CerebroAgent'
$script:LogPath = Join-Path $script:DataDir 'historial.jsonl'
$script:ReportsDir = Join-Path $script:DataDir 'Informes'
$script:StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Cerebro Agent.lnk'
$script:LastSnapshot = $null
$script:ConsecutiveHighDisk = 0
$script:ConsecutiveLowMemory = 0
$script:Monitoring = $true
$script:Busy = $false

if (!(Test-Path -LiteralPath $script:DataDir)) { New-Item -Path $script:DataDir -ItemType Directory -Force | Out-Null }
if (!(Test-Path -LiteralPath $script:ReportsDir)) { New-Item -Path $script:ReportsDir -ItemType Directory -Force | Out-Null }

function Save-AgentRecord {
    param([string]$Kind, [object]$Data)
    try {
        $record = [ordered]@{ date = (Get-Date).ToString('o'); type = $Kind; data = $Data }
        $json = ConvertTo-Json -InputObject $record -Depth 7 -Compress
        Add-Content -LiteralPath $script:LogPath -Value $json -Encoding UTF8 -ErrorAction Stop
    } catch { } # Una falla de escritura no debe bloquear la interfaz.
}

function Get-AgentSnapshot {
    param([switch]$Detailed)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    $totalGB = [math]::Round(([double]$os.TotalVisibleMemorySize / 1048576.0), 2)
    $freeGB = [math]::Round(([double]$os.FreePhysicalMemory / 1048576.0), 2)
    $memoryUsedPct = if ($totalGB -gt 0) { [math]::Round((1.0 - $freeGB / $totalGB) * 100.0, 1) } else { $null }
    $freeDiskGB = if ($null -ne $drive) { [math]::Round(([double]$drive.FreeSpace / 1GB), 1) } else { $null }
    $diskSizeGB = if ($null -ne $drive) { [math]::Round(([double]$drive.Size / 1GB), 1) } else { $null }
    $diskActivePct = $null
    $queueLength = $null
    try {
        # Muestra formateada de rendimiento. Es orientativa; no certifica fallo fisico.
        $perf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -ErrorAction Stop |
            Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
        if ($null -ne $perf) {
            # PercentDiskTime puede superar 100 en contadores agregados. No presentarlo como uso porcentual real.
            $rawDiskTime = [double]$perf.PercentDiskTime
            $diskActivePct = [math]::Round([math]::Min(100.0,[math]::Max(0.0,$rawDiskTime)),1)
            $queueLength = [math]::Round([double]$perf.CurrentDiskQueueLength, 0)
        }
    } catch { }

    $snapshot = [ordered]@{
        date = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
        windows = [string]$os.Caption
        totalRamGB = $totalGB
        freeRamGB = $freeGB
        memoryUsedPct = $memoryUsedPct
        diskActivePct = $diskActivePct
        diskQueueLength = $queueLength
        cFreeGB = $freeDiskGB
        cTotalGB = $diskSizeGB
        diskModel = $null
        diskMediaType = $null
        physicalDiskStatus = $null
        services = @()
        topMemoryProcesses = @()
        diskEvents = @()
        notes = @()
    }
    if ($Detailed) {
        try {
            $pd = Get-PhysicalDisk -ErrorAction Stop | Select-Object -First 1
            if ($null -ne $pd) {
                $snapshot.diskModel = [string]$pd.FriendlyName
                $snapshot.diskMediaType = [string]$pd.MediaType
                $snapshot.physicalDiskStatus = [string]$pd.HealthStatus
            }
        } catch { $snapshot.notes += 'No fue posible consultar el estado fisico del disco.' }
        try {
            $snapshot.topMemoryProcesses = @(
                Get-Process -ErrorAction Stop | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 |
                    ForEach-Object { [ordered]@{ name = $_.ProcessName; pid = $_.Id; ramMB = [math]::Round($_.WorkingSet64 / 1MB, 1) } }
            )
        } catch { $snapshot.notes += 'No se pudo completar la lista de procesos.' }
        try {
            $snapshot.services = @(
                Get-Service -Name 'SysMain','WinDefend','wuauserv' -ErrorAction SilentlyContinue |
                    ForEach-Object { [ordered]@{ name = $_.Name; status = [string]$_.Status } }
            )
        } catch { }
        try {
            $ids = @(7,11,15,51,55,129,153,157)
            $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $ids; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 60 -ErrorAction Stop |
                Where-Object { $_.ProviderName -match '(?i)disk|ntfs|stor|partmgr|volmgr' } | Select-Object -First 12)
            $snapshot.diskEvents = @($events | ForEach-Object {
                [ordered]@{ time = $_.TimeCreated.ToString('o'); id = $_.Id; provider = $_.ProviderName; message = ([string]$_.Message -replace '[\r\n]+',' ') }
            })
        } catch {
            # No encontrado o acceso insuficiente: no equivale a 'sin errores'.
            $snapshot.notes += 'No se obtuvieron eventos del sistema (sin coincidencias o sin acceso).'
        }
    }
    return [pscustomobject]$snapshot
}

function Get-AgentAssessment {
    param([object]$Snapshot, [switch]$Repeated)
    $alerts = New-Object 'System.Collections.Generic.List[string]'
    $advice = New-Object 'System.Collections.Generic.List[string]'

    if ($Snapshot.memoryUsedPct -ge 90) {
        $alerts.Add('RAM muy ocupada: ' + $Snapshot.memoryUsedPct + ' %.')
        $advice.Add('Cerrar voluntariamente pestanas y aplicaciones no necesarias. No forzar el cierre de procesos del sistema.')
    } elseif ($Snapshot.memoryUsedPct -ge 85) {
        $alerts.Add('RAM alta: ' + $Snapshot.memoryUsedPct + ' %.')
        $advice.Add('Con aproximadamente 4 GB de RAM, varias aplicaciones pueden causar paginacion al HDD.')
    }
    if ($null -ne $Snapshot.diskActivePct -and $Snapshot.diskActivePct -ge 90) {
        if ($Repeated -and $script:ConsecutiveHighDisk -ge 3) {
            $alerts.Add('Disco ocupado >= 90 % en tres comprobaciones seguidas.')
            $advice.Add('Abrir Monitor de recursos > Disco y comprobar procesos, tiempos de respuesta y cola. Hacer respaldo antes de intervenciones.')
        } else {
            $alerts.Add('Una medicion del disco fue alta (' + $Snapshot.diskActivePct + ' %). Aun no prueba saturacion persistente.')
        }
    }
    if ($null -eq $Snapshot.diskActivePct) {
        $advice.Add('Contador de actividad del disco no disponible. Verificar actividad desde Administrador de tareas o Monitor de recursos.')
    }
    if ($Snapshot.cTotalGB -gt 0 -and ($Snapshot.cFreeGB / $Snapshot.cTotalGB) -lt 0.15) {
        $alerts.Add('Queda menos del 15 % libre en C:.')
        $advice.Add('Revisar almacenamiento y liberar espacio con herramientas de Windows, sin borrar archivos automaticamente.')
    }
    if (@($Snapshot.diskEvents).Count -gt 0) {
        $alerts.Add('Se encontraron eventos de sistema asociados a posibles errores de almacenamiento.')
        $advice.Add('Respaldar datos; revisar detalle de eventos y ejecutar diagnostico especializado antes de reparar o cambiar hardware.')
    }
    if ($alerts.Count -eq 0) { $advice.Add('No se detectaron umbrales criticos en esta muestra. Eso no garantiza ausencia de problemas.') }
    $advice.Add('Windows 10 requiere un plan de actualizaciones de seguridad (ESU o migracion compatible).')
    return [pscustomobject]@{ alerts = @($alerts.ToArray()); recommendations = @($advice.ToArray()) }
}

function Format-AgentReport {
    param([object]$Snapshot, [object]$Assessment)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('CEREBRO AGENT 2.0 - INFORME LOCAL')
    $lines.Add('Fecha: ' + $Snapshot.date)
    $lines.Add('Equipo: ' + $Snapshot.computer)
    $lines.Add('Windows: ' + $Snapshot.windows)
    $lines.Add(('RAM: {0} GB totales | {1} GB libres | {2}% ocupada' -f $Snapshot.totalRamGB,$Snapshot.freeRamGB,$Snapshot.memoryUsedPct))
    $diskPctText = if ($null -eq $Snapshot.diskActivePct) { 'sin dato' } else { [string]$Snapshot.diskActivePct + ' %' }
    $lines.Add('Actividad de disco, muestra puntual: ' + $diskPctText)
    $lines.Add(('Unidad C: {0} GB libres de {1} GB' -f $Snapshot.cFreeGB,$Snapshot.cTotalGB))
    $lines.Add('Disco: ' + $Snapshot.diskModel + ' | Tipo: ' + $Snapshot.diskMediaType + ' | Estado informado: ' + $Snapshot.physicalDiskStatus)
    $lines.Add('')
    $lines.Add('ALERTAS')
    if ($Assessment.alerts.Count -eq 0) { $lines.Add('- Ninguna en umbrales actuales') }
    foreach ($a in $Assessment.alerts) { $lines.Add('- ' + $a) }
    $lines.Add('')
    $lines.Add('RECOMENDACIONES')
    foreach ($r in $Assessment.recommendations) { $lines.Add('- ' + $r) }
    if (@($Snapshot.services).Count -gt 0) {
        $lines.Add('')
        $lines.Add('SERVICIOS')
        foreach ($s in $Snapshot.services) { $lines.Add(('- {0}: {1}' -f $s.name,$s.status)) }
    }
    if (@($Snapshot.topMemoryProcesses).Count -gt 0) {
        $lines.Add('')
        $lines.Add('TOP DE MEMORIA POR PROCESO (instantanea)')
        foreach ($p in $Snapshot.topMemoryProcesses) { $lines.Add(('- {0} (PID {1}): {2} MB' -f $p.name,$p.pid,$p.ramMB)) }
    }
    if (@($Snapshot.diskEvents).Count -gt 0) {
        $lines.Add('')
        $lines.Add('EVENTOS A REVISAR (pueden tener causas distintas al HDD)')
        foreach ($ev in $Snapshot.diskEvents) { $lines.Add(('- {0} | {1} | ID {2}: {3}' -f $ev.time,$ev.provider,$ev.id,$ev.message)) }
    }
    foreach ($n in $Snapshot.notes) { $lines.Add('NOTA: ' + $n) }
    $lines.Add('')
    $lines.Add('IMPORTANTE: Las mediciones no certifican salud SMART, ni identifican por si solas la causa del 100% de disco.')
    $lines.Add('PRIVACIDAD: este informe se guarda localmente. Antes de compartirlo, revisa nombres de equipo, procesos y eventos.')
    return ($lines -join [Environment]::NewLine)
}

function Say-Agent {
    param([string]$Message)
    $script:ChatBox.AppendText(('[' + (Get-Date -Format 'HH:mm') + '] CEREBRO: ' + $Message + [Environment]::NewLine + [Environment]::NewLine))
    $script:ChatBox.SelectionStart = $script:ChatBox.TextLength
    $script:ChatBox.ScrollToCaret()
}

function Update-AgentStatus {
    param([object]$Snapshot, [object]$Assessment)
    $diskText = if ($null -eq $Snapshot.diskActivePct) { 's/d' } else { [string]$Snapshot.diskActivePct + '%' }
    $script:VitalsLabel.Text = ('RAM: {0}% | Disco: {1} | C: libre {2} GB' -f $Snapshot.memoryUsedPct,$diskText,$Snapshot.cFreeGB)
    if ($Assessment.alerts.Count -gt 0) {
        $script:StateLabel.Text = 'Atencion: ' + $Assessment.alerts[0]
        $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(226,169,83)
    } else {
        $script:StateLabel.Text = 'Sin alerta inmediata en esta medicion (no es certificado de salud).'
        $script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(128,211,182)
    }
    $script:LastSnapshot = $Snapshot
}

function Run-AgentCheck {
    param([bool]$Detailed = $false, [bool]$Silent = $false)
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        $script:StateLabel.Text = 'Consultando Windows...'
        [System.Windows.Forms.Application]::DoEvents()
        $s = Get-AgentSnapshot -Detailed:$Detailed
        if ($null -ne $s.diskActivePct -and $s.diskActivePct -ge 90) {
            $script:ConsecutiveHighDisk++
        } else { $script:ConsecutiveHighDisk = 0 }
        if ($s.memoryUsedPct -ge 90) { $script:ConsecutiveLowMemory++ } else { $script:ConsecutiveLowMemory = 0 }
        $a = Get-AgentAssessment -Snapshot $s -Repeated
        Update-AgentStatus -Snapshot $s -Assessment $a
        Save-AgentRecord -Kind 'check' -Data ([ordered]@{ ramUsedPct = $s.memoryUsedPct; diskPct = $s.diskActivePct; diskFreeGB = $s.cFreeGB; alerts = $a.alerts })
        if (!$Silent -or ($script:ConsecutiveHighDisk -eq 3) -or ($script:ConsecutiveLowMemory -eq 3)) {
            $headline = if ($a.alerts.Count -gt 0) { $a.alerts -join ' ' } else { 'Sin umbrales criticos en esta muestra.' }
            Say-Agent ('Resultado: ' + $headline + ' Recomendacion: ' + ($a.recommendations | Select-Object -First 1))
        }
        return [pscustomobject]@{ snapshot = $s; assessment = $a }
    } catch {
        Save-AgentRecord -Kind 'error' -Data ([ordered]@{ message = $_.Exception.Message })
        $script:StateLabel.Text = 'No fue posible obtener todas las mediciones.'
        if (!$Silent) { Say-Agent ('Windows no entrego datos: ' + $_.Exception.Message + '. No he realizado modificaciones.') }
        return $null
    } finally { $script:Busy = $false }
}

function Export-AgentReport {
    $result = Run-AgentCheck -Detailed $true -Silent $true
    if ($null -eq $result) { Say-Agent 'No se pudo generar el informe. Consulta el historial local.'; return }
    $file = Join-Path $script:ReportsDir ('Informe_Cerebro_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
    $content = Format-AgentReport -Snapshot $result.snapshot -Assessment $result.assessment
    [System.IO.File]::WriteAllText($file, $content, [System.Text.Encoding]::UTF8)
    Save-AgentRecord -Kind 'export' -Data @{ path = $file }
    Say-Agent ('Informe creado en: ' + $file + '. Revísalo antes de compartirlo.')
    Start-Process explorer.exe -ArgumentList ('"' + $script:ReportsDir + '"')
}

function Set-AgentAutoStart {
    param([bool]$Enable)
    if ($Enable) {
        $choice = [System.Windows.Forms.MessageBox]::Show('Esto iniciara Cerebro Agent cuando abras sesion en Windows. Solo vigilara y generara informes. ¿Lo autorizas?', 'Autorizacion de inicio automatico', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { Say-Agent 'Inicio automatico no activado.'; return }
        $launcher = Join-Path $script:Root 'Iniciar_Cerebro_Agent.cmd'
        if (!(Test-Path -LiteralPath $launcher)) { Say-Agent 'No se encontro el iniciador .cmd en la carpeta.'; return }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($script:StartupLink)
        $shortcut.TargetPath = $launcher
        $shortcut.WorkingDirectory = $script:Root
        $shortcut.Description = 'Cerebro Agent - vigilancia local con control del usuario'
        $shortcut.Save()
        Say-Agent 'Inicio automatico activado para tu usuario. Puedes quitarlo desde el boton correspondiente.'
    } else {
        if (Test-Path -LiteralPath $script:StartupLink) {
            $choice = [System.Windows.Forms.MessageBox]::Show('¿Quitar Cerebro Agent del inicio de Windows?', 'Confirmar cambio', [System.Windows.Forms.MessageBoxButtons]::YesNo)
            if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                Remove-Item -LiteralPath $script:StartupLink -Force
                Say-Agent 'Inicio automatico desactivado.'
            }
        } else { Say-Agent 'El inicio automatico no estaba activado.' }
    }
}

function Handle-AgentQuestion {
    param([string]$Question)
    $q = $Question.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($q)) { return }
    $script:ChatBox.AppendText(('[' + (Get-Date -Format 'HH:mm') + '] TU: ' + $Question + [Environment]::NewLine))
    if ($q -match 'diagnostic|analiz|revis|estado|comprueba') {
        Say-Agent 'Haré un diagnóstico nuevo, no una reparación.'
        [void](Run-AgentCheck -Detailed $true -Silent $false)
    } elseif ($q -match 'ram|memoria|lenta|rendimiento') {
        if ($null -eq $script:LastSnapshot) { Say-Agent 'Todavia no hay una medicion local. Pulsa Analizar ahora.' }
        else { Say-Agent (('La memoria estaba {0}% ocupada, con {1} GB libres. Con 4 GB y un HDD, cerrar aplicaciones sobrantes puede ayudar; no cerrare procesos por ti.' -f $script:LastSnapshot.memoryUsedPct,$script:LastSnapshot.freeRamGB)) }
    } elseif ($q -match 'disco|hdd|ssd|100%|almacenamiento') {
        $value = if ($null -ne $script:LastSnapshot -and $null -ne $script:LastSnapshot.diskActivePct) { [string]$script:LastSnapshot.diskActivePct + '%' } else { 'sin medicion disponible' }
        Say-Agent ('Ultima actividad de disco: ' + $value + '. Tu informe historico identifico un HDD Western Digital de 500 GB sin prediccion SMART de fallo; eso no descarta degradacion. Utiliza Monitor de recursos para ver actividad por proceso.')
    } elseif ($q -match 'defender|antivirus|virus|msmpeng') {
        Say-Agent 'El informe historico muestra tiempo de CPU acumulado alto de MsMpEng, no un porcentaje instantaneo. No conviene desactivar Microsoft Defender sin una causa comprobada.'
    } elseif ($q -match 'respal|backup|copia') {
        Say-Agent 'Antes de cambiar o reparar el disco, verifica que tus carpetas importantes esten respaldadas y prueba abrir una copia. No copiare archivos ni accedere a Google Drive automaticamente.'
    } elseif ($q -match 'arregl|repar|soluc|optimiza|limpi') {
        Say-Agent 'Puedo investigar y proponer correcciones, pero esta version no borra archivos, no desactiva servicios ni ejecuta reparaciones. Abrir Monitor de recursos es el paso seguro para identificar el origen del 100% de disco. Reparaciones posteriores requeriran tu aprobacion especifica.'
    } elseif ($q -match 'inicio|arranque|programas') {
        Say-Agent 'Puedes revisar programas de inicio desde el Administrador de tareas > Inicio. No deshabilitare aplicaciones automaticamente.'
    } elseif ($q -match 'actualiz|windows 10|seguridad|esu') {
        Say-Agent 'Windows 10 salio del soporte general el 14 de octubre de 2025. Conviene verificar inscripcion ESU o compatibilidad con Windows 11 antes de hacer cambios.'
    } elseif ($q -match 'ayuda|que puedes|comandos|funcion|hola') {
        Say-Agent 'Puedo hacer un diagnostico, vigilar RAM y actividad de disco, avisar de umbrales, revisar eventos, abrir Monitor de recursos y crear informes. Prueba: analiza, disco, memoria, respaldo, Defender, reparar, seguridad. Mis respuestas son reglas locales, no IA generativa.'
    } elseif ($q -match 'gracias|adios') {
        Say-Agent 'Cuando necesites una revision, pulsa Analizar ahora. No haré cambios en Windows sin que lo solicites.'
    } else {
        Say-Agent 'Todavia no comprendo preguntas generales. Soy un agente local basado en reglas y mediciones, no una IA conversacional completa. Puedo ayudarte con: disco, RAM, diagnostico, respaldo, seguridad y reparaciones supervisadas.'
    }
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
} catch {
    Write-Host 'No se pudo abrir la interfaz grafica de Windows Forms.'
    Write-Host $_.Exception.Message
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Cerebro Agent 2.0 | Tu trabajador digital'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1000,730)
$form.MinimumSize = New-Object System.Drawing.Size(800,650)
$form.BackColor = [System.Drawing.Color]::FromArgb(19,27,39)
$form.ForeColor = [System.Drawing.Color]::FromArgb(235,241,246)
$form.Font = New-Object System.Drawing.Font('Segoe UI',10)

$header = New-Object System.Windows.Forms.Label
$header.Text = 'CEREBRO AGENT'
$header.Location = New-Object System.Drawing.Point(24,18)
$header.Size = New-Object System.Drawing.Size(700,36)
$header.Font = New-Object System.Drawing.Font('Segoe UI Semibold',20)
$header.ForeColor = [System.Drawing.Color]::FromArgb(235,241,246)
$form.Controls.Add($header)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = 'Trabajador local | Diagnostica, vigila y recomienda | Sin reparaciones automaticas'
$sub.Location = New-Object System.Drawing.Point(25,59)
$sub.Size = New-Object System.Drawing.Size(925,29)
$sub.ForeColor = [System.Drawing.Color]::FromArgb(172,187,205)
$form.Controls.Add($sub)

$script:VitalsLabel = New-Object System.Windows.Forms.Label
$script:VitalsLabel.Text = 'RAM: pendiente | Disco: pendiente | C: pendiente'
$script:VitalsLabel.Location = New-Object System.Drawing.Point(26,103)
$script:VitalsLabel.Size = New-Object System.Drawing.Size(925,26)
$script:VitalsLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold',11)
$form.Controls.Add($script:VitalsLabel)

$script:StateLabel = New-Object System.Windows.Forms.Label
$script:StateLabel.Text = 'Sin medicion actual. Pulsa Analizar ahora.'
$script:StateLabel.Location = New-Object System.Drawing.Point(26,132)
$script:StateLabel.Size = New-Object System.Drawing.Size(925,37)
$script:StateLabel.ForeColor = [System.Drawing.Color]::FromArgb(226,169,83)
$form.Controls.Add($script:StateLabel)

function New-AgentButton {
    param([string]$Text,[int]$X,[int]$Y,[int]$W)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X,$Y)
    $b.Size = New-Object System.Drawing.Size($W,40)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.BackColor = [System.Drawing.Color]::FromArgb(47,70,91)
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(77,103,125)
    $form.Controls.Add($b)
    return $b
}

$btnAnalyze = New-AgentButton 'Analizar ahora' 26 181 170
$btnMonitor = New-AgentButton 'Detener vigilancia' 208 181 170
$btnExport = New-AgentButton 'Crear informe' 390 181 165
$btnResources = New-AgentButton 'Monitor de recursos' 567 181 180
$btnStartup = New-AgentButton 'Iniciar con Windows' 26 230 200
$btnRemoveStartup = New-AgentButton 'Quitar inicio automatico' 238 230 220
$btnTaskMgr = New-AgentButton 'Administrador tareas' 470 230 220
$btnInvestigate = New-AgentButton 'Investigar y proponer' 702 230 249

$script:ChatBox = New-Object System.Windows.Forms.TextBox
$script:ChatBox.Location = New-Object System.Drawing.Point(26,293)
$script:ChatBox.Size = New-Object System.Drawing.Size(925,280)
$script:ChatBox.Multiline = $true
$script:ChatBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:ChatBox.ReadOnly = $true
$script:ChatBox.BackColor = [System.Drawing.Color]::FromArgb(29,40,54)
$script:ChatBox.ForeColor = [System.Drawing.Color]::FromArgb(237,242,248)
$script:ChatBox.Font = New-Object System.Drawing.Font('Consolas',10)
$script:ChatBox.Anchor = ([System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($script:ChatBox)

$input = New-Object System.Windows.Forms.TextBox
$input.Location = New-Object System.Drawing.Point(26,585)
$input.Size = New-Object System.Drawing.Size(800,33)
$input.BackColor = [System.Drawing.Color]::FromArgb(243,246,249)
$input.ForeColor = [System.Drawing.Color]::FromArgb(35,46,55)
$input.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($input)
$btnSend = New-AgentButton 'Preguntar' 839 581 112
$btnSend.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right)
$input.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)

$footer = New-Object System.Windows.Forms.Label
$footer.Text = 'Los informes quedan en %LOCALAPPDATA%\CerebroAgent. No se envian a Internet.'
$footer.Location = New-Object System.Drawing.Point(28,635)
$footer.Size = New-Object System.Drawing.Size(900,35)
$footer.ForeColor = [System.Drawing.Color]::FromArgb(172,187,205)
$footer.Anchor = ([System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$form.Controls.Add($footer)

# Investigacion bajo demanda: lectura solamente, sin cambios en el sistema.
function Invoke-AgentInvestigation {
    if ($script:Busy) { Say-Agent 'Espera a que termine la medicion actual.'; return }
    $result = Run-AgentCheck -Detailed $true -Silent $true
    if ($null -eq $result) { Say-Agent 'No se pudo investigar. Consulta el historial.'; return }
    $s = $result.snapshot
    $ideas = New-Object System.Collections.Generic.List[string]
    if ($s.memoryUsedPct -ge 85) {
        $ideas.Add('RAM elevada: revisar programas de inicio y pestanas abiertas. Propuesta para tu aprobacion: cerrar solo aplicaciones elegidas por ti. No se cerro ninguna.')
    }
    if ($null -ne $s.diskActivePct -and $s.diskActivePct -ge 90) {
        $ideas.Add('Disco muy activo: observar Monitor de recursos y tiempos de respuesta. No detener servicios ni desactivar Defender.')
    }
    if (@($s.diskEvents).Count -gt 0) {
        $ideas.Add('Hay eventos de almacenamiento: respaldar datos y revisar salud SMART con herramienta especializada antes de reparar.')
    }
    if ($s.diskMediaType -eq 'HDD') {
        $ideas.Add('Equipo con HDD: evaluar sustitucion por SSD tras respaldo y comprobacion de compatibilidad.')
    }
    if ($ideas.Count -eq 0) { $ideas.Add('No hay causa confirmada en esta muestra. Comparar varias mediciones antes de actuar.') }
    $path = Join-Path $script:ReportsDir ('Investigacion_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
    $lines = @('CEREBRO AGENT - INVESTIGACION SUPERVISADA','Fecha: ' + (Get-Date).ToString('s'),'Modo: SOLO LECTURA. Ninguna reparacion ejecutada.','', 'Observaciones:', ('RAM: {0}%; disco (indicador limitado a 0-100): {1}%; espacio libre: {2} GB' -f $s.memoryUsedPct,$s.diskActivePct,$s.cFreeGB),'','HIPOTESIS Y PROPUESTAS (NO EJECUTADAS):') + @($ideas | ForEach-Object { '- ' + $_ })
    [System.IO.File]::WriteAllLines($path,[string[]]$lines,[System.Text.Encoding]::UTF8)
    Save-AgentRecord -Kind 'investigation' -Data @{ report = $path; proposals = @($ideas) }
    Say-Agent ('Investigacion terminada. ' + ($ideas -join ' ') + ' Informe: ' + $path)
    Start-Process explorer.exe -ArgumentList ('"' + $script:ReportsDir + '"')
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 120000 # 2 minutos. Se consulta el estado sin aplicaciones residentes adicionales.
$timer.Add_Tick({
    if ($script:Monitoring -and !$script:Busy) { [void](Run-AgentCheck -Detailed $false -Silent $true) }
})
$btnInvestigate.Add_Click({ Invoke-AgentInvestigation })
$btnAnalyze.Add_Click({ [void](Run-AgentCheck -Detailed $true -Silent $false) })
$btnExport.Add_Click({ Export-AgentReport })
$btnResources.Add_Click({ try { Start-Process 'resmon.exe' } catch { Say-Agent ('No pude abrir Monitor de recursos: ' + $_.Exception.Message) } })
$btnTaskMgr.Add_Click({ try { Start-Process 'taskmgr.exe' } catch { Say-Agent ('No pude abrir Administrador de tareas: ' + $_.Exception.Message) } })
$btnMonitor.Add_Click({
    $script:Monitoring = !$script:Monitoring
    if ($script:Monitoring) {
        $timer.Start(); $btnMonitor.Text = 'Detener vigilancia'
        Say-Agent 'Vigilancia activada: una medicion ligera cada 2 minutos, mientras esta ventana permanezca abierta.'
    } else {
        $timer.Stop(); $btnMonitor.Text = 'Reanudar vigilancia'
        Say-Agent 'Vigilancia en pausa. No se seguiran tomando mediciones hasta reactivarla.'
    }
})
$btnStartup.Add_Click({ try { Set-AgentAutoStart -Enable $true } catch { Say-Agent ('No pude activar inicio automatico: ' + $_.Exception.Message) } })
$btnRemoveStartup.Add_Click({ try { Set-AgentAutoStart -Enable $false } catch { Say-Agent ('No pude quitar inicio automatico: ' + $_.Exception.Message) } })
$btnSend.Add_Click({ $text = $input.Text; $input.Clear(); Handle-AgentQuestion -Question $text })
$input.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $_.SuppressKeyPress = $true; $btnSend.PerformClick() } })
$form.Add_Shown({
    Say-Agent 'Estoy listo. Tu informe del 5 de noviembre indico HDD de 500 GB y RAM libre muy baja; esos datos son historicos, no una medicion actual.'
    Say-Agent 'Vigilo tu equipo cada dos minutos mientras permanezca abierto. No reparo ni cierro nada sin autorizacion.'
    [void](Run-AgentCheck -Detailed $false -Silent $false)
    if ($script:Monitoring) { $timer.Start() }
})
$form.Add_FormClosing({ $timer.Stop() })
try { [void][System.Windows.Forms.Application]::Run($form) }
finally { $timer.Dispose(); $form.Dispose() }
