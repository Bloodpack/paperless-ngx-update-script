#!/usr/bin/env bash
###############################################################################
# Paperless-ngx Update-Skript – native Installation
# Angepasst für: /opt/paperless, PostgreSQL 18 (Port 5433), Ubuntu 26.04
# Erstellt vollständige, dauerhaft aufbewahrte Backups unter /opt/paperless-backup
###############################################################################
set -Eeuo pipefail

PAPERLESS_USER="paperless"
INSTALL_DIR="/opt/paperless"
VENV_DIR="$INSTALL_DIR/venv"
BACKUP_DIR="/opt/paperless-backup"
TMP_DIR="/tmp/paperless-update-$$"
LOGFILE="/var/log/paperless-update.log"
PAPERLESS_CONFIG_FILE="$INSTALL_DIR/paperless.conf"
DB_NAME="paperlessdb"
DB_PORT="5433"
GITHUB_API="https://api.github.com/repos/paperless-ngx/paperless-ngx/releases/latest"

SERVICES=(paperless-consumer paperless-task-queue paperless-scheduler paperless-webserver)
SERVICES_STOPPED=0
LIVE_LOG_PID=""
CURRENT_BACKUP=""

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"
}

fatal() {
    log "FEHLER: $*"
    if command -v dialog >/dev/null 2>&1 && [[ -t 1 ]]; then
        dialog --title "Paperless-ngx – Fehler" --msgbox "$*" 10 72 || true
    else
        printf 'FEHLER: %s\n' "$*" >&2
    fi
    exit 1
}

start_services() {
    local failed=0 service
    for service in "${SERVICES[@]}"; do
        if ! systemctl start "$service"; then
            log "FEHLER beim Start von $service"
            failed=1
        fi
    done
    return "$failed"
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ "$SERVICES_STOPPED" -eq 1 ]]; then
        log "Sicherheitsmaßnahme: Paperless-Dienste nach Skriptabbruch erneut starten."
        if start_services; then
            log "Dienste wurden durch die Fehlerbehandlung gestartet."
        else
            log "WARNUNG: Mindestens ein Dienst konnte durch die Fehlerbehandlung nicht gestartet werden."
        fi
    fi
    if [[ -n "$LIVE_LOG_PID" ]]; then
        kill "$LIVE_LOG_PID" 2>/dev/null || true
        wait "$LIVE_LOG_PID" 2>/dev/null || true
    fi
    rm -rf -- "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT

