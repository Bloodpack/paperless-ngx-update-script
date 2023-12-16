#!/bin/bash

# bash script to update Paperless-NGX bare metal installation on Ubuntu Server.
# Copyright (c) 2023 Bloodpack
# Author: Bloodpack 
# License: GPL-3.0 license
# Follow or contribute on GitHub here:
# https://github.com/Bloodpack/paperless-ngx-update-script




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
var_disk="80"
var_cpu="4"
var_ram="8096"
var_os="dubuntu"
var_version="22.04"




function update_script() {
  if [[ ! -d /opt/paperless-ngx ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  RELEASE=$(curl -s https://api.github.com/repos/paperless-ngx/paperless-ngx/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
  SER=/etc/systemd/system/paperless-task-queue.service

  UPD=$(whiptail --backtitle "Paperless-NGX Update Script" --title "SUPPORT" --radiolist --cancel-button Exit-Script "Spacebar = Select" 11 58 2 \
    "1" "Update Paperless-ngx to $RELEASE" ON \
    "2" "Paperless-ngx Credentials" OFF \
    3>&1 1>&2 2>&3)
  header_info

  if [ "$UPD" == "1" ]; then
    msg_info "Stopping Paperless-ngx"
    systemctl stop paperless-consumer paperless-webserver paperless-scheduler
    if [ -f "$SER" ]; then
      systemctl stop paperless-task-queue.service
    fi
    sleep 1
    msg_ok "Stopped Paperless-ngx"

    msg_info "Updating to ${RELEASE}"
    cd /opt/
    wget https://github.com/paperless-ngx/paperless-ngx/releases/download/$RELEASE/paperless-ngx-$RELEASE.tar.xz &>/dev/null
    tar -xfv paperless-ngx-$RELEASE.tar.xz &>/dev/null
    rm -R paperless-ngx-$RELEASE.tar.xz &>/dev/null
    cd /opt/paperless-ngx
    chown -R paperless:root /opt/paperless-ngx
    cp paperless.conf.horst paperless.conf
    cd /opt/paperless-ngx/scripts/
    cp paperless-consumer.service.horst paperless-consumer.service
    cp paperless-scheduler.service.horst paperless-scheduler.service
    cp paperless-task-queue.service.horst paperless-task-queue.service
    cp paperless-webserver.service.horst paperless-webserver.service
    cd /opt/paperless-ngx
    sudo -Hu paperless pip3 install --upgrade pip
    pip install -r requirements.txt &>/dev/null
    cd /opt/paperless-ngx/src
    sudo -Hu paperless python3 manage.py migrate &>/dev/null
    if [ -f "$SER" ]; then
      msg_ok "paperless-task-queue.service Exists."
    else
      cat <<EOF >/etc/systemd/system/paperless-task-queue.service

EOF
    msg_ok "Updated to ${RELEASE}"


    msg_info "Starting Paperless-ngx"
    systemctl daemon-reload
    systemctl start paperless-consumer paperless-webserver paperless-scheduler paperless-task-queue.service
    sleep 1
    msg_ok "Started Paperless-ngx"
    msg_ok "Updated Successfully!\n"
    exit
  fi
  if [ "$UPD" == "2" ]; then
    cat paperless.creds
    exit
  fi


#start
#build_container
#description

#msg_ok "Completed Successfully!\n"
#echo -e "${APP} should be reachable by going to the following URL.
#         ${BL}http://${IP}:8000${CL} \n"