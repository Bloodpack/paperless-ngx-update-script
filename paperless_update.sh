#!/bin/bash

###############################################################################
# Paperless-ngx Update Script
#
# Bare Metal Installation
#
# Ubuntu 24.04 LTS
#
# Installation:
#   /opt/paperless
#
# User:
#   paperless
#
###############################################################################

set -Eeuo pipefail


############################
# Konfiguration
############################

PAPERLESS_USER="paperless"

INSTALL_DIR="/opt/paperless"

VENV_DIR="/opt/paperless/venv"

BACKUP_DIR="/opt/paperless-backup"

TMP_DIR="/tmp/paperless-update"

LOGFILE="/var/log/paperless-update.log"

CLASSIFIER_LOG="/var/log/paperless_classifier.log"

SANITY_CHECKER_LOG="/var/log/paperless_sanity_checker.log"

REQUIREMENTS_FILE="$INSTALL_DIR/requirements.txt"

MANAGE_PY="$INSTALL_DIR/src/manage.py"

PAPERLESS_CONFIG_FILE="$INSTALL_DIR/paperless.conf"


SERVICES=(
paperless-webserver
paperless-consumer
paperless-task-queue
paperless-scheduler
)


GITHUB_API="https://api.github.com/repos/paperless-ngx/paperless-ngx/releases/latest"


############################
# Farben
############################

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[36m"
RESET="\e[0m"


############################
# Funktionen
############################


log()
{
    printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOGFILE"
}

log_to_file()
{
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOGFILE"
}

load_paperless_config()
{
    if [[ -f "$PAPERLESS_CONFIG_FILE" ]]; then
        # Nur relevante Variablen aus paperless.conf lesen
        if grep -Eq '^[[:space:]]*PAPERLESS_SECRET_KEY=' "$PAPERLESS_CONFIG_FILE"; then
            export PAPERLESS_SECRET_KEY="$(grep -E '^[[:space:]]*PAPERLESS_SECRET_KEY=' "$PAPERLESS_CONFIG_FILE" | head -n1 | sed -E 's/^[[:space:]]*PAPERLESS_SECRET_KEY=[[:space:]]*//')"
        fi

        if grep -Eq '^[[:space:]]*PAPERLESS_TIME_ZONE=' "$PAPERLESS_CONFIG_FILE"; then
            export PAPERLESS_TIME_ZONE="$(grep -E '^[[:space:]]*PAPERLESS_TIME_ZONE=' "$PAPERLESS_CONFIG_FILE" | head -n1 | sed -E 's/^[[:space:]]*PAPERLESS_TIME_ZONE=[[:space:]]*//')"
        fi
    else
        error "Paperless-Konfigurationsdatei fehlt: $PAPERLESS_CONFIG_FILE"
    fi
}


validate_paperless_config()
{
    if ! grep -Eq '^[[:space:]]*PAPERLESS_SECRET_KEY=' "$PAPERLESS_CONFIG_FILE"; then
        error "PAPERLESS_SECRET_KEY fehlt in $PAPERLESS_CONFIG_FILE"
    fi
}


run_as_paperless()
{
    sudo -u "$PAPERLESS_USER" bash -lc '
        set -a
        if [ -f "$1" ]; then
            while IFS= read -r line; do
                case "$line" in
                    PAPERLESS_SECRET_KEY=*|PAPERLESS_TIME_ZONE=*)
                        export "$line"
                        ;;
                esac
            done < "$1"
        fi
        set +a
        shift
        exec "$@"
    ' _ "$PAPERLESS_CONFIG_FILE" "$@"
}


start_live_log()
{
    touch "$LOGFILE"

    clear
    echo "=== Live Log ==="

    tail -f "$LOGFILE" &
    LOGVIEW_PID=$!
}


stop_live_log()
{
    if [[ -n "${LOGVIEW_PID:-}" ]]; then
        kill "$LOGVIEW_PID" 2>/dev/null || true
        wait "$LOGVIEW_PID" 2>/dev/null || true
    fi
}


error()
{
    if command -v dialog >/dev/null 2>&1; then
        dialog \
        --title "Fehler" \
        --msgbox "$1" \
        10 60
    else
        echo "FEHLER: $1" >&2
    fi

    log "FEHLER: $1"

    exit 1
}



cleanup()
{
    rm -rf "$TMP_DIR"
}