version_tuple() {
    [[ "$1" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    printf '%d %d %d\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

version_compare() {
    # Rückgabe: 0 = gleich, 1 = links neuer, 2 = links älter
    local -a a b
    read -r -a a <<< "$(version_tuple "$1")" || return 3
    read -r -a b <<< "$(version_tuple "$2")" || return 3
    local i
    for i in 0 1 2; do
        if (( a[i] > b[i] )); then return 1; fi
        if (( a[i] < b[i] )); then return 2; fi
    done
    return 0
}

get_version_from_file() {
    local file="$1"
    python3 - "$file" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"__version__\s*:\s*Final\[tuple\[int,\s*int,\s*int\]\]\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)", text)
if not m:
    m = re.search(r"__version__\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)", text)
if not m:
    raise SystemExit(1)
print(".".join(m.groups()))
PY
}

run_as_paperless() {
    # paperless.conf ist eine shell-kompatible EnvironmentFile-Datei und wird
    # unter dem unprivilegierten Paperless-Konto eingelesen.
    sudo -u "$PAPERLESS_USER" /bin/bash -c '
        set -Eeuo pipefail
        set -a
        # shellcheck disable=SC1090
        source "$1"
        set +a
        shift
        cd "$1"
        shift
        exec "$@"
    ' _ "$PAPERLESS_CONFIG_FILE" "$INSTALL_DIR/src" "$@"
}

[[ "$EUID" -eq 0 ]] || { echo "Bitte mit sudo bzw. als root starten." >&2; exit 1; }

for cmd in curl jq tar xz rsync sudo systemctl dialog python3 sha256sum pg_dump pg_dumpall psql; do
    command -v "$cmd" >/dev/null 2>&1 || fatal "Benötigtes Programm fehlt: $cmd"
done

[[ -d "$INSTALL_DIR" ]] || fatal "Paperless-Verzeichnis fehlt: $INSTALL_DIR"
[[ -x "$VENV_DIR/bin/python" ]] || fatal "Python-Virtualenv fehlt: $VENV_DIR/bin/python"
[[ -f "$INSTALL_DIR/requirements.txt" ]] || fatal "requirements.txt fehlt."
[[ -f "$INSTALL_DIR/src/manage.py" ]] || fatal "manage.py fehlt."
[[ -f "$INSTALL_DIR/src/paperless/version.py" ]] || fatal "Paperless-Versiondatei fehlt."
[[ -f "$PAPERLESS_CONFIG_FILE" ]] || fatal "Konfigurationsdatei fehlt: $PAPERLESS_CONFIG_FILE"
[[ "$(stat -c '%U' "$PAPERLESS_CONFIG_FILE")" == "$PAPERLESS_USER" ]] || fatal "paperless.conf gehört nicht dem Benutzer paperless. Bitte erst die Dateirechte prüfen."

# Vorab sicherstellen, dass die Konfiguration syntaktisch als Shell-Datei lesbar ist.
sudo -u "$PAPERLESS_USER" bash -n "$PAPERLESS_CONFIG_FILE" || fatal "paperless.conf ist nicht shell-kompatibel. Das Skript liest sie deshalb nicht ein."

CURRENT_VERSION="$(get_version_from_file "$INSTALL_DIR/src/paperless/version.py")" || fatal "Installierte Paperless-Version konnte nicht gelesen werden."
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "Unbekanntes Versionsformat: $CURRENT_VERSION"

API_JSON="$(curl --fail --location --silent --show-error --retry 3 "$GITHUB_API")" || fatal "GitHub-Release-API ist nicht erreichbar."
LATEST_VERSION="$(jq -er '.tag_name | sub("^v"; "")' <<< "$API_JSON")" || fatal "GitHub-Version konnte nicht ermittelt werden."
[[ "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "Unerwartetes GitHub-Versionsformat: $LATEST_VERSION"

# PostgreSQL-Verbindung und Datenbank vor dem Menü prüfen.
sudo -u postgres psql -p "$DB_PORT" -d "$DB_NAME" -Atqc 'SELECT 1' >/dev/null || fatal "PostgreSQL-Datenbank $DB_NAME auf Port $DB_PORT ist nicht erreichbar."

mkdir -p "$TMP_DIR" "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
touch "$LOGFILE"
chmod 600 "$LOGFILE"

printf '\nInstalliert: %s\nGitHub:      %s\n\n' "$CURRENT_VERSION" "$LATEST_VERSION"

if ! command -v dialog >/dev/null 2>&1; then fatal "dialog fehlt. Installation: sudo apt install dialog"; fi

CHOICE="$(dialog --clear --title "Paperless-ngx Update" \
    --menu "Installiert: $CURRENT_VERSION\nGitHub: $LATEST_VERSION\n\nBitte Aktion wählen:" \
    18 78 4 \
    1 "Update – nur wenn GitHub neuer ist" \
    2 "Reparatur – installierte Version erneut installieren" \
    3 "Erzwungenes Update – GitHub-Version bei gleich/neuer" \
    4 "Abbruch" --stdout)" || exit 0

case "$CHOICE" in
    1)
        version_compare "$LATEST_VERSION" "$CURRENT_VERSION" || cmp=$?
        cmp=${cmp:-0}
        if [[ "$cmp" -eq 2 ]]; then fatal "GitHub ($LATEST_VERSION) ist älter als installiert ($CURRENT_VERSION). Downgrade wird verhindert."; fi
        if [[ "$cmp" -eq 0 ]]; then
            dialog --title "Kein Update verfügbar" --msgbox "Paperless ist bereits auf Version $CURRENT_VERSION.\n\nFür eine erneute Installation derselben GitHub-Version bitte 'Erzwungenes Update' wählen." 9 72 || true
            exit 0
        fi
        TARGET_VERSION="$LATEST_VERSION"
        ACTION_NAME="Normales Update"
        ;;
    2)
        TARGET_VERSION="$CURRENT_VERSION"
        ACTION_NAME="Reparatur"
        ;;
    3)
        version_compare "$LATEST_VERSION" "$CURRENT_VERSION" || cmp=$?
        cmp=${cmp:-0}
        if [[ "$cmp" -eq 2 ]]; then fatal "GitHub ($LATEST_VERSION) ist älter als installiert ($CURRENT_VERSION). Downgrade wird verhindert."; fi
        TARGET_VERSION="$LATEST_VERSION"
        ACTION_NAME="Erzwungenes Update"
        ;;
    4) exit 0 ;;
    *) exit 0 ;;
