# =============================================================================
#  mock-server.ps1 - Simulador local del ESP32 para probar el dashboard SIN placa.
#
#  Replica la misma API que el firmware ProyectoSueloESP32.ino:
#    GET  /                       -> panel (dashboard.html)
#    GET  /mock                   -> panel de control del simulador
#    GET  /api/status
#    GET  /api/preview?ph_present=0|1
#    POST /api/save
#    POST /api/calibrar
#    GET  /api/csv  (y ?view=1)
#    GET  /mock/state | /mock/set?hum_mv=..&ph_mv=.. | /mock/reset | /mock/seed
#
#  Uso:  powershell -ExecutionPolicy Bypass -File tools\mock-server.ps1 [-Port 8080]
#  Los datos simulados se guardan en tools\mock-data\ (no tocan el firmware).
# =============================================================================

param([int]$Port = 8080)

$ErrorActionPreference = 'Stop'
$INV = [System.Globalization.CultureInfo]::InvariantCulture

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root      = (Resolve-Path (Join-Path $ScriptDir '..\ProyectoSueloESP32')).Path
$DataDir   = Join-Path $ScriptDir 'mock-data'
$StateFile = Join-Path $DataDir 'state.json'

# Mismos criterios provisionales que el firmware.
$HUM_ALERT   = 20.0
$PH_ALERT    = 1.0
$PERSIST_MIN = 18 * 3600
$PERSIST_MAX = 30 * 3600

$CSV_HEADER = 'fecha_utc,epoch_s,hum_mv,hum_ind,ph_mv,ph,ph_present,lluvia,riego,agua,cobertura,notas,coincide,persistente'

if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }

# ------------------------------- Estado --------------------------------------
function New-State {
    [ordered]@{
        hum_dry = $null
        hum_wet = $null
        ph7     = $null
        ph4     = $null
        hum_mv  = 2800
        ph_mv   = 1500
        rows    = @()
    }
}

function Load-State {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $j = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $j) { return $j }
        } catch { }
    }
    return (New-State)
}

