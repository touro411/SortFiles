# Auch bei Auswahl des Programmordners muss ein weiterer Start möglich bleiben.
$programmdateien = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in 'Start.cmd','Start-Oberflaeche.ps1','Oberflaeche.html','Sortiere-Dateien.ps1','README.md','delete_duplicates.ps1','Dateipruefung.psm1') {
    [void]$programmdateien.Add((Join-Path $PSScriptRoot $name))
}

function Get-Quelldateien {
    [CmdletBinding()]param([IO.DirectoryInfo]$ordner)
    $offen = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $offen.Push($ordner)
    while ($offen.Count) {
        $aktuell = $offen.Pop()
        try {
            foreach ($element in $aktuell.EnumerateFileSystemInfos()) {
                if (($element.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $element.LinkType) { continue }
                if ($element -is [IO.DirectoryInfo]) { $offen.Push($element) }
                elseif (-not $programmdateien.Contains($element.FullName)) { $element }
            }
        } catch { Write-Error "Ordner nicht vollständig lesbar '$($aktuell.FullName)': $_" }
    }
}

function Invoke-DuplicateScan {
    param([Parameter(Mandatory = $true)][string]$Path)

    $script:CurrentScan = $null
    $resolvedPath = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).FullName
    $scanErrors = @()
    $files = @(
        Get-Quelldateien -ordner $resolvedPath -ErrorAction SilentlyContinue -ErrorVariable +scanErrors
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

function Open-VerifiedFile($entry, [string]$root, [IO.FileShare]$share) {
    $file = [IO.FileInfo]::new($entry.Path)
    $prefix = $root.TrimEnd('\') + '\'
    if (-not $file.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Die Datei liegt außerhalb des geprüften Ordners.'
    }
    # Auch nach dem Scan darf kein Unterordner durch eine Verknüpfung ersetzt worden sein.
    $item = $file
    while ($null -ne $item) {
        if (-not $item.Exists -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.LinkType)) {
            throw 'Datei oder Ordner fehlt oder ist eine Verknüpfung.'
        }
        if ($item.FullName.TrimEnd('\') -eq $root.TrimEnd('\')) { break }
        if ($item -is [IO.FileInfo]) { $item = $file.Directory }
        else { $item = $item.Parent }
    }
    $stream = $file.Open([IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        if ($stream.Length -ne $entry.Length -or
            (Get-FileHash -InputStream $stream -Algorithm SHA256 -ErrorAction Stop).Hash -cne $entry.Hash) {
            throw 'Der Dateiinhalt hat sich seit der Suche geändert.'
        }
        return $stream
    } catch { $stream.Dispose(); throw }
}

function Invoke-ConfirmedDeletion {
    param(
        [Parameter(Mandatory = $true)][string]$ScanId,
        [Parameter(Mandatory = $true)][bool]$Confirmed
    )

    if (-not $Confirmed) {
        throw "Die Löschbestätigung fehlt."
    }
    if ($null -eq $script:CurrentScan -or $script:CurrentScan.Id -cne $ScanId) {
        throw "Die Scan-Vorschau ist nicht mehr aktuell. Bitte erneut suchen."
    }

    $results = New-Object System.Collections.Generic.List[object]
    $deletedCount = 0
    $skippedCount = 0
    $errorCount = 0
    $freedBytes = [int64]0

    $scan = $script:CurrentScan
    $script:CurrentScan = $null
    foreach ($group in $scan.Groups) {
        try {
            # Die verbleibende Kopie während der gesamten Gruppe gegen Schreiben und Löschen sperren.
            $keeper = Open-VerifiedFile $group.Keep $scan.RootPath ([IO.FileShare]::Read)
        } catch {
            foreach ($duplicate in $group.Delete) {
                $skippedCount++
                $results.Add([PSCustomObject]@{ Path = $duplicate.Path; Status = 'skipped'; Message = "Verbleibende Datei konnte nicht bestätigt werden: $_" })
            }
            continue
        }
        try {
            foreach ($duplicate in $group.Delete) {
                try {
                    $copy = Open-VerifiedFile $duplicate $scan.RootPath ([IO.FileShare]'Read, Delete')
                } catch {
                    $skippedCount++
                    $results.Add([PSCustomObject]@{ Path = $duplicate.Path; Status = 'skipped'; Message = $_.Exception.Message })
                    continue
                }
                try {
                    Remove-Item -LiteralPath $duplicate.Path -Force -ErrorAction Stop
                    $deletedCount++
                    $freedBytes += [int64]$duplicate.Length
                    $results.Add([PSCustomObject]@{ Path = $duplicate.Path; Status = 'deleted'; Message = 'Datei gelöscht.' })
                } catch {
                    $errorCount++
                    $results.Add([PSCustomObject]@{ Path = $duplicate.Path; Status = 'error'; Message = $_.Exception.Message })
                } finally { $copy.Dispose() }
            }
        } finally { $keeper.Dispose() }
    }
    return [PSCustomObject]@{
        DeletedCount = $deletedCount
        SkippedCount = $skippedCount
        ErrorCount = $errorCount
        FreedBytes = $freedBytes
        Results = $results.ToArray()
    }
}

function Clear-DuplicateScan {
    $script:CurrentScan = $null
}

Export-ModuleMember -Function Get-Quelldateien, Invoke-DuplicateScan, Invoke-ConfirmedDeletion, Clear-DuplicateScan