esac

log "Aktion: $ACTION_NAME | Installiert: $CURRENT_VERSION | Ziel: $TARGET_VERSION"

# Release herunterladen und vollständig prüfen, BEVOR die Installation angefasst wird.
ARCHIVE="$TMP_DIR/paperless-ngx-v${TARGET_VERSION}.tar.xz"
DOWNLOAD_URL="https://github.com/paperless-ngx/paperless-ngx/releases/download/v${TARGET_VERSION}/paperless-ngx-v${TARGET_VERSION}.tar.xz"
log "Lade Release $TARGET_VERSION herunter."
curl --fail --location --silent --show-error --retry 3 "$DOWNLOAD_URL" -o "$ARCHIVE" || fatal "Release-Download fehlgeschlagen: $DOWNLOAD_URL"
[[ -s "$ARCHIVE" ]] || fatal "Heruntergeladenes Archiv ist leer."
xz -t "$ARCHIVE" || fatal "Das heruntergeladene Archiv besteht den xz-Integritätstest nicht."

# Pfad-Traversal-Einträge ablehnen, bevor tar entpackt.
if tar -tf "$ARCHIVE" | awk 'BEGIN{bad=0} /^\// {bad=1} /(^|\/)\.\.(\/|$)/ {bad=1} END{exit bad?0:1}'; then
    fatal "Das Release-Archiv enthält unzulässige Pfade."
fi
mkdir -p "$TMP_DIR/extract"
tar -xf "$ARCHIVE" -C "$TMP_DIR/extract"
mapfile -t TOP_DIRS < <(find "$TMP_DIR/extract" -mindepth 1 -maxdepth 1 -type d -print)
[[ "${#TOP_DIRS[@]}" -eq 1 ]] || fatal "Im Archiv wurde nicht genau ein Release-Hauptverzeichnis gefunden."
NEW_SOURCE="${TOP_DIRS[0]}"
[[ -f "$NEW_SOURCE/src/paperless/version.py" && -f "$NEW_SOURCE/requirements.txt" ]] || fatal "Das entpackte Release hat nicht die erwartete Paperless-Struktur."
ARCHIVE_VERSION="$(get_version_from_file "$NEW_SOURCE/src/paperless/version.py")" || fatal "Version im Release-Archiv konnte nicht ermittelt werden."
[[ "$ARCHIVE_VERSION" == "$TARGET_VERSION" ]] || fatal "Versionsabweichung: angefordert $TARGET_VERSION, Archiv enthält $ARCHIVE_VERSION."

# Backup-Ziel eindeutig und dauerhaft anlegen.
BACKUP_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
CURRENT_BACKUP="$BACKUP_DIR/paperless-backup-$BACKUP_TIMESTAMP"
mkdir -m 700 "$CURRENT_BACKUP"

