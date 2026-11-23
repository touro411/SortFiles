#requires -Version 5.1

<#
.SYNOPSIS
    Lokale Browser-Oberflaeche zum Finden und Entfernen doppelter Dateien.

.DESCRIPTION
    Startet im aktuellen Benutzerkontext einen nur an 127.0.0.1 gebundenen
    Webserver und oeffnet die Bedienoberflaeche in Google Chrome.
    Dateien werden anhand von Groesse und SHA-256 verglichen. Pro Gruppe bleibt
    der alphabetisch erste Pfad erhalten.

.PARAMETER InitialPath
    Optionaler Pfad, der beim Start in das Eingabefeld eingetragen ist.

.PARAMETER Port
    Optionaler lokaler TCP-Port. Ohne Angabe wird ein freier Port verwendet.

.PARAMETER NoBrowser
    Startet nur den lokalen Server. Dieser Schalter ist fuer Tests gedacht.
#>

[CmdletBinding()]
param(
    [string]$InitialPath = "",
    [ValidateRange(0, 65535)][int]$Port = 0,
    [switch]$NoBrowser
)

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:Running = $true
$script:CurrentScan = $null
$script:SessionToken = [Guid]::NewGuid().ToString("N")
$script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AssetRoot = Join-Path $script:ScriptRoot "web"

function Get-FreeTcpPort {
    $tcpListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $tcpListener.Start()
        return ([System.Net.IPEndPoint]$tcpListener.LocalEndpoint).Port
    }
    finally {
        $tcpListener.Stop()
    }
}

function Get-ChromePath {
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
    $candidates = @(
        (Join-Path ([Environment]::GetFolderPath("ProgramFiles")) "Google\Chrome\Application\chrome.exe"),
        $(if ($programFilesX86) { Join-Path $programFilesX86 "Google\Chrome\Application\chrome.exe" }),
        $(if ($localAppData) { Join-Path $localAppData "Google\Chrome\Application\chrome.exe" })
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    $command = Get-Command "chrome.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    return $null
}

function Get-WebAsset {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $script:AssetRoot $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Web-Datei fehlt: $path"
    }
    return [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-JsonText {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 10 -Compress)
}

function Send-TextResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [int]$StatusCode = 200
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = [Text.Encoding]::UTF8
    $Response.ContentLength64 = $bytes.Length
    $Response.Headers["Cache-Control"] = "no-store, max-age=0"
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-JsonResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)]$Value,
        [int]$StatusCode = 200
    )
    Send-TextResponse -Response $Response -Text (ConvertTo-JsonText $Value) -ContentType "application/json; charset=utf-8" -StatusCode $StatusCode
}

function Read-JsonRequest {
    param([Parameter(Mandatory = $true)]$Request)

    if (-not $Request.HasEntityBody) {
        return [PSCustomObject]@{}
    }
    if ($Request.ContentLength64 -gt 1048576) {
        throw "Die Anfrage ist zu gross."
    }

    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $body = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    if ([string]::IsNullOrWhiteSpace($body)) {
        return [PSCustomObject]@{}
    }
    return ($body | ConvertFrom-Json)
}

function Assert-ApiToken {
    param([Parameter(Mandatory = $true)]$Request)
    if ($Request.Headers["X-Duplicate-Cleaner-Token"] -cne $script:SessionToken) {
        throw (New-Object UnauthorizedAccessException("Ungueltige Sitzung."))
    }
}

function Resolve-DirectoryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($candidate.Length -ge 2) {
        $first = $candidate.Substring(0, 1)
        $last = $candidate.Substring($candidate.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $candidate = $candidate.Substring(1, $candidate.Length - 2).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw "Bitte einen Ordnerpfad eingeben."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "Der Ordner wurde nicht gefunden oder ist nicht erreichbar: $candidate"
    }

    return (Get-Item -LiteralPath $candidate -Force).FullName
}

