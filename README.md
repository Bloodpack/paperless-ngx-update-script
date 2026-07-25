# Paperless-ngx Update Script

Dieses Repository enthält ein Bash-Skript für die Aktualisierung einer lokalen Paperless-ngx-Installation auf einem Ubuntu-System mit einer Bare-Metal-Installation unter `/opt/paperless`.

## Überblick

Das Skript führt folgende Schritte aus:

- prüft, ob die benötigten Programme vorhanden sind
- liest die installierte Version aus der lokalen Datei `/opt/paperless/src/paperless/version.py`
- fragt über einen grafischen Dialog zwischen Update, Reparatur oder Abbruch
- stoppt die relevanten Paperless-Dienste
- erstellt ein Backup der Konfiguration, Datenbank und Medien
- lädt das aktuelle GitHub-Release herunter
- aktualisiert die Dateien im Installationsverzeichnis
- führt `pip`, `migrate`, `collectstatic` und weitere Paperless-Operationen aus
- startet die Dienste neu
- zeigt den Verlauf im Live-Log an
- räumt temporäre Dateien und Backup-Ordner auf

## Voraussetzungen

Das Skript wurde für folgende Umgebung entwickelt:

- Ubuntu 24.04 LTS
- Paperless-ngx Installation unter `/opt/paperless`
- Benutzer `paperless`
- Python Virtual Environment unter `/opt/paperless/venv`

Erforderliche Pakete:

- `bash`
- `curl`
- `jq`
- `wget`
- `tar`
- `rsync`
- `dialog`

## Installation

1. Repository klonen oder die Datei `paperless_update.sh` herunterladen.
2. Ausführbar machen:

```bash
chmod +x paperless_update.sh
```

3. Als Root ausführen:

```bash
sudo ./paperless_update.sh
```

## Hinweise zur Nutzung

- Das Skript ist auf die hier beschriebene Struktur ausgelegt und wurde für genau diese Installation entwickelt.
- Vor dem Einsatz sollte man eine eigene Sicherheitsprüfung durchführen.
- Es ist sinnvoll, vor dem ersten Einsatz zunächst die Datei zu prüfen und die Pfade bei Bedarf anzupassen.

## Haftungsausschluss

Dieses Skript wird ohne jegliche Gewährleistung bereitgestellt. Es wird ausschließlich zu Demonstrations- und Administrationszwecken bereitgestellt.

Ich übernehme keine Verantwortung für Schäden, Datenverluste, Ausfallzeiten oder sonstige Folgen, die durch die Ausführung dieses Skripts auf anderen Systemen oder in anderen Umgebungen entstehen. Jeder Nutzer ist allein dafür verantwortlich, die Funktionsweise des Skripts zu prüfen, die Sicherheit zu beurteilen und die geeigneten Maßnahmen für sein eigenes System zu treffen.

## Lizenz

Dieses Projekt steht unter der gleichen Lizenz wie das Repository, sofern keine andere Lizenz angegeben ist.
