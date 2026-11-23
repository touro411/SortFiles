#requires -Version 5.1
<# Direktstart der Duplikatsuche in der gemeinsamen Oberfläche. #>
[CmdletBinding()]
param(
    [string]$InitialPath = '',
    [ValidateRange(0, 65535)][int]$Port = 0,
    [switch]$NoBrowser
)

& (Join-Path $PSScriptRoot 'Start-Oberflaeche.ps1') -Duplikatstart -Port $Port -InitialPath $InitialPath -NoBrowser:$NoBrowser