function Show-FolderPicker {
    param([string]$SelectedPath)

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = "Ordner fuer die Duplikatsuche auswaehlen"
        $dialog.ShowNewFolderButton = $false
        if ($SelectedPath -and (Test-Path -LiteralPath $SelectedPath -PathType Container)) {
            $dialog.SelectedPath = $SelectedPath
        }
        $result = $dialog.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
        return $null
    }
    finally {
        $dialog.Dispose()
    }
}

function Invoke-DuplicateScan {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = Resolve-DirectoryPath -Path $Path
    $scanErrors = @()
    $files = @(
        Get-ChildItem -LiteralPath $resolvedPath -File -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors
    )
    $sizeGroups = @(
        $files | Group-Object -Property Length | Where-Object { $_.Count -gt 1 }
    )

    $hashErrors = New-Object System.Collections.Generic.List[object]
    $hashResults = @(
        foreach ($sizeGroup in $sizeGroups) {
            foreach ($file in $sizeGroup.Group) {
                try {
                    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop
                    [PSCustomObject]@{
                        FullName = $file.FullName
                        Name = $file.Name
                        Length = [int64]$file.Length
                        LastWriteTime = $file.LastWriteTime.ToString("o")
                        Hash = $hash.Hash
                        GroupKey = "{0}:{1}" -f $file.Length, $hash.Hash
                    }
                }
                catch {
                    $hashErrors.Add([PSCustomObject]@{ Path = $file.FullName; Error = $_.Exception.Message })
                }
            }
        }
    )
    $duplicateGroups = @(
        $hashResults | Group-Object -Property GroupKey | Where-Object { $_.Count -gt 1 }
    )

    $resultGroups = New-Object System.Collections.Generic.List[object]
    $filesToDelete = New-Object System.Collections.Generic.List[object]
    $groupNumber = 0
    foreach ($duplicateGroup in $duplicateGroups) {
        $groupNumber++
        $sortedFiles = @($duplicateGroup.Group | Sort-Object -Property FullName)
        $fileToKeep = $sortedFiles[0]
        $duplicates = @($sortedFiles | Select-Object -Skip 1)
        $keep = [PSCustomObject]@{
            Path = $fileToKeep.FullName
            Name = $fileToKeep.Name
            Length = [int64]$fileToKeep.Length
            LastWriteTime = $fileToKeep.LastWriteTime
            Hash = $fileToKeep.Hash
        }
        $deleteEntries = @(
            foreach ($duplicate in $duplicates) {
                $entry = [PSCustomObject]@{
                    Path = $duplicate.FullName
                    Name = $duplicate.Name
                    Length = [int64]$duplicate.Length
                    LastWriteTime = $duplicate.LastWriteTime
                    Hash = $duplicate.Hash
                }
                $filesToDelete.Add($entry)
                $entry
            }
        )
        $resultGroups.Add([PSCustomObject]@{
            Number = $groupNumber
            Length = [int64]$fileToKeep.Length
            Hash = $fileToKeep.Hash
            Keep = $keep
            Delete = $deleteEntries
        })
    }

    $totalBytes = [int64]0
    foreach ($entry in $filesToDelete) {
        $totalBytes += $entry.Length
    }

    $scanId = [Guid]::NewGuid().ToString("N")
    $script:CurrentScan = [PSCustomObject]@{
        Id = $scanId
        RootPath = $resolvedPath
        CreatedAt = [DateTime]::UtcNow
        Groups = $resultGroups.ToArray()
    }

    return [PSCustomObject]@{
        ScanId = $scanId
        RootPath = $resolvedPath
        ScannedFiles = $files.Count
        CandidateFiles = $hashResults.Count
        GroupCount = $resultGroups.Count
        DeleteCount = $filesToDelete.Count
        TotalBytes = $totalBytes
        ReadErrorCount = $scanErrors.Count
        HashErrorCount = $hashErrors.Count
        Groups = $resultGroups.ToArray()
    }
}

