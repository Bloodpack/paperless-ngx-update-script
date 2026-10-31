# Paperless-ngx Update-Skript

Ein Bash-Skript zum Aktualisieren oder Reparieren einer **nativen Paperless-ngx-Installation** auf Ubuntu. Die Bedienung erfolgt vollständig über ein Textmenü in der SSH-Konsole – ohne `dialog` oder grafische Fenster.

> **Wichtig:** Dieses Skript ist auf eine konkrete Installationsumgebung ausgelegt. Vor der Verwendung müssen die Einstellungen im Kopf der Skriptdatei mit der eigenen Installation übereinstimmen. Es ist kein allgemeines Installations- oder Update-Skript für jede Paperless-ngx-Umgebung.

## Funktionen

- Prüft die installierte Paperless-ngx-Version und fragt die aktuelle GitHub-Release-Version ab.
- Bietet ein Textmenü für Update, Reparatur, erzwungenes Update oder Abbruch.
- Verhindert Downgrades.
- Lädt das Release-Archiv herunter und prüft unter anderem den `xz`-Integritätstest, die Archivpfade und die Version im Archiv.
- Stoppt die Paperless-Dienste für ein konsistentes Backup.
- Erstellt eine vollständige Dateikopie der Installation sowie PostgreSQL-Dumps.
- Prüft die Dateikopie und den PostgreSQL-Dump vor der Veröffentlichung des Backups.
- Richtet `pip` bei Bedarf mit `ensurepip` ein und installiert anschließend die Python-Abhängigkeiten.
- Führt Datenbankmigrationen und weitere Paperless-Verwaltungsbefehle aus.
- Prüft nach der Installation die Version und den Status der Paperless-Dienste.
- **Löscht vorhandene Backups nicht automatisch.**

## Menü

Beim Start erscheint eine Auswahl in der Konsole:

```text
========================================
       PAPERLESS-NGX UPDATE
========================================
Installierte Version : 3.4.1
Verfügbare Version   : 3.4.1

Bitte Aktion auswählen:

  1) Normales Update
     Nur installieren, wenn GitHub neuer ist.

  2) Reparatur
     Installierte Version erneut installieren.

  3) Erzwungenes Update
     GitHub-Version installieren, sofern kein Downgrade.

  4) Abbrechen

Ihre Auswahl [1-4]:
```

### Menüoptionen

| Option | Funktion |
|---|---|
| `1` – Normales Update | Installiert die GitHub-Version nur, wenn sie neuer als die installierte Version ist. |
| `2` – Reparatur | Lädt die aktuell installierte Version erneut herunter und installiert sie erneut. |
| `3` – Erzwungenes Update | Installiert die aktuelle GitHub-Version auch dann, wenn sie der installierten Version entspricht. Ein Downgrade wird verhindert. |
| `4` – Abbrechen | Beendet das Skript ohne Update. |

## Voraussetzungen

Das Skript erwartet eine native Installation mit folgender Struktur und Konfiguration:

| Einstellung | Erwarteter Wert |
|---|---|
| Betriebssystem | Ubuntu 26.04 (Zielumgebung) |
| Paperless-Verzeichnis | `/opt/paperless` |
| Paperless-Benutzer | `paperless` |
| Virtuelle Python-Umgebung | `/opt/paperless/venv` |
| Konfiguration | `/opt/paperless/paperless.conf` |
| Backup-Verzeichnis | `/opt/paperless-backup` |
| PostgreSQL-Datenbank | `paperlessdb` |
| PostgreSQL-Port | `5433` |
| Update-Log | `/var/log/paperless-update.log` |

Die Werte sind im Skript als Variablen hinterlegt und müssen bei abweichender Installation angepasst werden.

### Benötigte Systemprogramme

Das Skript prüft beim Start, ob folgende Programme verfügbar sind:

- `curl`
- `jq`
- `tar`
- `xz`
- `rsync`
- `sudo`
- `systemctl`
- `systemd-run`
- `python3`
- `sha256sum`
- `pg_dump`, `pg_dumpall`, `pg_restore`, `psql`
- `flock`
- `du`, `df`, `stat`, `mktemp`
- `awk`, `find`, `sort`, `dirname`
- `rm`, `chmod`, `chown`

Außerdem werden systemd-Dienste mit diesen Namen erwartet:

- `paperless-consumer`
- `paperless-task-queue`
- `paperless-scheduler`
- `paperless-webserver`

