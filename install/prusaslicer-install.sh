#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://www.prusa3d.com/page/prusaslicer_424/

# Source the functions from the web
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/core.func)

# Define color codes
RD='\033[01;31m'
YW='\033[33m'
GN='\033[1;92m'
BL='\033[36m'
CL='\033[m'
BFR="\\r\\033[K"
TAB="  "
CM="${TAB}✔️${TAB}${CL}"

# Define message functions
msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Suppress output
STD=""

# Update the system
msg_info "Updating system packages"
apt-get update >/dev/null 2>&1
apt-get upgrade -y >/dev/null 2>&1
msg_ok "Updated system packages"

msg_info "Installing Desktop Environment and Dependencies"
apt-get install -y --no-install-recommends \
    lxde-core \
    lxterminal \
    xorg \
    dbus-x11 \
    xserver-xorg-video-all \
    xfonts-base \
    mesa-utils \
    firefox-esr \
    file-manager-nautilus \
    gvfs-backends >/dev/null 2>&1
msg_ok "Installed Desktop Environment"

msg_info "Installing VNC Server"
apt-get install -y tigervnc-standalone-server tigervnc-viewer >/dev/null 2>&1
msg_ok "Installed VNC Server"

msg_info "Installing noVNC"
cd /opt || exit
git clone https://github.com/novnc/noVNC.git >/dev/null 2>&1
cd noVNC || exit
git clone https://github.com/novnc/websockify.git utils/websockify >/dev/null 2>&1
msg_ok "Installed noVNC"

msg_info "Installing Python dependencies for noVNC"
apt-get install -y python3 python3-pip python3-numpy >/dev/null 2>&1
pip3 install websockify >/dev/null 2>&1
msg_ok "Installed Python dependencies"

msg_info "Installing Flatpak"
apt-get install -y flatpak >/dev/null 2>&1
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1
msg_ok "Installed Flatpak"

msg_info "Creating prusaslicer user"
useradd -m -s /bin/bash prusaslicer
echo "prusaslicer:prusaslicer" | chpasswd
usermod -aG sudo prusaslicer
msg_ok "Created prusaslicer user"

msg_info "Installing PrusaSlicer via Flatpak"
runuser -l prusaslicer -c 'flatpak install --user -y flathub com.prusa3d.PrusaSlicer' >/dev/null 2>&1
msg_ok "Installed PrusaSlicer"

msg_info "Configuring VNC for prusaslicer user"
# Create VNC password for prusaslicer user
mkdir -p /home/prusaslicer/.vnc
echo "prusaslicer" | runuser -l prusaslicer -c 'vncpasswd -f' > /home/prusaslicer/.vnc/passwd
chmod 600 /home/prusaslicer/.vnc/passwd
chown prusaslicer:prusaslicer /home/prusaslicer/.vnc/passwd

# Create VNC startup script
cat <<'EOF' > /home/prusaslicer/.vnc/xstartup
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
export XDG_CURRENT_DESKTOP="LXDE"
export XDG_MENU_PREFIX="lxde-"
export XDG_CONFIG_DIRS=/etc/xdg

dbus-launch --exit-with-session startlxde &
EOF

chmod +x /home/prusaslicer/.vnc/xstartup
chown prusaslicer:prusaslicer /home/prusaslicer/.vnc/xstartup
msg_ok "Configured VNC for prusaslicer user"

msg_info "Creating systemd service for VNC"
cat <<'EOF' > /etc/systemd/system/vnc@.service
[Unit]
Description=Remote desktop service (VNC) for %i
After=network.target

[Service]
Type=forking
User=%i
Group=%i
WorkingDirectory=/home/%i

PIDFile=/home/%i/.vnc/%H:1.pid
ExecStartPre=-/usr/bin/vncserver -kill :1 > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1920x1080 -localhost no :1
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Created VNC systemd service"

