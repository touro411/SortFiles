#requires -Version 5.1
<#
.SYNOPSIS
    Verschiebt Dateien nach Kategorie, Jahr und Monat, z. B. in Audio\2025\07.
.DESCRIPTION
    Verwendet zuerst das Windows-Feld "Aufnahmedatum", danach das
    Änderungsdatum. Fehlen beide, zählt das älteste der weiteren unten
    aufgeführten Datei- und Metadaten. Alle Unterordner werden durchsucht.
    Die Dateiauswahl erfolgt anhand der Endungen in $endungen.
    Jeder Jahresordner enthält die zweistelligen Monatsordner für seine Dateien.
    Bei Namenskonflikten wird eine Nummer vor der Dateiendung ergänzt.
.EXAMPLE
    .\Sortiere-Dateien.ps1 -Quellordner 'D:\Dateien' -WhatIf
.EXAMPLE
    .\Sortiere-Dateien.ps1 -Quellordner 'D:\Dateien'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Quellordner,
    [switch]$Vorschau,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$kultur = [Globalization.CultureInfo]::InvariantCulture
$nullZeit = [datetime]::FromFileTimeUtc(0)

function Get-MetadatumUtc($eintrag, [string]$feld) {
    if ($null -eq $eintrag) { return }
    try {
        $wert = $eintrag.ExtendedProperty($feld)
        if ($wert -is [datetime] -and $wert -gt $nullZeit) {
            # Die Windows-Shell liefert UTC ohne DateTimeKind-Kennzeichnung.
            return [datetime]::SpecifyKind($wert, [DateTimeKind]::Utc)
        }
    } catch [System.Runtime.InteropServices.COMException] {
        Write-Verbose "Metadatenfeld '$feld' ist nicht lesbar: $_"
    }
}

function Get-Sortierdatum([IO.FileInfo]$datei, $eintrag) {
    $aufnahme = Get-MetadatumUtc $eintrag 'System.Photo.DateTaken'
    if ($null -ne $aufnahme) {
        return @{ Datum = $aufnahme.ToLocalTime(); Quelle = 'Aufnahmedatum' }
    }
    if ($datei.LastWriteTimeUtc -gt $nullZeit) {
        return @{ Datum = $datei.LastWriteTime; Quelle = 'Änderungsdatum' }
    }

    $weitere = [ordered]@{
        'Erstellungsdatum' = $datei.CreationTimeUtc
        'Letzter Zugriff'  = $datei.LastAccessTimeUtc
    }
    foreach ($feld in 'System.DateAcquired', 'System.Media.DateEncoded',
                       'System.Document.DateCreated', 'System.Document.DateSaved',
                       'System.Document.DatePrinted', 'System.ItemDate') {
        $weitere[$feld] = Get-MetadatumUtc $eintrag $feld
    }
    $aeltestes = $weitere.GetEnumerator() | Where-Object { $_.Value -gt $nullZeit } |
        Sort-Object Value | Select-Object -First 1
    if ($null -ne $aeltestes) {
        return @{ Datum = $aeltestes.Value.ToLocalTime(); Quelle = $aeltestes.Key }
    }
}

$ordner = Get-Item -LiteralPath $Quellordner -Force
if ($ordner -isnot [IO.DirectoryInfo]) {
    throw "'$Quellordner' ist kein Dateisystemordner."
}
$endungen = [ordered]@{
    Bilder = @(
        '.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.apng', '.gif', '.bmp', '.dib',
        '.tif', '.tiff', '.heic', '.heif', '.hif', '.avif', '.webp', '.jxl',
        '.jp2', '.j2k', '.jxr', '.ico', '.svg', '.svgz', '.psd', '.psb'
        # Kamera-Rohbilder
        '.dng', '.cr2', '.cr3', '.crw', '.nef', '.nrw', '.arw', '.srf', '.sr2',
        '.raf', '.orf', '.ori', '.rw2', '.pef', '.srw', '.3fr', '.fff', '.iiq', '.rwl'
    )
    Videos = @(
        '.mp4', '.m4v', '.mov', '.avi', '.mkv', '.webm', '.wmv', '.asf', '.mpg',
        '.mpeg', '.mpe', '.m1v', '.m2v', '.mts', '.m2ts', '.vob', '.3gp', '.3g2',
        '.flv', '.f4v', '.ogv', '.mxf'
    )
    Dokumente = @(
        '.pdf', '.txt', '.md', '.rtf', '.doc', '.docx', '.docm', '.dot', '.dotx', '.dotm',
        '.xls', '.xlsx', '.xlsm', '.xlsb', '.xlt', '.xltx', '.xltm', '.csv', '.tsv',
        '.ppt', '.pptx', '.pptm', '.pps', '.ppsx', '.ppsm', '.pot', '.potx', '.potm',
        '.odt', '.ods', '.odp', '.odg', '.ott', '.ots', '.otp', '.epub', '.xps', '.oxps'
    )
    Audio = @(
        '.mp3', '.wav', '.wave', '.flac', '.aac', '.m4a', '.m4b', '.alac', '.aif',
        '.aiff', '.aifc', '.ogg', '.oga', '.opus', '.wma', '.amr', '.awb', '.au',
        '.snd', '.ape', '.wv', '.mid', '.midi', '.ac3', '.eac3', '.dts', '.mka', '.caf'
    )
    Andere = @()
}
$kategorie = @{}
foreach ($typ in $endungen.Keys) {
    foreach ($endung in $endungen[$typ]) { $kategorie[$endung] = $typ }
}