function Test-FileMatchesScan {
    param([Parameter(Mandatory = $true)]$Entry)

    try {
        if (-not (Test-Path -LiteralPath $Entry.Path -PathType Leaf)) {
            return [PSCustomObject]@{ Matches = $false; Reason = "Datei ist nicht mehr vorhanden." }
        }
        $item = Get-Item -LiteralPath $Entry.Path -Force
        if ([int64]$item.Length -ne [int64]$Entry.Length) {
            return [PSCustomObject]@{ Matches = $false; Reason = "Dateigroesse wurde seit dem Scan geaendert." }
        }
        $hash = Get-FileHash -LiteralPath $Entry.Path -Algorithm SHA256 -ErrorAction Stop
        if ($hash.Hash -cne $Entry.Hash) {
            return [PSCustomObject]@{ Matches = $false; Reason = "Dateiinhalt wurde seit dem Scan geaendert." }
        }
        return [PSCustomObject]@{ Matches = $true; Reason = $null }
    }
    catch {
        return [PSCustomObject]@{ Matches = $false; Reason = $_.Exception.Message }
    }
}

function Invoke-ConfirmedDeletion {
    param(
        [Parameter(Mandatory = $true)][string]$ScanId,
        [Parameter(Mandatory = $true)][bool]$Confirmed
    )

    if (-not $Confirmed) {
        throw "Die Loeschbestaetigung fehlt."
    }
    if ($null -eq $script:CurrentScan -or $script:CurrentScan.Id -cne $ScanId) {
        throw "Die Scan-Vorschau ist nicht mehr aktuell. Bitte erneut pruefen."
    }

    $results = New-Object System.Collections.Generic.List[object]
    $deletedCount = 0
    $skippedCount = 0
    $errorCount = 0
    $freedBytes = [int64]0

    foreach ($group in $script:CurrentScan.Groups) {
        $keepState = Test-FileMatchesScan -Entry $group.Keep
        if (-not $keepState.Matches) {
            foreach ($duplicate in $group.Delete) {
                $skippedCount++
                $results.Add([PSCustomObject]@{
                    Path = $duplicate.Path
                    Status = "skipped"
                    Message = "Erhaltungsdatei ist nicht mehr unveraendert vorhanden."
                })
            }
            continue
        }

        foreach ($duplicate in $group.Delete) {
            $state = Test-FileMatchesScan -Entry $duplicate
            if (-not $state.Matches) {
                $skippedCount++
                $results.Add([PSCustomObject]@{ Path = $duplicate.Path; Status = "skipped"; Message = $state.Reason })
                continue
            }
            try {
                Remove-Item -LiteralPath $duplicate.Path -Force -ErrorAction Stop
                $deletedCount++
                $freedBytes += [int64]$duplicate.Length
                $results.Add([PSCustomObject]@{ Path = $duplicate.Path; Status = "deleted"; Message = "Datei wurde geloescht." })
            }
            catch {
                $errorCount++
                $results.Add([PSCustomObject]@{ Path = $duplicate.Path; Status = "error"; Message = $_.Exception.Message })
            }
        }
    }

    $script:CurrentScan = $null
    return [PSCustomObject]@{
        DeletedCount = $deletedCount
        SkippedCount = $skippedCount
        ErrorCount = $errorCount
        FreedBytes = $freedBytes
        Results = $results.ToArray()
    }
}

foreach ($asset in @("index.html", "styles.css", "app.js")) {
    $assetPath = Join-Path $script:AssetRoot $asset
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Die benoetigte Web-Datei fehlt: $assetPath"
    }
}

if ($Port -eq 0) {
    $Port = Get-FreeTcpPort
}

