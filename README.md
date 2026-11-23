# Dateisortierer für Windows

Der Dateisortierer durchsucht den gewählten Quellordner samt Unterordnern und verschiebt die Dateien nach Kategorie, Jahr und Monat. Für Dateien vom Juli 2025 sieht die Zielstruktur beispielsweise so aus.

```text
Quellordner\
├── Bilder\2025\07\Urlaub.jpg
├── Videos\2025\07\Ausflug.mp4
├── Dokumente\2025\07\Rechnung.pdf
└── Andere\2025\07\Archiv.zip
```

## Mit der Oberfläche starten

1. Doppelklicke auf **Start.cmd** und bestätige die Windows-Abfrage der Benutzerkontensteuerung (UAC). Die CMD-Datei fordert beim Start Administratorrechte für den lokalen Sortierdienst an. Ob Windows einen Dialog zeigt, hängt von den UAC-Einstellungen und den bereits vorhandenen Rechten ab.
2. Füge in Chrome einen lokalen Pfad wie **D:\Sammlung**, einen Netzlaufwerkspfad wie **Z:\Musik** oder einen UNC-Pfad wie **\\Server\Freigabe\Musik** ins Feld **Quellordner** ein. Auch die Anführungszeichen aus „Als Pfad kopieren“ sind zulässig. Alternativ öffnet **Ordner auswählen …** einen Dialog direkt vor der Seite. Unter **Laufwerke** findest du die verbundenen Laufwerke. Über **Standardordner** öffnest du direkt Dokumente, Downloads, Desktop, Bilder, Musik oder Videos deines Windows-Kontos. Öffne bei Bedarf einen Unterordner und bestätige mit **Diesen Ordner übernehmen**.
3. Klicke auf **Vorschau anzeigen**, um die geplanten Zielpfade zu prüfen. Die Vorschau liest die Dateien. Alle Änderungen erfolgen erst mit **Dateien verschieben** und deiner Bestätigung.
4. Über **Sitzung beenden** schließt du den lokalen Dienst. Wenn du nur das Browserfenster schließt, beendet er sich nach 30 Minuten ohne Anfrage.

Voraussetzungen sind Windows, Windows PowerShell 5.1 und Google Chrome. Belasse die Programmdateien zusammen in einem Ordner. Die Webseite und der Sortierdienst laufen auf deinem Rechner.

Beim Start übernimmt das Programm die verbundenen Netzlaufwerke der aufrufenden Windows-Sitzung. Bei der Auswahl eines solchen Laufwerks zeigt das Pfadfeld anschließend die zugehörige UNC-Adresse. Für Netzwerkordner braucht das bei der UAC-Abfrage verwendete Konto Lesezugriff und zum Verschieben auch Schreib- und Löschrechte auf der Freigabe.

## Duplikate suchen und löschen

Wähle oben neben **Dateisortierer** die **Duplikatsuche**. Beide Werkzeuge verwenden denselben Quellordner und dieselbe Ordnerauswahl. Mit **Duplikate suchen** prüfst du den Ordner samt Unterordnern. Das Werkzeug vergleicht zunächst die Dateigröße und anschließend bei gleich großen Dateien den SHA-256-Hash des Inhalts.

In der Vorschau ist pro Gruppe der alphabetisch erste Pfad zum **Behalten** vorausgewählt. Klicke auf den gewünschten Dateipfad, um die Auswahl zu ändern. Alle übrigen Pfade der Gruppe sind mit **Löschen** markiert. Erst mit **Angezeigte Kopien löschen …** und deiner Bestätigung entfernst du diese Kopien endgültig. Vor dem Löschen prüft das Werkzeug die Inhalte erneut. Hat sich die ausgewählte Datei geändert oder fehlt sie, wird die gesamte Gruppe übersprungen. Das Ergebnis nennt gelöschte und übersprungene Dateien sowie Fehler.

Du kannst auch direkt mit `.\delete_duplicates.ps1` in die Duplikatsuche einsteigen. Mit `-InitialPath 'D:\Sammlung'` belegst du den Quellordner vor.

## Direkt mit PowerShell sortieren

Öffne Windows PowerShell im Skriptordner. Ersetze den Beispielpfad durch deinen Quellordner. Der erste Aufruf zeigt die Vorschau, der zweite verschiebt die Dateien.

```powershell
.\Sortiere-Dateien.ps1 -Quellordner 'D:\Sammlung' -WhatIf
.\Sortiere-Dateien.ps1 -Quellordner 'D:\Sammlung'
```

Falls die Ausführung lokaler Skripte deaktiviert ist, kannst du sie für das aktuelle PowerShell-Fenster mit `Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned` erlauben. Auf verwalteten Geräten haben Gruppenrichtlinien Vorrang. [Microsoft-Dokumentation zu Ausführungsrichtlinien](https://learn.microsoft.com/de-de/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1)

## Sortierregeln

- **Bilder** umfassen unter anderem JPG, PNG, HEIC und Kamera-Rohbilder wie NEF und CR3.
- **Videos** umfassen unter anderem MP4, MOV, AVI und MKV.
- **Dokumente** umfassen unter anderem PDF, Word-, Excel-, PowerPoint- und OpenDocument-Dateien sowie TXT, Markdown, CSV und RTF.
- **Audiodateien** wie MP3, WAV, FLAC, M4A und OGG bleiben in ihrem bisherigen Ordner. Der Sortierer erkennt sie an der Dateiendung.
- **Andere** nimmt Dateien mit unbekannter Endung und Dateien ohne Endung auf. Die vollständigen Endungslisten stehen im [Sortierskript](./Sortiere-Dateien.ps1).
- Die Groß- und Kleinschreibung der Dateiendung spielt keine Rolle. Beide Werkzeuge überspringen beim Durchsuchen symbolische Links, Verzeichnisverbindungen und die eigenen Programm- und Anleitungsdateien am Installationsort.
- Das Windows-Aufnahmedatum hat Vorrang. Fehlt es, zählt das Änderungsdatum. Dies ist bei Dokumenten der übliche Fall. Fehlen beide, verwendet das Skript das älteste verfügbare Datum aus den weiteren Datei- und Metadaten. Fehlt jedes verwendbare Datum, erscheint ein Hinweis und die Datei bleibt am Platz.
- Beim Verschieben entstehen alle vier Kategorieordner. Jahres- und zweistellige Monatsordner entstehen nach Bedarf. Auch Dateien in früheren Jahres- und Monatsordnern werden einsortiert. Leere Quellordner bleiben erhalten.
- Ist der Zielname belegt, erhält die hinzukommende Datei einen Zusatz wie `Rechnung (1).pdf`. Bei einem erneuten Lauf zählt das Skript bereits richtig einsortierte Dateien und lässt sie am Platz.
