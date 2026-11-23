#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Server,
    [ValidateRange(0,65535)][int]$Port,
    [guid]$Sitzung,
    [guid]$Startkennung,
    [string]$Netzlaufwerke,
    [string]$Benutzerordner,
    [switch]$Duplikatstart,
    [string]$InitialPath,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

function Find-Chrome {
    $app = 'Software\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    foreach ($schluessel in "HKCU:\$app", "HKLM:\$app") {
        $eintrag = Get-Item -LiteralPath $schluessel -ErrorAction SilentlyContinue
        if ($eintrag) {
            $pfad = ([string]$eintrag.GetValue('')).Trim('"')
            if ([IO.File]::Exists($pfad)) { return $pfad }
        }
    }
    foreach ($basis in $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) {
        if ($basis) {
            $pfad = Join-Path $basis 'Google\Chrome\Application\chrome.exe'
            if ([IO.File]::Exists($pfad)) { return $pfad }
        }
    }
    $befehl = Get-Command chrome.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($befehl) { return $befehl.Source }
    throw 'Google Chrome wurde nicht gefunden. Bitte installiere Google Chrome und öffne Start.cmd erneut.'
}

function Get-Standardordner {
    # Downloads hat in .NET Framework keinen SpecialFolder-Eintrag.
    $schluessel = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    $downloads = if ($schluessel) { $schluessel.GetValue('{374DE290-123F-4565-9164-39C4925E467B}') }
    if (-not $downloads) { $downloads = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads' }
    $pfade = [ordered]@{
        Dokumente = [Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')
        Downloads = $downloads
        Desktop   = [Environment]::GetFolderPath('DesktopDirectory', 'DoNotVerify')
        Bilder    = [Environment]::GetFolderPath('MyPictures', 'DoNotVerify')
        Musik     = [Environment]::GetFolderPath('MyMusic', 'DoNotVerify')
        Videos    = [Environment]::GetFolderPath('MyVideos', 'DoNotVerify')
    }
    foreach ($name in $pfade.Keys) {
        if ($pfade[$name]) { @{ name = $name; pfad = $pfade[$name] } }
    }
}

if (-not $Server) {
    if (-not $Port) {
        $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        try {
            $probe.Start()
            $Port = $probe.LocalEndpoint.Port
        } finally { $probe.Stop() }
    }
    $Sitzung = [guid]::NewGuid()
    $Startkennung = [guid]::NewGuid()
    $ursprung = "http://127.0.0.1:$Port"
    # Laufwerksbuchstaben gehören zur Anmeldesitzung des aufrufenden Benutzers.
    $zuordnungen = @{}
    foreach ($laufwerk in Get-PSDrive -PSProvider FileSystem) {
        if ($laufwerk.Name -match '^[A-Z]$' -and $laufwerk.DisplayRoot -like '\\*') {
            $zuordnungen[$laufwerk.Name] = $laufwerk.DisplayRoot
        }
    }
    $Netzlaufwerke = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $zuordnungen -Compress)))
}
if (-not $Server -and -not $Duplikatstart) {
    $argumente = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Server -Port $Port -Sitzung $Sitzung -Startkennung $Startkennung"
    # Vor der UAC-Abfrage ermitteln, auch wenn später ein anderes Konto bestätigt.
    $ordnerJson = ConvertTo-Json -InputObject @(Get-Standardordner) -Compress
    $Benutzerordner = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ordnerJson))
    $argumente += " -Netzlaufwerke $Netzlaufwerke -Benutzerordner $Benutzerordner"
    $dienst = Start-Process -FilePath "$PSHOME\powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList $argumente -PassThru
    $client = [Net.WebClient]::new()
    $client.Proxy = $null
    try {
        $ende = [datetime]::UtcNow.AddSeconds(20)
        while ($true) {
            if ($dienst.HasExited) { throw 'Der lokale Dateisortierer konnte nicht starten.' }
            try { $antwort = $client.DownloadString("$ursprung/bereit") }
            catch [Net.WebException] { $antwort = '' }
            if ($antwort -ceq $Startkennung.ToString()) { break }
            if ([datetime]::UtcNow -gt $ende) { throw 'Der lokale Dateisortierer antwortet nicht.' }
            Start-Sleep -Milliseconds 150
        }
        try {
            $chrome = Find-Chrome
            Start-Process -FilePath $chrome -ArgumentList "--new-window $ursprung/#$Sitzung"
        } catch {
            $client.Headers['Origin'] = $ursprung
            $client.Headers['X-Sitzung'] = $Sitzung.ToString()
            [void]$client.UploadString("$ursprung/beenden", '')
            throw
        }
    } finally { $client.Dispose() }
    return
}