$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
}
catch {
    throw "Der lokale Webserver konnte auf Port $Port nicht gestartet werden: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Duplikatpruefer ist gestartet." -ForegroundColor Cyan
Write-Host "Adresse: $prefix" -ForegroundColor Gray
Write-Host "Mit Strg+C kann die Anwendung beendet werden." -ForegroundColor Gray
Write-Host ""

if (-not $NoBrowser) {
    $chromePath = Get-ChromePath
    if (-not $chromePath) {
        $listener.Stop()
        throw "Google Chrome wurde nicht gefunden. Bitte Chrome installieren oder das Skript mit -NoBrowser starten."
    }
    Start-Process -FilePath $chromePath -ArgumentList @("--new-window", $prefix)
}

try {
    while ($script:Running -and $listener.IsListening) {
        $response = $null
        try {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            $path = $request.Url.AbsolutePath

            $response.Headers["X-Content-Type-Options"] = "nosniff"
            $response.Headers["Referrer-Policy"] = "no-referrer"
            $response.Headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"

            if ($request.HttpMethod -eq "GET" -and $path -eq "/") {
                $html = (Get-WebAsset -Name "index.html").Replace("__SESSION_TOKEN__", [Net.WebUtility]::HtmlEncode($script:SessionToken))
                Send-TextResponse -Response $response -Text $html -ContentType "text/html; charset=utf-8"
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/styles.css") {
                Send-TextResponse -Response $response -Text (Get-WebAsset -Name "styles.css") -ContentType "text/css; charset=utf-8"
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/app.js") {
                Send-TextResponse -Response $response -Text (Get-WebAsset -Name "app.js") -ContentType "application/javascript; charset=utf-8"
                continue
            }
            if ($request.HttpMethod -eq "GET" -and $path -eq "/favicon.ico") {
                $response.StatusCode = 204
                $response.Close()
                continue
            }

            Assert-ApiToken -Request $request

            if ($request.HttpMethod -eq "GET" -and $path -eq "/api/status") {
                Send-JsonResponse -Response $response -Value ([PSCustomObject]@{
                    initialPath = $InitialPath
                    isAdministrator = Test-IsAdministrator
                })
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/browse") {
                $body = Read-JsonRequest -Request $request
                $selectedPath = Show-FolderPicker -SelectedPath ([string]$body.path)
                Send-JsonResponse -Response $response -Value ([PSCustomObject]@{ path = $selectedPath })
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/scan") {
                $body = Read-JsonRequest -Request $request
                $result = Invoke-DuplicateScan -Path ([string]$body.path)
                Send-JsonResponse -Response $response -Value $result
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/delete") {
                $body = Read-JsonRequest -Request $request
                $result = Invoke-ConfirmedDeletion -ScanId ([string]$body.scanId) -Confirmed ([bool]$body.confirmed)
                Send-JsonResponse -Response $response -Value $result
                continue
            }
            if ($request.HttpMethod -eq "POST" -and $path -eq "/api/shutdown") {
                Send-JsonResponse -Response $response -Value ([PSCustomObject]@{ stopped = $true })
                $script:Running = $false
                continue
            }

            Send-JsonResponse -Response $response -Value ([PSCustomObject]@{ error = "Nicht gefunden." }) -StatusCode 404
        }
        catch [UnauthorizedAccessException] {
            Write-Warning ("API-Zugriff abgelehnt: " + $_.Exception.Message)
            if ($response -and $response.OutputStream.CanWrite) {
                Send-JsonResponse -Response $response -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 403
            }
        }
        catch {
            Write-Warning ("API-Fehler: " + $_.Exception.Message)
            if ($_.ScriptStackTrace) {
                Write-Warning $_.ScriptStackTrace
            }
            if ($response -and $response.OutputStream.CanWrite) {
                Send-JsonResponse -Response $response -Value ([PSCustomObject]@{ error = $_.Exception.Message }) -StatusCode 400
            }
        }
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-Host "Duplikatpruefer wurde beendet." -ForegroundColor Yellow
}