# Live-Log in separatem Terminalbereich starten, falls ein Terminal vorhanden ist.
if [[ -t 1 ]]; then
    clear
    echo "=== Paperless-ngx Update – Live-Log ==="
    tail -n 20 -f "$LOGFILE" &
    LIVE_LOG_PID=$!
fi

log "Stoppe Paperless-Dienste für konsistentes Backup."
# Bereits beim ersten Stop-Versuch aktivieren, damit ein Teilfehler
# ebenfalls zum erneuten Start aller Dienste in cleanup() führt.
SERVICES_STOPPED=1
for service in "${SERVICES[@]}"; do
    systemctl stop "$service" || fatal "Dienst $service konnte nicht gestoppt werden."
done

# Vollständige Dateikopie inklusive venv, Konfiguration, Daten, Medien und Consume.
log "Erstelle vollständiges Dateibackup nach $CURRENT_BACKUP/filesystem."
mkdir "$CURRENT_BACKUP/filesystem"
rsync -aHAX --numeric-ids "$INSTALL_DIR/" "$CURRENT_BACKUP/filesystem/" || fatal "Dateibackup fehlgeschlagen."

# PostgreSQL-Backup: custom-format DB-Dump plus Rollen/Globaleinstellungen.
log "Sichere PostgreSQL-Datenbank $DB_NAME auf Port $DB_PORT."
sudo -u postgres pg_dump -Fc -p "$DB_PORT" -d "$DB_NAME" > "$CURRENT_BACKUP/postgresql-$DB_NAME.dump" || fatal "PostgreSQL-Datenbankdump fehlgeschlagen."
sudo -u postgres pg_dumpall --globals-only -p "$DB_PORT" > "$CURRENT_BACKUP/postgresql-globals.sql" || fatal "PostgreSQL-Rollenbackup fehlgeschlagen."
[[ -s "$CURRENT_BACKUP/postgresql-$DB_NAME.dump" && -s "$CURRENT_BACKUP/postgresql-globals.sql" ]] || fatal "PostgreSQL-Backup ist unvollständig."

{
    echo "Paperless-ngx Backup"
    echo "Zeitpunkt: $(date --iso-8601=seconds)"
    echo "Installierte Version: $CURRENT_VERSION"
    echo "Zielversion: $TARGET_VERSION"
    echo "Aktion: $ACTION_NAME"
    echo "Installationsverzeichnis: $INSTALL_DIR"
    echo "Datenbank: $DB_NAME"
    echo "PostgreSQL-Port: $DB_PORT"
    echo "Dateien: filesystem/ (vollständige Kopie von $INSTALL_DIR)"
    echo "Datenbank: postgresql-$DB_NAME.dump (pg_dump -Fc)"
    echo "Rollen: postgresql-globals.sql"
    echo "Dieses Backup wird vom Skript NICHT automatisch gelöscht."
} > "$CURRENT_BACKUP/README.txt"
sha256sum "$CURRENT_BACKUP/postgresql-$DB_NAME.dump" "$CURRENT_BACKUP/postgresql-globals.sql" > "$CURRENT_BACKUP/SHA256SUMS"
chmod -R go-rwx "$CURRENT_BACKUP"
log "Backup erfolgreich erstellt: $CURRENT_BACKUP"

# Alte Programmdateien entfernen, persistente Verzeichnisse behalten.
# Entspricht der offiziellen Bare-Metal-Anleitung; export/log bleiben ebenfalls erhalten.
log "Entferne alte Release-Dateien (Daten, Medien, Consume, venv, Export und Logs bleiben erhalten)."
find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.env' \
    ! -name 'paperless.conf' \
    ! -name 'data' \
    ! -name 'media' \
    ! -name 'consume' \
    ! -name 'venv' \
    ! -name 'export' \
    ! -name 'log' \
    -exec rm -rf -- {} +