remove_old_release_files()
{
    if [[ ! -d "$INSTALL_DIR" ]]; then
        error "Paperless Verzeichnis fehlt: $INSTALL_DIR"
    fi

    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 \
        ! -name '.env' \
        ! -name 'paperless.conf' \
        ! -name 'data' \
        ! -name 'media' \
        ! -name 'consume' \
        ! -name 'venv' \
        -exec rm -rf -- {} +
}


trap cleanup EXIT



############################
# Root Prüfung
############################


if [[ "$EUID" -ne 0 ]]; then

    echo "Bitte als root ausführen."

    exit 1

fi



############################
# Programme prüfen
############################


REQUIRED=(
curl
jq
wget
tar
rsync

)


for CMD in "${REQUIRED[@]}"
do

    if ! command -v "$CMD" >/dev/null 2>&1
    then

        echo "Fehlt: $CMD"

        echo "Installieren mit:"
        echo

        echo "apt install $CMD"

        exit 1

    fi

done



############################
# Verzeichnisse prüfen
############################


[[ -d "$INSTALL_DIR" ]] \
|| error "Paperless Verzeichnis fehlt: $INSTALL_DIR"



[[ -d "$VENV_DIR" ]] \
|| error "Python Virtual Environment fehlt: $VENV_DIR"

[[ -x "$VENV_DIR/bin/python" ]] \
|| error "Python-Binary fehlt: $VENV_DIR/bin/python"

[[ -f "$REQUIREMENTS_FILE" ]] \
|| error "requirements.txt fehlt: $REQUIREMENTS_FILE"

[[ -f "$MANAGE_PY" ]] \
|| error "manage.py fehlt: $MANAGE_PY"


mkdir -p "$TMP_DIR"



log "Paperless Update gestartet"



echo

echo "Vorbereitung abgeschlossen"
###############################################################################
# Teil 2
# Versionsprüfung
###############################################################################


get_version_from_file()
{
    run_as_paperless \
    "$VENV_DIR/bin/python" \
    -c "from pathlib import Path; import re; p = Path('/opt/paperless/src/paperless/version.py'); text = p.read_text(); m = re.search(r'__version__\s*[:=]\s*Final\[tuple\[int, int, int\]\]\s*=\s*\((\d+)\s*,\s*(\d+)\s*,\s*(\d+)\)', text); print(f'{m.group(1)}.{m.group(2)}.{m.group(3)}') if m else ''" 2>/dev/null \
    | tr -d '\r'
}

get_local_version()
{
    get_version_from_file
}



get_github_version()
{

    curl -s "$GITHUB_API" \
    | jq -r '.tag_name' \
    | sed 's/^v//'

}



###############################################################################
# Versionen auslesen
###############################################################################


load_paperless_config
validate_paperless_config

CURRENT_VERSION=$(get_local_version)


if [[ -z "$CURRENT_VERSION" ]]; then

    error "Lokale Paperless-Version konnte nicht ermittelt werden."

fi



LATEST_VERSION=$(get_github_version)



if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then

    error "GitHub-Version konnte nicht ermittelt werden."

fi



log_to_file "Installierte Version: $CURRENT_VERSION"

log_to_file "GitHub Version: $LATEST_VERSION"


###############################################################################
# Versionsvergleich
###############################################################################


REPAIR_MODE=0


if ! command -v dialog >/dev/null 2>&1; then
    error "dialog ist nicht installiert. Bitte 'apt install dialog' ausführen."
fi

SELECTED_ACTION=$(dialog \
    --clear \
    --title "Paperless-ngx Update" \
    --menu "Bitte wählen:\n\nInstalliert: $CURRENT_VERSION\nGitHub: $LATEST_VERSION" \
    16 70 3 \
    1 "Update" \
    2 "Reparatur" \
    3 "Abbruch" \
    --stdout)

case "$SELECTED_ACTION" in
    1)
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
            REPAIR_MODE=1
            log_to_file "Keine neue Version verfügbar, Reparaturlauf wird verwendet"
        else
            REPAIR_MODE=0
            log_to_file "Benutzer hat Update gewählt"
        fi
        ;;
    2)
        REPAIR_MODE=1
        log_to_file "Benutzer hat Reparatur gewählt"
        ;;
    3)
        log_to_file "Benutzer hat Abbruch gewählt"
        exit 0
        ;;
    *)
        log_to_file "Dialog abgebrochen"
        exit 0
        ;;
esac

# Live Log Fenster starten
start_live_log
sleep 1

