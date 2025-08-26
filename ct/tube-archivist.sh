#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/p-h-0-x/ProxmoxVE/refs/heads/feat-tube-archivist/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Author: benjaminmerieau
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/tubearchivist/tubearchivist

APP="tube-archivist"
var_tags="${var_tags:-media}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  
  if [[ ! -f /opt/tubearchivist/manage.py ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  
  msg_info "Updating ${APP}"
  cd /opt/tubearchivist || exit
  
  # Stop services
  systemctl stop tubearchivist celery-tubearchivist nginx
  
  # Update yt-dlp
  /opt/tubearchivist/venv/bin/pip install --upgrade yt-dlp
  
  # Pull latest code
  git fetch --all
  git reset --hard origin/master
  
  # Update Python dependencies
  /opt/tubearchivist/venv/bin/pip install -r requirements.txt
  
  # Run migrations and collect static files
  /opt/tubearchivist/venv/bin/python manage.py migrate
  /opt/tubearchivist/venv/bin/python manage.py collectstatic --noinput
  
  # Restart services
  systemctl start elasticsearch redis-server nginx celery-tubearchivist tubearchivist
  
  msg_ok "Updated ${APP}"
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following IP:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW} Default credentials:${CL}"
echo -e "${TAB}${RD}Username${CL}: tubearchivist"
echo -e "${TAB}${RD}Password${CL}: verysecret"