log "Kopiere geprüfte Release-Dateien nach $INSTALL_DIR."
rsync -a --chown="$PAPERLESS_USER:$PAPERLESS_USER" \
    --exclude='data' --exclude='media' --exclude='consume' --exclude='export' \
    --exclude='venv' --exclude='.env' --exclude='paperless.conf' --exclude='log' \
    "$NEW_SOURCE/" "$INSTALL_DIR/" || fatal "Kopieren der Release-Dateien fehlgeschlagen."

# Sicherstellen, dass Paperless-Konfiguration und Virtualenv nicht überschrieben wurden.
[[ -f "$PAPERLESS_CONFIG_FILE" && -x "$VENV_DIR/bin/python" ]] || fatal "Konfiguration oder Virtualenv fehlt nach dem Dateiaustausch."
chown "$PAPERLESS_USER:$PAPERLESS_USER" "$PAPERLESS_CONFIG_FILE"
chmod 600 "$PAPERLESS_CONFIG_FILE"
if [[ -f "$INSTALL_DIR/.env" ]]; then
    chown "$PAPERLESS_USER:$PAPERLESS_USER" "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
fi

log "Aktualisiere Python-Abhängigkeiten."
run_as_paperless "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel || fatal "pip/setuptools/wheel konnten nicht aktualisiert werden. Backup: $CURRENT_BACKUP"
run_as_paperless "$VENV_DIR/bin/python" -m pip install --upgrade -r "$INSTALL_DIR/requirements.txt" || fatal "Python-Abhängigkeiten konnten nicht installiert werden. Backup: $CURRENT_BACKUP"

log "Führe Datenbankmigrationen aus."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" migrate --noinput || fatal "Datenbankmigration fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Erzeuge statische Dateien."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" collectstatic --noinput || fatal "collectstatic fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Aktualisiere Suchindex (falls erforderlich)."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" document_index reindex --if-needed || fatal "Suchindex-Aktualisierung fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Migriere LLM-Index (falls aktiviert/konfiguriert)."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" document_llmindex migrate || fatal "LLM-Index-Migration fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Aktualisiere den Paperless-Klassifikator."
if ! run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" document_create_classifier >> "$LOGFILE" 2>&1; then
    log "WARNUNG: document_create_classifier ist fehlgeschlagen; Details stehen im Update-Log."
fi

log "Starte Paperless-Dienste."
start_services || fatal "Mindestens ein Paperless-Dienst konnte nicht gestartet werden. Backup: $CURRENT_BACKUP"

FAILED_SERVICES=()
for service in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$service" || FAILED_SERVICES+=("$service")
done
if [[ "${#FAILED_SERVICES[@]}" -gt 0 ]]; then
    fatal "Folgende Dienste laufen nicht: ${FAILED_SERVICES[*]}. Backup: $CURRENT_BACKUP"
fi
SERVICES_STOPPED=0

NEW_VERSION="$(get_version_from_file "$INSTALL_DIR/src/paperless/version.py")" || fatal "Neue Version konnte nach der Installation nicht gelesen werden."
[[ "$NEW_VERSION" == "$TARGET_VERSION" ]] || fatal "Nachprüfung fehlgeschlagen: installiert $NEW_VERSION, erwartet $TARGET_VERSION."

log "ERFOLG: $ACTION_NAME abgeschlossen. Version: $CURRENT_VERSION -> $NEW_VERSION"
log "Backup dauerhaft aufbewahrt unter: $CURRENT_BACKUP"

if command -v dialog >/dev/null 2>&1; then
    dialog --title "Paperless-ngx erfolgreich" --msgbox "Aktion: $ACTION_NAME\nAlte Version: $CURRENT_VERSION\nNeue Version: $NEW_VERSION\n\nAlle vier Dienste laufen.\n\nBackup dauerhaft gespeichert unter:\n$CURRENT_BACKUP" 14 78 || true
else
    echo "Erfolgreich: $CURRENT_VERSION -> $NEW_VERSION"
    echo "Backup: $CURRENT_BACKUP"
fi

exit 0