if [[ "$REPAIR_MODE" -eq 1 ]]; then
    log "Reparaturlauf gestartet"
else
    log "Update wird vorbereitet..."
fi

log "Von: $CURRENT_VERSION"
log "Auf: $LATEST_VERSION"

sleep 2
###############################################################################
# Teil 3
# Backup und Programmdateien aktualisieren
###############################################################################


(
echo 5
echo "# Stoppe Paperless-Dienste..."
log "Stoppe Paperless-Dienste"

for SERVICE in "${SERVICES[@]}"
do
    log "Stoppe Dienst: $SERVICE"
    systemctl stop "$SERVICE"
done


sleep 2


###############################################################################
# Backup erstellen
###############################################################################

echo 15
echo "# Erstelle Backup..."


BACKUP_TIMESTAMP=$(date '+%Y%m%d-%H%M%S')

CURRENT_BACKUP="${BACKUP_DIR}-${BACKUP_TIMESTAMP}"


mkdir -p "$CURRENT_BACKUP"



# Konfiguration sichern

cp \
"$INSTALL_DIR/.env" \
"$CURRENT_BACKUP/" 2>/dev/null || true



cp \
"$INSTALL_DIR/paperless.conf" \
"$CURRENT_BACKUP/" 2>/dev/null || true



# Datenbank sichern

if [[ -f "$INSTALL_DIR/data/db.sqlite3" ]]
then

    cp \
    "$INSTALL_DIR/data/db.sqlite3" \
    "$CURRENT_BACKUP/"

fi



# wichtige Datenverzeichnisse

rsync -a \
"$INSTALL_DIR/data/" \
"$CURRENT_BACKUP/data/"


rsync -a \
"$INSTALL_DIR/media/" \
"$CURRENT_BACKUP/media/"



log "Backup erstellt: $CURRENT_BACKUP"



###############################################################################
# Release herunterladen
###############################################################################


echo 35
echo "# Lade Paperless Release herunter..."



DOWNLOAD_URL="https://github.com/paperless-ngx/paperless-ngx/releases/download/v${LATEST_VERSION}/paperless-ngx-v${LATEST_VERSION}.tar.xz"



wget \
-q \
-O "$TMP_DIR/paperless.tar.xz" \
"$DOWNLOAD_URL"



if [[ ! -s "$TMP_DIR/paperless.tar.xz" ]]
then

    echo 100

    error "Download fehlgeschlagen."

fi



###############################################################################
# Entpacken
###############################################################################


echo 50
echo "# Entferne alte Release-Dateien..."

remove_old_release_files


echo 55
echo "# Entpacke Archiv..."



mkdir -p "$TMP_DIR/extract"



tar xf \
"$TMP_DIR/paperless.tar.xz" \
-C "$TMP_DIR/extract"



NEW_SOURCE=$(find \
"$TMP_DIR/extract" \
-mindepth 1 \
-maxdepth 1 \
-type d \
| head -n1)



if [[ -z "$NEW_SOURCE" ]]
then

    error "Entpacktes Release nicht gefunden."

fi



###############################################################################
# Dateien aktualisieren
###############################################################################


echo 70
echo "# Aktualisiere Paperless Dateien..."



rsync -a \
--exclude=data \
--exclude=media \
--exclude=consume \
--exclude=export \
--exclude=venv \
--exclude=.env \
--exclude=paperless.conf \
"$NEW_SOURCE/" \
"$INSTALL_DIR/"



###############################################################################
# Besitzer korrigieren
###############################################################################


echo 90
echo "# Setze Dateirechte..."



chown -R \
"$PAPERLESS_USER:$PAPERLESS_USER" \
"$INSTALL_DIR"



echo 100
echo "# Dateien aktualisiert"



)


log "Programmdateien aktualisiert"
###############################################################################
# Teil 4
# Python Umgebung aktualisieren
# Migrationen
# Dienste starten
###############################################################################