Die Datei `/opt/paperless/paperless.conf` muss vorhanden sein, dem Benutzer `paperless` gehören und die vom Skript abgefragten Datenbankwerte enthalten. Das Skript liest die Datei über systemd als `EnvironmentFile`; es lädt sie ausdrücklich nicht mit Bash `source`.

## Installation

1. Lade `paperless_update.sh` aus diesem Repository herunter.
2. Prüfe die Konfigurationswerte am Anfang der Datei und passe sie gegebenenfalls an.
3. Übertrage die Datei auf den Paperless-Server, zum Beispiel nach:

   ```text
   /opt/projects/paperless-ngx-update-script/paperless_update.sh
   ```

4. Setze das Ausführungsrecht:

   ```bash
   chmod 750 /opt/projects/paperless-ngx-update-script/paperless_update.sh
   ```

5. Prüfe die Bash-Syntax:

   ```bash
   bash -n /opt/projects/paperless-ngx-update-script/paperless_update.sh
   ```

6. Starte das Skript als `root`:

   ```bash
   /opt/projects/paperless-ngx-update-script/paperless_update.sh
   ```

Alternativ kann es direkt mit Bash gestartet werden:

```bash
bash /opt/projects/paperless-ngx-update-script/paperless_update.sh
```

## Ablauf und Backup

Vor dem Austausch der Programmdateien führt das Skript folgende Schritte aus:

1. Prüft die Installation, Konfiguration, Datenbankverbindung und den verfügbaren Speicherplatz.
2. Lädt das gewünschte Paperless-ngx-Release herunter und prüft das Archiv.
3. Stoppt die vier Paperless-Dienste.
4. Kopiert `/opt/paperless` vollständig in ein neues Backup-Verzeichnis.
5. Erstellt einen PostgreSQL-Dump im Custom-Format und sichert die PostgreSQL-Rollen.
6. Prüft die Dateikopie, den PostgreSQL-Dump und die Prüfsummen der Datenbank-Backups.
7. Benennt das Backup erst nach erfolgreicher Prüfung in ein reguläres Backup-Verzeichnis um.

Backups werden nach folgendem Muster angelegt:

```text
/opt/paperless-backup/paperless-backup-JJJJMMTT-HHMMSS/
```

Ein Backup enthält unter anderem:

```text
filesystem/
postgresql-paperlessdb.dump
postgresql-globals.sql
SHA256SUMS
README.txt
```

Das Backup-Verzeichnis wird mit restriktiven Rechten angelegt. **Das Skript löscht keine älteren oder vorhandenen Backups automatisch.** Die Aufbewahrung und das Entfernen alter Sicherungen bleiben Aufgabe des Administrators.

> Die Erstellung und Prüfung eines Backups ist kein vollständiger Wiederherstellungstest. Ein Restore sollte separat und kontrolliert getestet werden.

## Fehlerverhalten

- Tritt ein Fehler auf, bevor die Programmdateien ausgetauscht wurden, versucht das Skript, die zuvor gestoppten Paperless-Dienste wieder zu starten.
- Tritt ein Fehler auf, nachdem der Austausch der Programmdateien begonnen hat, bleiben die Dienste aus Sicherheitsgründen gestoppt. Das soll verhindern, dass Paperless mit einem unvollständigen oder gemischten Programmstand gestartet wird.
- In diesem Fall zuerst das Log und den angegebenen Backup-Pfad prüfen. Eine Wiederherstellung sollte kontrolliert und passend zur Installation erfolgen. Das Skript führt **keine automatische Wiederherstellung** durch.

## Protokoll

Das Skript schreibt sein Protokoll nach:

```text
/var/log/paperless-update.log
```

Die Ausgaben werden außerdem in der Konsole angezeigt.

## Sicherheitshinweise

- Vor dem ersten Einsatz eine unabhängige Sicherung der VM bzw. des Servers erstellen.
- Das Skript zunächst in einer Testumgebung prüfen.
- Vor jedem Lauf sicherstellen, dass ausreichend freier Speicherplatz für eine vollständige Dateikopie und den Datenbank-Dump vorhanden ist.
- Das Skript benötigt Root-Rechte und verändert Programmdateien sowie die Python-Umgebung von Paperless-ngx.
- Während des Backups und der Installation sind die Paperless-Dienste gestoppt.
- Das Skript ist auf die oben angegebene native Installation zugeschnitten. Docker-, Podman- oder andere Installationsvarianten werden nicht unterstützt.
- Die Release-Dateien werden von den offiziellen Paperless-ngx-GitHub-Releases bezogen.

