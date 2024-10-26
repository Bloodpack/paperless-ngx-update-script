#!/bin/bash

# bash script to update Paperless-NGX bare metal installation on Ubuntu Server.
# Copyright (c) 2023 Bloodpack
# Author: Bloodpack 
# License: GPL-3.0 license
# Follow or contribute on GitHub here:
# https://github.com/Bloodpack/paperless-ngx-update-script
################################
# VERSION: 1.2 from 26.10.2024 #
################################

source <(curl -s https://raw.githubusercontent.com/Bloodpack/paperless-ngx-update-script/main/build.func)

function header_info {
  clear
  cat <<"EOF"
    ____                        __                                     
   / __ \____ _____  ___  _____/ /__  __________    ____  ____ __  __
  / /_/ / __ `/ __ \/ _ \/ ___/ / _ \/ ___/ ___/___/ __ \/ __ `/ |/_/
 / ____/ /_/ / /_/ /  __/ /  / /  __(__  |__  )___/ / / / /_/ />  <  
/_/    \__,_/ .___/\___/_/  /_/\___/____/____/   /_/ /_/\__, /_/|_|  
           /_/                                         /____/        
EOF
}

header_info
echo -e "Loading..."
APP="Paperless-ngx"
RELEASE=$(curl -s https://api.github.com/repos/paperless-ngx/paperless-ngx/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
SER=/etc/systemd/system/paperless-task-queue.service

function msg_info {
  echo -e "\e[32m[INFO] $1\e[0m" # Green text for info messages
}

function update_script {
  if [[ ! -d /opt/paperless-ngx ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi
}

update_script

UPD=$(whiptail --backtitle "Paperless-NGX Update Script" --title "SUPPORT" --radiolist --cancel-button Exit-Script "Spacebar = Select" 11 58 2 \
  "1" "Update Paperless-ngx to $RELEASE" ON \
  "2" "Paperless-ngx Credentials" OFF \
  3>&1 1>&2 2>&3)

header_info

if [ "$UPD" == "1" ]; then
  echo
  msg_info "Stopping Paperless-ngx services..."
  systemctl stop paperless-consumer paperless-webserver paperless-scheduler

  if [ -f "$SER" ]; then
    systemctl stop paperless-task-queue.service
  fi

  sleep 1
  echo
  msg_info "Successfully stopped Paperless-ngx services."

  echo
  msg_info "Updating to version ${RELEASE}..."
  cd /opt/ || exit

  echo
  msg_info "Downloading Paperless-ngx version ${RELEASE}..."
  wget "https://github.com/paperless-ngx/paperless-ngx/releases/download/$RELEASE/paperless-ngx-$RELEASE.tar.xz"

  echo
  msg_info "Unpacking Paperless-ngx version ${RELEASE}..."
  tar -xf "paperless-ngx-$RELEASE.tar.xz"
  rm -f "paperless-ngx-$RELEASE.tar.xz"

  echo
  msg_info "Patching Paperless-ngx configuration..."
  cd /opt/paperless-ngx || exit
  chown -R paperless:root /opt/paperless-ngx
  cp paperless.conf.horst paperless.conf

  echo
  msg_info "Patching Paperless-ngx scripts..."
  cp scripts/paperless-consumer.service.horst scripts/paperless-consumer.service
  cp scripts/paperless-scheduler.service.horst scripts/paperless-scheduler.service
  cp scripts/paperless-task-queue.service.horst scripts/paperless-task-queue.service
  cp scripts/paperless-webserver.service.horst scripts/paperless-webserver.service

  echo
  msg_info "Upgrading PIP..."
  sudo -Hu paperless pip3 install --upgrade pip --break-system-packages

  echo
  msg_info "Installing requirements..."
  sudo -Hu paperless pip3 install -r requirements.txt --break-system-packages

  echo
  msg_info "Migrating to new version..."
  cd src || exit
  sudo -Hu paperless python3 manage.py migrate 

  echo
  msg_ok "Updated to version ${RELEASE} successfully."

  echo
  msg_info "Starting Paperless-ngx services..."
  systemctl daemon-reload
  systemctl start paperless-consumer paperless-webserver paperless-scheduler paperless-task-queue.service
  sleep 1
  echo
  msg_ok "Successfully started Paperless-ngx services."
  echo
  msg_ok "Update completed successfully!\n"
  exit 0
fi
