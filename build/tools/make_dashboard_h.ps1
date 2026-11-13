# Genera dashboard.h (interfaz web embebida en el firmware) a partir de dashboard.html.
# Uso:  powershell -ExecutionPolicy Bypass -File tools\make_dashboard_h.ps1
# Edita SIEMPRE dashboard.html y vuelve a ejecutar este script; no edites dashboard.h a mano.

param(
    [string]$Html = (Join-Path $PSScriptRoot '..\ProyectoSueloESP32\dashboard.html'),
    [string]$Out  = (Join-Path $PSScriptRoot '..\ProyectoSueloESP32\dashboard.h')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Html)) { throw "No se encontró el HTML de origen: $Html" }

$html = [System.IO.File]::ReadAllText($Html, [System.Text.Encoding]::UTF8)

# El delimitador crudo de C++ no puede aparecer dentro del contenido.
if ($html -match '\)rawliteral"') { throw 'El HTML contiene el delimitador )rawliteral" y no puede embeberse.' }

$head = @'
// -----------------------------------------------------------------------------
// dashboard.h - Interfaz web embebida (generada desde dashboard.html)
// NO EDITAR A MANO. Modifica dashboard.html y ejecuta tools\make_dashboard_h.ps1
// -----------------------------------------------------------------------------
#pragma once
#include <pgmspace.h>

const char DASHBOARD_HTML[] PROGMEM = R"rawliteral(
'@

$tail = @'
)rawliteral";
'@

$content = $head + $html.TrimEnd() + "`r`n" + $tail

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($Out, $content, $utf8NoBom)

Write-Host "dashboard.h generado: $Out ($($content.Length) caracteres)"