if (-not $Port -or -not $Sitzung -or -not $Startkennung) { throw 'Startparameter fehlen.' }
$ursprung = "http://127.0.0.1:$Port"
$sortierer = Join-Path $PSScriptRoot 'Sortiere-Dateien.ps1'
Import-Module (Join-Path $PSScriptRoot 'Dateipruefung.psm1')
$seite = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Oberflaeche.html'))
$standardordner = if ($Benutzerordner) {
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Benutzerordner)) | ConvertFrom-Json
} else { Get-Standardordner }

$freigaben = @{}
if ($Netzlaufwerke) {
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Netzlaufwerke))
    foreach ($paar in (ConvertFrom-Json $json).PSObject.Properties) {
        $freigaben[$paar.Name] = $paar.Value
    }
}

function Resolve-Quellordner([string]$pfad) {
    $pfad = $pfad.Trim()
    if ($pfad -match '^"(.*)"$') { $pfad = $Matches[1] }
    $pfad = $pfad.Replace('/', '\')
    if ($pfad -notmatch '^(?:[a-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))' -or $pfad -match '^\\\\[?.]\\') {
        throw 'Gib einen vollständigen Pfad wie D:\Sammlung oder \\Server\Freigabe ein.'
    }
    $pfad = [IO.Path]::GetFullPath($pfad)
    if ($pfad -match '^([a-z]):\\' -and $freigaben.ContainsKey($Matches[1])) {
        $pfad = $freigaben[$Matches[1]].TrimEnd('\') + $pfad.Substring(2)
    }
    $ordner = [IO.DirectoryInfo]::new($pfad)
    if (-not $ordner.Exists) {
        throw "Ordner nicht erreichbar: $pfad. Prüfe den Pfad und bei Netzlaufwerken die Verbindung und die Freigaberechte."
    }
    return $ordner
}

function Get-Ordnerauswahl([string]$pfad) {
    if ([string]::IsNullOrWhiteSpace($pfad)) {
        $laufwerke = @{}
        foreach ($laufwerk in [IO.DriveInfo]::GetDrives()) {
            $laufwerke[$laufwerk.Name] = @{ name = $laufwerk.Name; pfad = $laufwerk.Name }
        }
        foreach ($buchstabe in $freigaben.Keys) {
            $wurzel = '{0}:\' -f $buchstabe
            $laufwerke[$wurzel] = @{ name = "$wurzel  ($($freigaben[$buchstabe]))"; pfad = $wurzel }
        }
        return @{ pfad = ''; eltern = ''; ordner = @($laufwerke.Keys | Sort-Object | ForEach-Object { $laufwerke[$_] }) }
    }
    $ordner = Resolve-Quellordner $pfad
    $kinder = @($ordner.EnumerateDirectories() | Sort-Object Name | ForEach-Object {
        @{ name = $_.Name; pfad = $_.FullName }
    })
    return @{ pfad = $ordner.FullName; eltern = [string]$ordner.Parent.FullName; ordner = $kinder }
}

function Invoke-Sortierung([string]$pfad, [bool]$vorschau) {
    $pfad = (Resolve-Quellordner $pfad).FullName
    $daten = [ordered]@{
        Geplant = 0; Verschoben = 0; Einsortiert = 0; Warnungen = 0
        Dateien = [Collections.Generic.List[object]]::new()
        Hinweise = [Collections.Generic.List[string]]::new()
    }
    & $sortierer -Quellordner $pfad -Vorschau:$vorschau -PassThru -Confirm:$false 3>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.WarningRecord]) {
            $daten.Warnungen++
            if ($daten.Hinweise.Count -lt 100) { $daten.Hinweise.Add($_.Message) }
        } else {
            $daten[$_.Status]++
            if ($_.Von -and $daten.Dateien.Count -lt 250) { $daten.Dateien.Add($_) }
        }
    }
    return $daten
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("$ursprung/")
try {
    $listener.Start()
    if ($Duplikatstart) {
        $adresse = "$ursprung/#$Sitzung&ansicht=duplikate&pfad=$([uri]::EscapeDataString($InitialPath))"
        if ($NoBrowser) { Write-Host "Duplikatsuche: $adresse" }
        else { Start-Process -FilePath (Find-Chrome) -ArgumentList "--new-window `"$adresse`"" }
    }
    $aktiv = $true
    $loeschauftragLimit = 131072
    while ($aktiv) {
        $eingang = $listener.BeginGetContext($null, $null)
        if (-not $eingang.AsyncWaitHandle.WaitOne([timespan]::FromMinutes(30))) { break }
        $kontext = $listener.EndGetContext($eingang)
        $eingang.AsyncWaitHandle.Close()
        $anfrage = $kontext.Request
        $antwort = $kontext.Response
        $antwort.ContentType = 'application/json; charset=utf-8'
        $antwort.Headers['Cache-Control'] = 'no-store'
        $antwort.Headers['X-Content-Type-Options'] = 'nosniff'
        $antwort.Headers['Referrer-Policy'] = 'no-referrer'
        $antwort.Headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        try {
            $route = $anfrage.Url.AbsolutePath
            if ($anfrage.UserHostName -cne "127.0.0.1:$Port") {
                $antwort.StatusCode = 403
                $inhalt = '{}'
            } elseif ($anfrage.HttpMethod -eq 'GET' -and $route -eq '/') {
                $antwort.ContentType = 'text/html; charset=utf-8'
                $inhalt = $seite
            } elseif ($anfrage.HttpMethod -eq 'GET' -and $route -eq '/bereit') {
                $antwort.ContentType = 'text/plain; charset=utf-8'
                $inhalt = $Startkennung.ToString()
            } elseif ($anfrage.HttpMethod -ne 'POST' -or $anfrage.Headers['Origin'] -cne $ursprung -or
                $anfrage.Headers['X-Sitzung'] -cne $Sitzung.ToString()) {
                $antwort.StatusCode = 403
                $inhalt = '{"fehler":"Öffne die Oberfläche über Start.cmd."}'
            } else {
                switch ($route) {
                    '/standardordner' { $daten = @{ pfad = ''; eltern = ''; ordner = @($standardordner) } }
                    { $_ -in '/ordner', '/vorschau', '/verschieben', '/duplikate/suchen', '/duplikate/loeschen' } {
                        $limit = if ($route -eq '/duplikate/loeschen') { $loeschauftragLimit } else { 131072 }
                        if ($anfrage.ContentLength64 -lt 0 -or $anfrage.ContentLength64 -gt $limit) {
                            throw 'Ungültige Anfragegröße.'
                        }
                        $leser = [IO.StreamReader]::new($anfrage.InputStream, [Text.Encoding]::UTF8)
                        try { $text = $leser.ReadToEnd() } finally { $leser.Dispose() }
                        switch ($route) {
                            '/ordner' { $daten = Get-Ordnerauswahl $text }
                            '/vorschau' { $daten = Invoke-Sortierung $text $true }
                            '/verschieben' {
                                Clear-DuplicateScan
                                $daten = Invoke-Sortierung $text $false
                            }
                            '/duplikate/suchen' {
                                Clear-DuplicateScan
                                $quelle = Resolve-Quellordner $text
                                $daten = Invoke-DuplicateScan -Path $quelle.FullName
                                # Auch große Vorschauen können einen Dateiindex pro Gruppe übermitteln.
                                $loeschauftragLimit = 131072 + 12L * $daten.GroupCount
                            }
                            '/duplikate/loeschen' {
                                $auftrag = ConvertFrom-Json $text
                                $bestaetigt = $auftrag.confirmed -is [bool] -and $auftrag.confirmed
                                $daten = Invoke-ConfirmedDeletion -ScanId $auftrag.scanId -Confirmed $bestaetigt -KeepIndices $auftrag.keepIndices
                            }
                        }
                    }
                    '/beenden' { $daten = @{}; $aktiv = $false }
                    default { $daten = @{}; $antwort.StatusCode = 404 }
                }
                $inhalt = ConvertTo-Json -InputObject $daten -Depth 6 -Compress
            }
        } catch {
            $antwort.StatusCode = 400
            $inhalt = ConvertTo-Json @{ fehler = $_.Exception.Message } -Compress
        }
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($inhalt)
            $antwort.ContentLength64 = $bytes.Length
            $antwort.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch [Net.HttpListenerException] {
            Write-Verbose 'Das Browserfenster wurde geschlossen.'
        } finally { $antwort.Close() }
    }
} finally { $listener.Close() }