Import-Module (Join-Path $PSScriptRoot 'Dateipruefung.psm1')

function Assert-Zielordner([string]$pfad) {
    $vorhanden = [IO.DirectoryInfo]::new($pfad)
    if ([IO.File]::Exists($pfad) -or ($vorhanden.Attributes -ne -1 -and
        ($vorhanden.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $vorhanden.LinkType)) {
        throw "Zielpfad ist durch eine Datei oder Verknüpfung belegt: $pfad"
    }
}

$dateien = @(Get-Quelldateien -ordner $ordner -ErrorAction Continue 2>&1 | ForEach-Object {
    if ($_ -is [Management.Automation.ErrorRecord]) { Write-Warning $_.ToString() }
    else { $_ }
} | Sort-Object DirectoryName, Name)
foreach ($typ in $endungen.Keys) {
    $typordner = Join-Path $ordner.FullName $typ
    Assert-Zielordner $typordner
}
foreach ($typ in $endungen.Keys) {
    $typordner = Join-Path $ordner.FullName $typ
    if (-not $Vorschau -and -not [IO.Directory]::Exists($typordner) -and
        $PSCmdlet.ShouldProcess($typordner, 'Kategorieordner erstellen')) {
        [void][IO.Directory]::CreateDirectory($typordner)
    }
}
if ($dateien.Count -eq 0) {
    if (-not $PassThru) { Write-Warning "Keine zu sortierenden Dateien in '$($ordner.FullName)' gefunden." }
    return
}
if ($WhatIfPreference) {
    Write-Host ("Vorschau für '{0}' – gefundene Dateien: {1}" -f $ordner.FullName, $dateien.Count)
}
$shell = $null
try { $shell = New-Object -ComObject Shell.Application }
catch { Write-Warning "Windows-Metadaten sind nicht verfügbar. Es gelten die Dateizeiten." }
$metadatenPfad = $null
$metadatenOrdner = $null
$bereitsEinsortiert = 0

# Auch in der Vorschau sollen mehrfach beanspruchte Namen eindeutig sein.
$verplanteZiele = [Collections.Generic.HashSet[string]]::new([string[]]$dateien.FullName, [StringComparer]::OrdinalIgnoreCase)
foreach ($datei in $dateien) {
    $eintrag = $null
    try {
        if ($null -ne $shell -and $metadatenPfad -ne $datei.DirectoryName) {
            if ($null -ne $metadatenOrdner) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($metadatenOrdner)
            }
            $metadatenOrdner = $null
            $metadatenPfad = $datei.DirectoryName
            try { $metadatenOrdner = $shell.NameSpace($metadatenPfad) }
            catch { Write-Verbose "Metadaten für '$metadatenPfad' nicht verfügbar: $_" }
        }
        if ($null -ne $metadatenOrdner) {
            try { $eintrag = $metadatenOrdner.ParseName($datei.Name) }
            catch { Write-Verbose "Metadaten für '$($datei.Name)' nicht verfügbar: $_" }
        }
        $auswahl = Get-Sortierdatum $datei $eintrag
        if ($null -eq $auswahl) {
            Write-Warning "Kein verwendbares Datum. Datei bleibt am Platz: $($datei.FullName)"
            continue
        }

        $jahr = $auswahl.Datum.ToString('yyyy', $kultur)
        $monat = $auswahl.Datum.ToString('MM', $kultur)
        $typ = $kategorie[$datei.Extension]
        if (-not $typ) { $typ = 'Andere' }
        $typordner = Join-Path $ordner.FullName $typ
        $jahresordner = Join-Path $typordner $jahr
        $zielordner = Join-Path $jahresordner $monat
        foreach ($pfad in $typordner, $jahresordner, $zielordner) { Assert-Zielordner $pfad }
        $ziel = Join-Path $zielordner $datei.Name
        if ($datei.FullName -eq $ziel) {
            $bereitsEinsortiert++
            if ($PassThru) { [pscustomobject]@{ Status = 'Einsortiert' } }
            continue
        }
        $nummer = 1
        while ((Test-Path -LiteralPath $ziel) -or $verplanteZiele.Contains($ziel)) {
            $ziel = Join-Path $zielordner ('{0} ({1}){2}' -f $datei.BaseName, $nummer, $datei.Extension)
            $nummer++
        }

        $datum = $auswahl.Datum.ToString('dd.MM.yyyy', $kultur)
        $aktion = "Nach '$ziel' verschieben ($($auswahl.Quelle) $datum)"
        $status = 'Geplant'
        if (-not $Vorschau -and $PSCmdlet.ShouldProcess($datei.FullName, $aktion)) {
            [void][IO.Directory]::CreateDirectory($zielordner)
            [IO.File]::Move($datei.FullName, $ziel)
            $status = 'Verschoben'
        } elseif (-not ($Vorschau -or $WhatIfPreference)) {
            continue
        }
        [void]$verplanteZiele.Add($ziel)
        if ($PassThru) {
            [pscustomobject]@{ Status = $status; Von = $datei.FullName; Nach = $ziel }
        }
    } catch {
        Write-Warning "Fehler bei '$($datei.FullName)': $_"
    } finally {
        if ($null -ne $eintrag) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($eintrag)
        }
    }
}
foreach ($objekt in $metadatenOrdner, $shell) {
    if ($null -ne $objekt) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($objekt) }
}
if ($bereitsEinsortiert -gt 0 -and -not $PassThru) {
    Write-Host "Bereits im richtigen Monatsordner: $bereitsEinsortiert"
}
