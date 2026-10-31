#!/usr/bin/env bash
###############################################################################
# Paperless-ngx Update-Skript – native Installation
# Zielsystem: /opt/paperless, PostgreSQL 18 auf Port 5433, Ubuntu 26.04
# Konsolenmenü ohne dialog; keine automatische Löschung vorhandener Backups
###############################################################################
set -Eeuo pipefail

PAPERLESS_USER="paperless"
INSTALL_DIR="/opt/paperless"
VENV_DIR="$INSTALL_DIR/venv"
BACKUP_DIR="/opt/paperless-backup"
TMP_DIR=""
LOGFILE="/var/log/paperless-update.log"
PAPERLESS_CONFIG_FILE="$INSTALL_DIR/paperless.conf"
DB_NAME="paperlessdb"
DB_PORT="5433"
GITHUB_API="https://api.github.com/repos/paperless-ngx/paperless-ngx/releases/latest"
SERVICES=(paperless-consumer paperless-task-queue paperless-scheduler paperless-webserver)
SERVICES_STOPPED=0
UPDATE_STARTED=0
CURRENT_BACKUP=""

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"
}

fatal() {
    log "FEHLER: $*"
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

stop_services_best_effort() {
    local service
    for service in "${SERVICES[@]}"; do
        systemctl stop "$service" || log "WARNUNG: $service konnte nicht gestoppt werden."
    done
}

cleanup() {
    local rc=$?
    trap - EXIT

    if [[ "$SERVICES_STOPPED" -eq 1 ]]; then
        if [[ "$UPDATE_STARTED" -eq 0 ]]; then
            log "Fehler vor dem Austausch der Programmdateien: starte Paperless-Dienste erneut."
            if start_services; then
                log "Paperless-Dienste wurden wieder gestartet."
            else
                log "WARNUNG: Mindestens ein Paperless-Dienst konnte nicht gestartet werden."
            fi
        else
            log "ACHTUNG: Update wurde bereits begonnen. Paperless-Dienste bleiben zur Sicherheit gestoppt."
            stop_services_best_effort
            log "Bitte Log und Backup prüfen; bei Bedarf kontrolliert wiederherstellen: $CURRENT_BACKUP"
        fi
    fi

    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" && "$TMP_DIR" == /tmp/paperless-update.* ]]; then
        rm -rf -- "$TMP_DIR"
    fi
    exit "$rc"
}
trap cleanup EXIT

version_compare() {
    # Rückgabe: 0 = gleich, 1 = links neuer, 2 = links älter, 3 = ungültig
    local -a left right
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 3
    IFS='.' read -r -a left <<< "$1"
    IFS='.' read -r -a right <<< "$2"
    local i l r
    for i in 0 1 2; do
        l=$((10#${left[i]}))
        r=$((10#${right[i]}))
        if (( l > r )); then return 1; fi
        if (( l < r )); then return 2; fi
    done
    return 0
}

get_version_from_file() {
    local file="$1"
    python3 - "$file" <<'PYVERSION'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
patterns = (
    r"__version__\s*:\s*Final\[tuple\[int,\s*int,\s*int\]\]\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)",
    r"__version__\s*=\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)",
)
for pattern in patterns:
    match = re.search(pattern, text)
    if match:
        print(".".join(match.groups()))
        raise SystemExit(0)
raise SystemExit(1)
PYVERSION
}

run_as_paperless() {
    # systemd-run verwendet denselben EnvironmentFile-Parser wie die
    # Paperless-Dienste. Die Konfigurationsdatei wird NICHT als Bash geladen.
    systemd-run --quiet --wait --pipe --collect \
        --uid="$PAPERLESS_USER" \
        --property="EnvironmentFile=$PAPERLESS_CONFIG_FILE" \
        --working-directory="$INSTALL_DIR/src" \
        -- "$@"
}

read_config_value() {
    local variable="$1"
    systemd-run --quiet --wait --pipe --collect \
        --uid="$PAPERLESS_USER" \
        --property="EnvironmentFile=$PAPERLESS_CONFIG_FILE" \
        --working-directory="$INSTALL_DIR" \
        -- /usr/bin/printenv "$variable"
}

[[ "$EUID" -eq 0 ]] || { echo "Bitte mit sudo bzw. als root starten." >&2; exit 1; }

for cmd in curl jq tar xz rsync sudo systemctl systemd-run python3 sha256sum pg_dump pg_dumpall pg_restore psql flock du df stat mktemp awk find sort dirname rm chmod chown; do
    command -v "$cmd" >/dev/null 2>&1 || fatal "Benötigtes Programm fehlt: $cmd"
done

# Parallele Update-Läufe verhindern.
exec 9>/run/lock/paperless-ngx-update.lock
flock -n 9 || fatal "Ein anderes Paperless-Update läuft bereits."

[[ -d "$INSTALL_DIR" ]] || fatal "Paperless-Verzeichnis fehlt: $INSTALL_DIR"
[[ -x "$VENV_DIR/bin/python" ]] || fatal "Python-Virtualenv fehlt: $VENV_DIR/bin/python"
[[ -f "$INSTALL_DIR/requirements.txt" ]] || fatal "requirements.txt fehlt."
[[ -f "$INSTALL_DIR/src/manage.py" ]] || fatal "manage.py fehlt."
[[ -f "$INSTALL_DIR/src/paperless/version.py" ]] || fatal "Paperless-Versiondatei fehlt."
[[ -f "$PAPERLESS_CONFIG_FILE" ]] || fatal "Konfigurationsdatei fehlt: $PAPERLESS_CONFIG_FILE"
[[ "$(stat -c '%U' "$PAPERLESS_CONFIG_FILE")" == "$PAPERLESS_USER" ]] ||
    fatal "paperless.conf gehört nicht dem Benutzer paperless. Bitte Dateirechte prüfen."

CONFIG_DB_NAME="$(read_config_value PAPERLESS_DBNAME)"
CONFIG_DB_PORT="$(read_config_value PAPERLESS_DBPORT)"
[[ "$CONFIG_DB_NAME" == "$DB_NAME" ]] ||
    fatal "DB_NAME im Skript stimmt nicht mit PAPERLESS_DBNAME überein."
[[ "$CONFIG_DB_PORT" == "$DB_PORT" ]] ||
    fatal "DB_PORT im Skript stimmt nicht mit PAPERLESS_DBPORT überein."

CURRENT_VERSION="$(get_version_from_file "$INSTALL_DIR/src/paperless/version.py")" ||
    fatal "Installierte Paperless-Version konnte nicht gelesen werden."
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fatal "Unbekanntes Versionsformat: $CURRENT_VERSION"

API_JSON="$(curl --fail --location --silent --show-error --retry 3 "$GITHUB_API")" ||
    fatal "GitHub-Release-API ist nicht erreichbar."
LATEST_VERSION="$(jq -er '.tag_name | sub("^v"; "")' <<< "$API_JSON")" ||
    fatal "GitHub-Version konnte nicht ermittelt werden."
[[ "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fatal "Unerwartetes GitHub-Versionsformat: $LATEST_VERSION"

sudo -u postgres psql -p "$DB_PORT" -d "$DB_NAME" -Atqc 'SELECT 1' >/dev/null ||
    fatal "PostgreSQL-Datenbank ist nicht erreichbar."

[[ ! -L "$BACKUP_DIR" ]] || fatal "Backup-Verzeichnis darf kein symbolischer Link sein."
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
[[ "$(stat -c '%U' "$BACKUP_DIR")" == root ]] ||
    fatal "Backup-Verzeichnis muss root gehören."

SOURCE_BYTES="$(du -sx --block-size=1 "$INSTALL_DIR" | awk '{print $1}')"
DB_BYTES="$(sudo -u postgres psql -p "$DB_PORT" -d "$DB_NAME" -Atqc "SELECT pg_database_size(current_database())")"
FREE_BYTES="$(df -PB1 "$BACKUP_DIR" | awk 'NR==2 {print $4}')"

[[ "$SOURCE_BYTES" =~ ^[0-9]+$ && "$DB_BYTES" =~ ^[0-9]+$ && "$FREE_BYTES" =~ ^[0-9]+$ ]] ||
    fatal "Speicherplatz konnte nicht ermittelt werden."

REQUIRED_BYTES=$((SOURCE_BYTES + DB_BYTES + 536870912))
if (( FREE_BYTES < REQUIRED_BYTES )); then
    fatal "Zu wenig Speicherplatz für das Backup."
fi

TMP_DIR="$(mktemp -d /tmp/paperless-update.XXXXXXXX)"
chmod 700 "$TMP_DIR"
touch "$LOGFILE"
chmod 600 "$LOGFILE"

printf '\n'
printf '%s\n' '========================================'
printf '%s\n' '       PAPERLESS-NGX UPDATE'
printf '%s\n' '========================================'
printf 'Installierte Version : %s\n' "$CURRENT_VERSION"
printf 'Verfügbare Version   : %s\n\n' "$LATEST_VERSION"
printf '%s\n' 'Bitte Aktion auswählen:'
printf '\n'
printf '%s\n' '  1) Normales Update'
printf '%s\n' '     Nur installieren, wenn GitHub neuer ist.'
printf '\n'
printf '%s\n' '  2) Reparatur'
printf '%s\n' '     Installierte Version erneut installieren.'
printf '\n'
printf '%s\n' '  3) Erzwungenes Update'
printf '%s\n' '     GitHub-Version installieren, sofern kein Downgrade.'
printf '\n'
printf '%s\n' '  4) Abbrechen'
printf '\n'

while true; do
    read -r -p 'Ihre Auswahl [1-4]: ' CHOICE || exit 0
    case "$CHOICE" in
        1|2|3|4) break ;;
        *) printf 'Ungültige Eingabe. Bitte 1, 2, 3 oder 4 eingeben.\n' ;;
    esac
done

case "$CHOICE" in
    1)
        if version_compare "$LATEST_VERSION" "$CURRENT_VERSION"; then
            cmp=0
        else
            cmp=$?
        fi
        [[ "$cmp" -ne 3 ]] || fatal "Versionsvergleich fehlgeschlagen."
        [[ "$cmp" -ne 2 ]] ||
            fatal "GitHub ist älter als installiert. Downgrade wird verhindert."
        if [[ "$cmp" -eq 0 ]]; then
            log "Kein Update verfügbar: Paperless ist bereits auf Version $CURRENT_VERSION. Für eine erneute Installation bitte Option 3 wählen."
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
        if version_compare "$LATEST_VERSION" "$CURRENT_VERSION"; then
            cmp=0
        else
            cmp=$?
        fi
        [[ "$cmp" -ne 3 ]] || fatal "Versionsvergleich fehlgeschlagen."
        [[ "$cmp" -ne 2 ]] ||
            fatal "GitHub ist älter als installiert. Downgrade wird verhindert."
        TARGET_VERSION="$LATEST_VERSION"
        ACTION_NAME="Erzwungenes Update"
        ;;
    4) exit 0 ;;
    *) exit 0 ;;
esac

log "Aktion: $ACTION_NAME | Installiert: $CURRENT_VERSION | Ziel: $TARGET_VERSION"

ARCHIVE="$TMP_DIR/paperless-ngx-v${TARGET_VERSION}.tar.xz"
DOWNLOAD_URL="https://github.com/paperless-ngx/paperless-ngx/releases/download/v${TARGET_VERSION}/paperless-ngx-v${TARGET_VERSION}.tar.xz"

log "Lade Release $TARGET_VERSION herunter."
curl --fail --location --silent --show-error --retry 3 "$DOWNLOAD_URL" -o "$ARCHIVE" ||
    fatal "Release-Download fehlgeschlagen."

[[ -s "$ARCHIVE" ]] || fatal "Heruntergeladenes Archiv ist leer."
xz -t "$ARCHIVE" || fatal "Archiv-Integritätstest fehlgeschlagen."
tar -tf "$ARCHIVE" > "$TMP_DIR/archive.list" ||
    fatal "Archiv kann nicht aufgelistet werden."

if awk 'BEGIN{bad=0} /^\// {bad=1} /(^|\/)\.\.(\/|$)/ {bad=1} END{exit bad?0:1}' "$TMP_DIR/archive.list"; then
    fatal "Archiv enthält unzulässige Pfade."
fi

mkdir "$TMP_DIR/extract"
tar --no-same-owner -xf "$ARCHIVE" -C "$TMP_DIR/extract"

mapfile -t TOP_DIRS < <(find "$TMP_DIR/extract" -mindepth 1 -maxdepth 1 -type d -print)
[[ "${#TOP_DIRS[@]}" -eq 1 ]] ||
    fatal "Release-Hauptverzeichnis nicht eindeutig."

NEW_SOURCE="${TOP_DIRS[0]}"
[[ -f "$NEW_SOURCE/src/paperless/version.py" && -f "$NEW_SOURCE/requirements.txt" ]] ||
    fatal "Release-Struktur ist ungültig."

ARCHIVE_VERSION="$(get_version_from_file "$NEW_SOURCE/src/paperless/version.py")" ||
    fatal "Archiv-Version konnte nicht ermittelt werden."

[[ "$ARCHIVE_VERSION" == "$TARGET_VERSION" ]] ||
    fatal "Archiv-Version stimmt nicht mit der Zielversion überein."

BACKUP_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
FINAL_BACKUP="$BACKUP_DIR/paperless-backup-$BACKUP_TIMESTAMP"
CURRENT_BACKUP="$BACKUP_DIR/.paperless-backup-$BACKUP_TIMESTAMP.incomplete"

[[ ! -e "$FINAL_BACKUP" && ! -e "$CURRENT_BACKUP" ]] ||
    fatal "Backup-Verzeichnis existiert bereits."

mkdir -m 700 "$CURRENT_BACKUP"

log "Stoppe Paperless-Dienste."
SERVICES_STOPPED=1
for service in "${SERVICES[@]}"; do
    systemctl stop "$service" ||
        fatal "Dienst $service konnte nicht gestoppt werden."
done

log "Erstelle vollständiges Dateibackup."
mkdir "$CURRENT_BACKUP/filesystem"
rsync -aHAX --numeric-ids "$INSTALL_DIR/" "$CURRENT_BACKUP/filesystem/" ||
    fatal "Dateibackup fehlgeschlagen."

log "Sichere PostgreSQL-Datenbank."
sudo -u postgres pg_dump -Fc -p "$DB_PORT" -d "$DB_NAME" > "$CURRENT_BACKUP/postgresql-$DB_NAME.dump" ||
    fatal "Datenbankdump fehlgeschlagen."

sudo -u postgres pg_dumpall --globals-only -p "$DB_PORT" > "$CURRENT_BACKUP/postgresql-globals.sql" ||
    fatal "Rollenbackup fehlgeschlagen."

[[ -s "$CURRENT_BACKUP/postgresql-$DB_NAME.dump" && -s "$CURRENT_BACKUP/postgresql-globals.sql" ]] ||
    fatal "Datenbankbackup ist unvollständig."

pg_restore --list "$CURRENT_BACKUP/postgresql-$DB_NAME.dump" >/dev/null ||
    fatal "Datenbankdump besteht die Strukturprüfung nicht."

RSYNC_CHECK="$(rsync -aHAXnci --numeric-ids --out-format='%i %n%L' "$INSTALL_DIR/" "$CURRENT_BACKUP/filesystem/" 2>&1)" ||
    fatal "Dateibackup konnte nicht verifiziert werden: $RSYNC_CHECK"

[[ -z "$RSYNC_CHECK" ]] ||
    fatal "Dateibackup weicht vom Original ab: $RSYNC_CHECK"

{
    echo "Paperless-ngx Backup"
    echo "Zeitpunkt: $(date --iso-8601=seconds)"
    echo "Installierte Version: $CURRENT_VERSION"
    echo "Zielversion: $TARGET_VERSION"
    echo "Aktion: $ACTION_NAME"
    echo "Datenbank: $DB_NAME"
    echo "PostgreSQL-Port: $DB_PORT"
    echo "Prüfsummen: SHA256SUMS"
    echo "Aufbewahrung: keine automatische Löschung vorhandener Backups."
    echo "Hinweis: Backup ist kein automatisch getesteter Restore."
} > "$CURRENT_BACKUP/README.txt"

sha256sum "$CURRENT_BACKUP/postgresql-$DB_NAME.dump" "$CURRENT_BACKUP/postgresql-globals.sql" \
    > "$CURRENT_BACKUP/SHA256SUMS"

sha256sum -c "$CURRENT_BACKUP/SHA256SUMS" >/dev/null ||
    fatal "Prüfsummenprüfung fehlgeschlagen."

chmod -R go-rwx "$CURRENT_BACKUP"

mv -- "$CURRENT_BACKUP" "$FINAL_BACKUP" ||
    fatal "Geprüftes Backup konnte nicht veröffentlicht werden."

CURRENT_BACKUP="$FINAL_BACKUP"
log "Backup erstellt und geprüft: $CURRENT_BACKUP"
log "Vorhandene Backups werden nicht automatisch gelöscht."

UPDATE_STARTED=1

log "Entferne alte Release-Dateien."
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

log "Kopiere Release-Dateien."
rsync -a --chown="$PAPERLESS_USER:$PAPERLESS_USER" \
    --exclude='/data' --exclude='/media' --exclude='/consume' --exclude='/export' \
    --exclude='/venv' --exclude='/.env' --exclude='/paperless.conf' --exclude='/log' \
    "$NEW_SOURCE/" "$INSTALL_DIR/" ||
    fatal "Kopieren der Release-Dateien fehlgeschlagen."

[[ -f "$PAPERLESS_CONFIG_FILE" && -x "$VENV_DIR/bin/python" ]] ||
    fatal "Konfiguration oder Virtualenv fehlt."

chown "$PAPERLESS_USER:$PAPERLESS_USER" "$PAPERLESS_CONFIG_FILE"
chmod 600 "$PAPERLESS_CONFIG_FILE"

if [[ -f "$INSTALL_DIR/.env" ]]; then
    chown "$PAPERLESS_USER:$PAPERLESS_USER" "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
fi

log "Stelle pip im virtuellen Environment sicher."
run_as_paperless "$VENV_DIR/bin/python" -m ensurepip --upgrade 2>&1 | tee -a "$LOGFILE" ||
    fatal "pip konnte mit ensurepip nicht eingerichtet werden. Backup: $CURRENT_BACKUP"

log "Aktualisiere pip, setuptools und wheel."
run_as_paperless "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel 2>&1 | tee -a "$LOGFILE" ||
    fatal "pip/setuptools/wheel konnten nicht aktualisiert werden. Backup: $CURRENT_BACKUP"

log "Installiere Paperless-Python-Abhängigkeiten."
run_as_paperless "$VENV_DIR/bin/python" -m pip install --upgrade -r "$INSTALL_DIR/requirements.txt" 2>&1 | tee -a "$LOGFILE" ||
    fatal "Python-Abhängigkeiten konnten nicht installiert werden. Backup: $CURRENT_BACKUP"

log "Führe Datenbankmigrationen aus."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" migrate --noinput ||
    fatal "Datenbankmigration fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Erzeuge statische Dateien."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" collectstatic --noinput ||
    fatal "collectstatic fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Aktualisiere Suchindex."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" document_index reindex --if-needed ||
    fatal "Suchindex-Aktualisierung fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Migriere LLM-Index."
run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" document_llmindex migrate ||
    fatal "LLM-Index-Migration fehlgeschlagen. Backup: $CURRENT_BACKUP"

log "Aktualisiere den Paperless-Klassifikator."
if ! run_as_paperless "$VENV_DIR/bin/python" "$INSTALL_DIR/src/manage.py" document_create_classifier >> "$LOGFILE" 2>&1; then
    log "WARNUNG: Klassifikator konnte nicht aktualisiert werden."
fi

NEW_VERSION="$(get_version_from_file "$INSTALL_DIR/src/paperless/version.py")" ||
    fatal "Neue Version konnte nicht gelesen werden."

[[ "$NEW_VERSION" == "$TARGET_VERSION" ]] ||
    fatal "Versionsprüfung fehlgeschlagen. Erwartet: $TARGET_VERSION, installiert: $NEW_VERSION."

log "Starte Paperless-Dienste."
start_services ||
    fatal "Mindestens ein Paperless-Dienst konnte nicht gestartet werden. Backup: $CURRENT_BACKUP"

FAILED_SERVICES=()
for service in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$service" || FAILED_SERVICES+=("$service")
done

if [[ "${#FAILED_SERVICES[@]}" -gt 0 ]]; then
    fatal "Folgende Dienste laufen nicht: ${FAILED_SERVICES[*]}. Backup: $CURRENT_BACKUP"
fi

SERVICES_STOPPED=0

log "ERFOLG: $ACTION_NAME abgeschlossen. Version: $CURRENT_VERSION -> $NEW_VERSION"
log "Backup aufbewahrt unter: $CURRENT_BACKUP"

printf '\n'
printf '%s\n' '========================================'
printf '%s\n' '          UPDATE ERFOLGREICH'
printf '%s\n' '========================================'
printf 'Aktion       : %s\n' "$ACTION_NAME"
printf 'Alte Version : %s\n' "$CURRENT_VERSION"
printf 'Neue Version : %s\n' "$NEW_VERSION"
printf '%s\n' 'Alle vier Paperless-Dienste laufen.'
printf 'Backup       : %s\n' "$CURRENT_BACKUP"
printf '%s\n' 'Vorhandene Backups wurden nicht gelöscht.'
printf '\n'

exit 0