function Save-State($s) {
    ($s | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# ---------------------------- Cálculo (igual que el firmware) ----------------
function Test-HumCal($s) {
    if ($null -eq $s.hum_dry -or $null -eq $s.hum_wet) { return $false }
    if ([int]$s.hum_dry -eq [int]$s.hum_wet) { return $false }
    return $true
}
function Test-PhCal($s) {
    if ($null -eq $s.ph7 -or $null -eq $s.ph4) { return $false }
    if ([int]$s.ph7 -eq [int]$s.ph4) { return $false }
    return $true
}
function Hum-Index($s, $mv) {
    $dry = [double]$s.hum_dry; $wet = [double]$s.hum_wet
    $v = ($dry - $mv) * 100.0 / ($dry - $wet)
    if ($v -lt 0) { $v = 0 }
    if ($v -gt 100) { $v = 100 }
    return $v
}
function Ph-Value($s, $mv) {
    $p7 = [double]$s.ph7; $p4 = [double]$s.ph4
    return 7.0 + ($p7 - $mv) * 3.0 / ($p4 - $p7)
}
function Clean($v, $max) {
    if ($null -eq $v) { return '' }
    $s = [string]$v
    $s = $s.Replace("`r", ' ').Replace("`n", ' ').Replace(',', ';').Replace('"', "'").Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }
    return $s
}

# Agrega una fila aplicando la misma lógica de coincidencia/persistencia.
function Add-Row($s, $timestamp, $epoch, $hum_mv, $ph_mv, $phPresent, $lluvia, $riego, $agua, $cobertura, $notas) {
    $humValid = Test-HumCal $s
    $phValid  = $phPresent -and (Test-PhCal $s)
    $humv = 0.0; $phv = 0.0
    if ($humValid) { $humv = Hum-Index $s $hum_mv }
    if ($phValid)  { $phv  = Ph-Value  $s $ph_mv  }

    $rowsArr = @($s.rows)
    $prev = $null
    if ($rowsArr.Count -gt 0) { $prev = $rowsArr[$rowsArr.Count - 1] }

    $prevHasHum = $false; $prevHum = 0.0; $prevHasPh = $false; $prevPh = 0.0
    $prevCoincide = $false; $prevEpoch = [long]0
    if ($null -ne $prev) {
        if (-not [string]::IsNullOrEmpty([string]$prev.hum_ind)) { $prevHum = [double]::Parse([string]$prev.hum_ind, $INV); $prevHasHum = $true }
        if (-not [string]::IsNullOrEmpty([string]$prev.ph))      { $prevPh  = [double]::Parse([string]$prev.ph, $INV);      $prevHasPh = $true }
        $prevCoincide = ([string]$prev.coincide -eq '1')
        $prevEpoch = [long]$prev.epoch_s
    }

    $humAlert = $humValid -and $prevHasHum -and ([math]::Abs($humv - $prevHum) -ge $HUM_ALERT)
    $phAlert  = $phValid  -and $prevHasPh  -and ([math]::Abs($phv  - $prevPh)  -ge $PH_ALERT)
    $coincide = $humAlert -and $phAlert
    $dt = [long]$epoch - $prevEpoch
    $persistente = $coincide -and $prevCoincide -and ($dt -ge $PERSIST_MIN) -and ($dt -le $PERSIST_MAX)

    $humIndStr = ''; if ($humValid) { $humIndStr = $humv.ToString('0.0', $INV) }
    $phStr = '';     if ($phValid)  { $phStr     = $phv.ToString('0.00', $INV) }
    $phPresStr = '0'; if ($phPresent) { $phPresStr = '1' }
    $coinStr = '0';   if ($coincide) { $coinStr = '1' }
    $persStr = '0';   if ($persistente) { $persStr = '1' }

    $row = [ordered]@{
        fecha_utc   = $timestamp
        epoch_s     = [string]$epoch
        hum_mv      = [string][int]$hum_mv
        hum_ind     = $humIndStr
        ph_mv       = [string][int]$ph_mv
        ph          = $phStr
        ph_present  = $phPresStr
        lluvia      = $lluvia
        riego       = $riego
        agua        = $agua
        cobertura   = $cobertura
        notas       = $notas
        coincide    = $coinStr
        persistente = $persStr
    }
    $s.rows = @($s.rows) + @($row)

    return [pscustomobject]@{
        humValid = $humValid; phValid = $phValid
        humInd = $humIndStr;  ph = $phStr
        coincide = $coincide; persistente = $persistente
    }
}

function Row-Line($r) {
    $cols = @(
        (Clean $r.fecha_utc 40), (Clean $r.epoch_s 20), (Clean $r.hum_mv 20), (Clean $r.hum_ind 20),
        (Clean $r.ph_mv 20), (Clean $r.ph 20), (Clean $r.ph_present 5), (Clean $r.lluvia 20),
        (Clean $r.riego 20), (Clean $r.agua 20), (Clean $r.cobertura 20), (Clean $r.notas 100),
        (Clean $r.coincide 5), (Clean $r.persistente 5)
    )
    return ($cols -join ',')
}

function Csv-Text($s) {
    $lines = @($CSV_HEADER)
    foreach ($r in @($s.rows)) { $lines += (Row-Line $r) }
    return (($lines -join "`r`n") + "`r`n")
}

function Status-Json($s) {
    $humIndex = 'null'
    if (Test-HumCal $s) { $humIndex = (Hum-Index $s ([int]$s.hum_mv)).ToString('0.0', $INV) }
    $dry = 'null'; if ($null -ne $s.hum_dry) { $dry = ([int]$s.hum_dry).ToString($INV) }
    $wet = 'null'; if ($null -ne $s.hum_wet) { $wet = ([int]$s.hum_wet).ToString($INV) }
    $p7  = 'null'; if ($null -ne $s.ph7)     { $p7  = ([int]$s.ph7).ToString($INV) }
    $p4  = 'null'; if ($null -ne $s.ph4)     { $p4  = ([int]$s.ph4).ToString($INV) }
    $parts = @(
        ('"storage":true'),
        (',"hum_mv":' + [int]$s.hum_mv),
        (',"ph_mv":' + [int]$s.ph_mv),
        (',"hum_index":' + $humIndex),
        (',"hum_dry":' + $dry),
        (',"hum_wet":' + $wet),
        (',"ph7":' + $p7),
        (',"ph4":' + $p4)
    )
    return '{' + ($parts -join '') + '}'
}

function Preview-Json($s, $phPresent) {
    $humValid = Test-HumCal $s
    $phValid  = $phPresent -and (Test-PhCal $s)
    $humIndex = 'null'; $humv = 0.0
    if ($humValid) { $humv = Hum-Index $s ([int]$s.hum_mv); $humIndex = $humv.ToString('0.0', $INV) }
    $phStr = 'null'; $phv = 0.0
    if ($phValid) { $phv = Ph-Value $s ([int]$s.ph_mv); $phStr = $phv.ToString('0.00', $INV) }

    if (-not $humValid -and -not $phValid) { $st = 'Sin variables evaluables' }
    elseif ($humValid -and -not $phValid) { $st = 'Solo humedad evaluable; pH no evaluable' }
    elseif (-not $humValid -and $phValid) { $st = 'Solo pH evaluable; humedad sin calibrar' }
    else {
        $rowsArr = @($s.rows); $prev = $null
        if ($rowsArr.Count -gt 0) { $prev = $rowsArr[$rowsArr.Count - 1] }
        $humAlert = $false; $phAlert = $false
        if ($null -ne $prev) {
            if (-not [string]::IsNullOrEmpty([string]$prev.hum_ind)) { $humAlert = [math]::Abs($humv - [double]::Parse([string]$prev.hum_ind, $INV)) -ge $HUM_ALERT }
            if (-not [string]::IsNullOrEmpty([string]$prev.ph))      { $phAlert  = [math]::Abs($phv  - [double]::Parse([string]$prev.ph, $INV))      -ge $PH_ALERT }
        }
        if ($humAlert -and $phAlert) { $st = 'Dos variables evaluables; coincidencia provisional' }
        else { $st = 'Dos variables evaluables; sin coincidencia' }
    }
    $parts = @(
        ('"hum_mv":' + [int]$s.hum_mv),
        (',"ph_mv":' + [int]$s.ph_mv),
        (',"hum_index":' + $humIndex),
        (',"ph":' + $phStr),
        (',"status":"' + $st + '"')
    )
    return '{' + ($parts -join '') + '}'
}

# ------------------------------- HTTP ----------------------------------------
function Send-Text($ctx, $code, $ctype, $text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$text)
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.ContentType = $ctype
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Send-File($ctx, $file, $ctype) {
    if (-not (Test-Path -LiteralPath $file)) { Send-Text $ctx 404 'text/plain; charset=utf-8' 'Archivo no encontrado'; return }
    $bytes = [System.IO.File]::ReadAllBytes($file)
    $res = $ctx.Response
    $res.StatusCode = 200
    $res.ContentType = $ctype
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Parse-Form($body) {
    $h = @{}
    if ([string]::IsNullOrEmpty($body)) { return $h }
    foreach ($pair in $body.Split('&')) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $idx = $pair.IndexOf('=')
        if ($idx -lt 0) { $k = $pair; $v = '' } else { $k = $pair.Substring(0, $idx); $v = $pair.Substring($idx + 1) }
        $k = [System.Uri]::UnescapeDataString($k.Replace('+', ' '))
        $v = [System.Uri]::UnescapeDataString($v.Replace('+', ' '))
        $h[$k] = $v
    }
    return $h
}

function Handle-Request($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    $body = ''
    if ($method -eq 'POST') {
        $enc = $req.ContentEncoding
        if ($null -eq $enc) { $enc = [System.Text.Encoding]::UTF8 }
        $reader = New-Object System.IO.StreamReader($req.InputStream, $enc)
        $body = $reader.ReadToEnd()
        $reader.Close()
    }
    Write-Host ("  {0} {1}" -f $method, $req.Url.PathAndQuery)

    if ($path -eq '/' -or $path -eq '/index.html') {
        Send-File $ctx (Join-Path $Root 'dashboard.html') 'text/html; charset=utf-8'
    }
    elseif ($path -eq '/mock') {
        Send-File $ctx (Join-Path $ScriptDir 'mock-control.html') 'text/html; charset=utf-8'
    }
    elseif ($path -eq '/api/status') {
        Send-Text $ctx 200 'application/json' (Status-Json (Load-State))
    }
    elseif ($path -eq '/api/preview') {
        $phPresent = ($req.QueryString['ph_present'] -eq '1')
        Send-Text $ctx 200 'application/json' (Preview-Json (Load-State) $phPresent)
    }
    elseif ($path -eq '/api/save' -and $method -eq 'POST') {
        $s = Load-State
        $f = Parse-Form $body
        $epoch = [long]0; [void][long]::TryParse([string]$f['epoch_s'], [ref]$epoch)
        $res = Add-Row $s (Clean $f['timestamp'] 40) $epoch ([int]$s.hum_mv) ([int]$s.ph_mv) `
                         ($f['ph_present'] -eq '1') (Clean $f['lluvia'] 20) (Clean $f['riego'] 20) `
                         (Clean $f['agua'] 20) (Clean $f['cobertura'] 20) (Clean $f['notas'] 100)
        Save-State $s
        $st = 'Humedad: '
        if ($res.humValid) { $st += $res.humInd + ' indice' } else { $st += 'sin calibrar' }
        $st += ' - pH: '
        if ($res.phValid) { $st += $res.ph } else { $st += 'no evaluable' }
        if ($res.coincide) { $st += ' - Coincidencia provisional'; if ($res.persistente) { $st += ' persistente' } }
        Send-Text $ctx 200 'application/json' ('{"status":"' + $st + '"}')
    }
    elseif ($path -eq '/api/calibrar' -and $method -eq 'POST') {
        $s = Load-State
        $f = Parse-Form $body
        $tipo = [string]$f['tipo']
        $msg = ''
        switch ($tipo) {
            'seco'   { $s.hum_dry = [int]$s.hum_mv; $msg = 'Referencia seca guardada: ' + [int]$s.hum_mv + ' mV' }
            'humedo' { $s.hum_wet = [int]$s.hum_mv; $msg = 'Referencia humeda guardada: ' + [int]$s.hum_mv + ' mV' }
            'ph7'    { $s.ph7 = [int]$s.ph_mv;       $msg = 'Tampon pH 7.00 guardado: ' + [int]$s.ph_mv + ' mV' }
            'ph4'    { $s.ph4 = [int]$s.ph_mv;       $msg = 'Tampon pH 4.00 guardado: ' + [int]$s.ph_mv + ' mV' }
            default  { Send-Text $ctx 400 'application/json' '{"error":"Tipo de calibracion desconocido"}'; return }
        }
        Save-State $s
        Send-Text $ctx 200 'application/json' ('{"message":"' + $msg + '"}')
    }
    elseif ($path -eq '/api/csv') {
        $csv = Csv-Text (Load-State)
        if ($null -eq $req.QueryString['view']) {
            $ctx.Response.AddHeader('Content-Disposition', 'attachment; filename=suelo_pina.csv')
        }
        Send-Text $ctx 200 'text/csv; charset=utf-8' $csv
    }
    elseif ($path -eq '/mock/state') {
        $s = Load-State
        $dry = 'null'; if ($null -ne $s.hum_dry) { $dry = ([int]$s.hum_dry).ToString($INV) }
        $wet = 'null'; if ($null -ne $s.hum_wet) { $wet = ([int]$s.hum_wet).ToString($INV) }
        $p7  = 'null'; if ($null -ne $s.ph7)     { $p7  = ([int]$s.ph7).ToString($INV) }
        $p4  = 'null'; if ($null -ne $s.ph4)     { $p4  = ([int]$s.ph4).ToString($INV) }
        $parts = @(
            ('"hum_mv":' + [int]$s.hum_mv),
            (',"ph_mv":' + [int]$s.ph_mv),
            (',"hum_dry":' + $dry),
            (',"hum_wet":' + $wet),
            (',"ph7":' + $p7),
            (',"ph4":' + $p4),
            (',"rows":' + @($s.rows).Count)
        )
        Send-Text $ctx 200 'application/json' ('{' + ($parts -join '') + '}')
    }
    elseif ($path -eq '/mock/set') {
        $s = Load-State
        if ($null -ne $req.QueryString['hum_mv']) { $s.hum_mv = [int]$req.QueryString['hum_mv'] }
        if ($null -ne $req.QueryString['ph_mv'])  { $s.ph_mv  = [int]$req.QueryString['ph_mv'] }
        Save-State $s
        Send-Text $ctx 200 'application/json' '{"ok":true}'
    }
    elseif ($path -eq '/mock/reset') {
        Save-State (New-State)
        Send-Text $ctx 200 'application/json' '{"ok":true}'
    }
    elseif ($path -eq '/mock/seed') {
        $s = Load-State
        if (-not (Test-HumCal $s)) { $s.hum_dry = 2800; $s.hum_wet = 1200 }
        if (-not (Test-PhCal $s))  { $s.ph7 = 1500;     $s.ph4 = 2030 }
        $humSeq = @(1500, 1480, 1520, 1500, 1490, 1510, 2600, 1300, 1500, 1490, 1510, 1500)
        $phSeq  = @(1600, 1610, 1595, 1605, 1600, 1590, 1850, 1500, 1600, 1605, 1595, 1600)
        $n = $humSeq.Count
        $now = [DateTimeOffset]::UtcNow
        for ($i = 0; $i -lt $n; $i++) {
            $t = $now.AddSeconds(-86400.0 * ($n - 1 - $i))
            $ts = $t.ToString('yyyy-MM-ddTHH:mm:ssZ', $INV)
            $ep = [long]$t.ToUnixTimeSeconds()
            Add-Row $s $ts $ep $humSeq[$i] $phSeq[$i] $true 'No consta' 'No consta' 'No determinado' 'No determinada' 'dato de ejemplo' | Out-Null
        }
        Save-State $s
        Send-Text $ctx 200 'application/json' ('{"ok":true,"count":' + $n + '}')
    }
    else {
        Send-Text $ctx 404 'text/plain; charset=utf-8' 'Recurso no encontrado'
    }
}

# ------------------------------- Arranque ------------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host ""
Write-Host "  Simulador ESP32 (mock) escuchando en http://localhost:$Port/" -ForegroundColor Green
Write-Host "    Panel (dashboard) : http://localhost:$Port/"
Write-Host "    Control simulador : http://localhost:$Port/mock"
Write-Host "    Datos simulados   : $DataDir"
Write-Host "  Ctrl+C para detener."
Write-Host ""

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try { Handle-Request $ctx }
        catch {
            Write-Host ("  ERROR: " + $_.Exception.Message) -ForegroundColor Red
            try { Send-Text $ctx 500 'application/json' '{"error":"Error interno del simulador"}' } catch { }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "Simulador detenido."
}