(
echo 5
echo "# Aktualisiere Python-Abhängigkeiten..."



sudo -u "$PAPERLESS_USER" \
"$VENV_DIR/bin/python" -m pip install \
--upgrade pip setuptools wheel



sudo -u "$PAPERLESS_USER" \
"$VENV_DIR/bin/python" -m pip install \
-r "$INSTALL_DIR/requirements.txt"



if [[ $? -ne 0 ]]
then

    echo 100

    error "Python-Abhängigkeiten konnten nicht aktualisiert werden."

fi



###############################################################################
# Datenbank Migrationen
###############################################################################


echo 30
echo "# Führe Datenbankmigrationen aus..."



run_as_paperless \
"$VENV_DIR/bin/python" \
"$INSTALL_DIR/src/manage.py" \
migrate \
--noinput



if [[ $? -ne 0 ]]
then

    echo 100

    error "Datenbankmigration fehlgeschlagen."

fi



###############################################################################
# Static Dateien
###############################################################################


echo 55
echo "# Erzeuge statische Dateien..."



run_as_paperless \
"$VENV_DIR/bin/python" \
"$INSTALL_DIR/src/manage.py" \
collectstatic \
--noinput



if [[ $? -ne 0 ]]
then

    echo 100

    error "Collectstatic fehlgeschlagen."

fi



###############################################################################
# Dokumentenindex aktualisieren
###############################################################################


echo 75
echo "# Aktualisiere Suchindex und führe Checks aus..."


touch "$CLASSIFIER_LOG" "$SANITY_CHECKER_LOG"

if ! run_as_paperless \
"$VENV_DIR/bin/python" \
"$INSTALL_DIR/src/manage.py" \
document_create_classifier >>"$CLASSIFIER_LOG" 2>&1
then
    log "document_create_classifier fehlgeschlagen - siehe $CLASSIFIER_LOG"
fi

if ! run_as_paperless \
"$VENV_DIR/bin/python" \
"$INSTALL_DIR/src/manage.py" \
document_sanity_checker >>"$SANITY_CHECKER_LOG" 2>&1
then
    log "document_sanity_checker fehlgeschlagen - siehe $SANITY_CHECKER_LOG"
fi

run_as_paperless \
"$VENV_DIR/bin/python" \
"$INSTALL_DIR/src/manage.py" \
document_index \
reindex \
|| true



###############################################################################
# Dienste starten
###############################################################################


echo 90
echo "# Starte Paperless-Dienste..."



for SERVICE in "${SERVICES[@]}"
do

    systemctl start "$SERVICE"

done



echo 100
echo "# Update abgeschlossen"



)


log "Migrationen und Neustart abgeschlossen"
###############################################################################
# Teil 5
# Abschlussprüfung
###############################################################################


###############################################################################
# Dienste prüfen
###############################################################################

FAILED_SERVICES=()


for SERVICE in "${SERVICES[@]}"
do

    if systemctl is-active --quiet "$SERVICE"
    then

        log "Dienst läuft: $SERVICE"

    else

        FAILED_SERVICES+=("$SERVICE")

        log "Dienst FEHLER: $SERVICE"

    fi

done



###############################################################################
# Ergebnis anzeigen
###############################################################################


if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]
then


FAILED_LIST=$(printf "%s\n" "${FAILED_SERVICES[@]}")

echo
echo "Update abgeschlossen mit Fehlern."
echo "Folgende Dienste laufen nicht:"
printf '%s\n' "${FAILED_SERVICES[@]}"
echo
log "Update abgeschlossen mit Fehlern"



else


NEW_VERSION=$(get_version_from_file)

if [[ -z "$NEW_VERSION" ]]; then
    NEW_VERSION="$CURRENT_VERSION"
fi

echo
echo "Update erfolgreich abgeschlossen!"
echo "Alte Version: $CURRENT_VERSION"
echo "Neue Version: $NEW_VERSION"
echo "Alle Paperless-Dienste laufen."
echo

log "Update erfolgreich"
log "Version alt: $CURRENT_VERSION"
log "Version neu: $NEW_VERSION"



fi



###############################################################################
# Aufräumen
###############################################################################


rm -rf "$TMP_DIR"

if [[ -f "$TMP_DIR/paperless.tar.xz" ]]; then
    rm -f "$TMP_DIR/paperless.tar.xz"
fi

if [[ -d "$TMP_DIR/extract" ]]; then
    rm -rf "$TMP_DIR/extract"
fi

log "Temporäre Dateien entfernt"

if [[ -d "$BACKUP_DIR" ]]; then
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print -exec rm -rf {} + 2>/dev/null || true
    log "Backup-Verzeichnisse entfernt"
fi

if [[ -d "/opt" ]]; then
    find /opt -maxdepth 1 -mindepth 1 -type d -name 'paperless-backup-*' -print -exec rm -rf {} + 2>/dev/null || true
    log "Paperless-Backups im /opt-Ordner entfernt"
fi

log "=========================================="


# Live Log Fenster schließen
stop_live_log


exit 0