msg_info "Creating systemd service for noVNC"
cat <<'EOF' > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC WebSocket proxy
After=network.target vnc@prusaslicer.service
Requires=vnc@prusaslicer.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/noVNC
ExecStart=/usr/bin/python3 /opt/noVNC/utils/websockify/websockify.py --web /opt/noVNC --target-config=/opt/noVNC/targets.conf 6080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
msg_ok "Created noVNC systemd service"

msg_info "Configuring noVNC targets"
cat <<'EOF' > /opt/noVNC/targets.conf
prusaslicer: localhost:5901
EOF
msg_ok "Configured noVNC targets"

msg_info "Creating PrusaSlicer desktop launcher"
mkdir -p /home/prusaslicer/Desktop
cat <<'EOF' > /home/prusaslicer/Desktop/PrusaSlicer.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=PrusaSlicer
Comment=3D Printing Slicer
Exec=flatpak run com.prusa3d.PrusaSlicer
Icon=com.prusa3d.PrusaSlicer
Terminal=false
Categories=Graphics;3DGraphics;Engineering;
MimeType=model/stl;application/vnd.ms-3mfdocument;
EOF

chmod +x /home/prusaslicer/Desktop/PrusaSlicer.desktop
chown prusaslicer:prusaslicer /home/prusaslicer/Desktop/PrusaSlicer.desktop

# Create symbolic link in home directory for easy access
ln -sf /home/prusaslicer/Desktop/PrusaSlicer.desktop /home/prusaslicer/
msg_ok "Created PrusaSlicer desktop launcher"

msg_info "Creating application startup script"
cat <<'EOF' > /home/prusaslicer/.vnc/start-prusaslicer.sh
#!/bin/bash
export DISPLAY=:1
sleep 5
flatpak run com.prusa3d.PrusaSlicer &
EOF

chmod +x /home/prusaslicer/.vnc/start-prusaslicer.sh
chown prusaslicer:prusaslicer /home/prusaslicer/.vnc/start-prusaslicer.sh
msg_ok "Created application startup script"

msg_info "Setting up auto-launch for PrusaSlicer"
mkdir -p /home/prusaslicer/.config/autostart
cat <<'EOF' > /home/prusaslicer/.config/autostart/prusaslicer.desktop
[Desktop Entry]
Type=Application
Name=PrusaSlicer
Exec=/home/prusaslicer/.vnc/start-prusaslicer.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

chown -R prusaslicer:prusaslicer /home/prusaslicer/.config
msg_ok "Set up auto-launch for PrusaSlicer"

msg_info "Configuring firewall rules"
# Allow VNC and noVNC ports
ufw allow 5901/tcp >/dev/null 2>&1
ufw allow 6080/tcp >/dev/null 2>&1
msg_ok "Configured firewall rules"

msg_info "Reloading systemd and enabling services"
systemctl daemon-reload
systemctl enable vnc@prusaslicer
systemctl enable novnc
msg_ok "Enabled services"

msg_info "Installing additional useful packages"
apt-get install -y \
    curl \
    wget \
    nano \
    htop \
    unzip \
    zip \
    git \
    build-essential \
    net-tools >/dev/null 2>&1
msg_ok "Installed additional packages"

msg_info "Setting proper file permissions"
chown -R prusaslicer:prusaslicer /home/prusaslicer
chmod 755 /home/prusaslicer
msg_ok "Set proper file permissions"

msg_info "Cleaning up"
apt-get -y autoremove >/dev/null 2>&1
apt-get -y autoclean >/dev/null 2>&1
msg_ok "Cleaned"

msg_info "PrusaSlicer Installation Complete!"
echo ""
echo "Access Information:"
echo "=================="
echo "noVNC Web Interface: http://YOUR_VM_IP:6080"
echo "VNC Direct Access: YOUR_VM_IP:5901"
echo "Username: prusaslicer"
echo "Password: prusaslicer"
echo ""
echo "To start the services manually:"
echo "systemctl start vnc@prusaslicer"
echo "systemctl start novnc"
echo ""
echo "PrusaSlicer will auto-launch when VNC session starts."
msg_ok "Installation information displayed" 
