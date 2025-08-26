#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: benjaminmerieau
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/tubearchivist/tubearchivist

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y \
  curl \
  wget \
  nginx \
  python3 \
  python3-pip \
  python3-venv \
  python3-dev \
  build-essential \
  libldap2-dev \
  libsasl2-dev \
  libssl-dev \
  ffmpeg \
  atomicparsley \
  openjdk-17-jre-headless \
  lsb-release \
  apt-transport-https \
  gnupg2
msg_ok "Installed Dependencies"

msg_info "Setting up Redis"
curl -fsSL "https://packages.redis.io/gpg" | gpg --dearmor >/usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" >/etc/apt/sources.list.d/redis.list
$STD apt-get update
$STD apt-get install -y redis
systemctl enable -q --now redis-server
msg_ok "Setup Redis"

msg_info "Setting up Elasticsearch"
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list >/dev/null
$STD apt-get update
$STD apt-get install -y elasticsearch

# Configure Elasticsearch
cat >/etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: tubearchivist
node.name: tubearchivist-node
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
path.repo: /var/lib/elasticsearch/snapshot
action.destructive_requires_name: false
EOF

# Set JVM options
echo "-Xms1g" >>/etc/elasticsearch/jvm.options.d/tubearchivist.options
echo "-Xmx1g" >>/etc/elasticsearch/jvm.options.d/tubearchivist.options

# Create snapshot directory
mkdir -p /var/lib/elasticsearch/snapshot
chown elasticsearch:elasticsearch /var/lib/elasticsearch/snapshot

# Install ingest-attachment plugin
$STD /usr/share/elasticsearch/bin/elasticsearch-plugin install ingest-attachment

systemctl enable -q --now elasticsearch

# Wait for Elasticsearch to start
sleep 30

# Set built-in user passwords
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -s -b <<< "verysecret" >/dev/null 2>&1
msg_ok "Setup Elasticsearch"

msg_info "Installing Tube-Archivist"

# Create tubearchivist user
msg_info "Creating tubearchivist user..."
$STD adduser --system --group tubearchivist
msg_info "✓ User created"

# Get latest release and download  
msg_info "Getting latest release..."
cd /opt
RELEASE=$(curl -fsSL https://api.github.com/repos/tubearchivist/tubearchivist/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4)}')
msg_info "✓ Found release: $RELEASE"

msg_info "Downloading release..."
curl -fsSL "https://github.com/tubearchivist/tubearchivist/archive/refs/tags/v${RELEASE}.tar.gz" -o "v${RELEASE}.tar.gz"
msg_info "✓ Downloaded tarball"

msg_info "Extracting release..."
$STD tar -xzf "v${RELEASE}.tar.gz"
mv tubearchivist-"${RELEASE}" tubearchivist
rm "v${RELEASE}.tar.gz"
msg_info "✓ Extracted and organized"

# Set up application directory structure (matching Dockerfile)
msg_info "Setting up application structure..."
mkdir -p /app
mv tubearchivist/* /app/
cd /app
msg_info "✓ Application structure ready"

# Create virtual environment and install dependencies
msg_info "Creating Python virtual environment..."
$STD python3 -m venv venv
msg_info "✓ Virtual environment created"

msg_info "Upgrading pip..."
$STD /app/venv/bin/pip install --upgrade pip
msg_info "✓ Pip upgraded"

msg_info "Installing Python requirements..."
$STD /app/venv/bin/pip install -r backend/requirements.txt
msg_info "✓ Requirements installed"

# Build frontend (simplified - without npm build process for now)
msg_info "Setting up frontend..."
mkdir -p /app/static
if [ -d "frontend/dist" ]; then
    cp -r frontend/dist/* /app/static/
    msg_info "✓ Frontend files copied"
else
    msg_info "! Frontend dist not found, will use basic setup"
fi

# Create required directories (matching Dockerfile volumes)
mkdir -p /cache /youtube
chown -R tubearchivist:tubearchivist /app /cache /youtube
msg_info "✓ Directories created"

# Configure application environment
msg_info "Setting up environment configuration..."
cat >/app/.env <<EOF
# Tube Archivist Environment Configuration
ES_URL=http://127.0.0.1:9200
REDIS_CON=redis://127.0.0.1:6379
HOST_UID=0
HOST_GID=0
TA_HOST=http://localhost:8000
TA_USERNAME=tubearchivist
TA_PASSWORD=verysecret
ELASTIC_PASSWORD=verysecret
TZ=UTC
EOF
msg_info "✓ Environment configured"

# Initialize application (Django setup)
msg_info "Initializing Tube-Archivist application..."
cd /app
$STD sudo -u tubearchivist bash -c "
source /app/venv/bin/activate
cd /app
export $(cat .env | xargs)
python manage.py migrate
python manage.py collectstatic --noinput
"
msg_info "✓ Application initialized"

# Create startup script (based on Dockerfile run.sh)
msg_info "Creating startup script..."
cat >/app/start.sh <<'EOF'
#!/bin/bash
set -e

# Load environment
export $(cat /app/.env | xargs)

# Start services
source /app/venv/bin/activate
cd /app

# Start nginx in background
nginx &

# Start celery worker in background
celery -A config worker --loglevel=info &

# Start the main application
exec python backend_start.py
EOF

chmod +x /app/start.sh
chown tubearchivist:tubearchivist /app/start.sh
msg_info "✓ Startup script created"

msg_ok "Installed Tube-Archivist"

msg_info "Configuring Services"
# Create systemd service for Tube-Archivist (single service now handles everything)
cat >/etc/systemd/system/tubearchivist.service <<EOF
[Unit]
Description=Tube-Archivist Application
After=network.target elasticsearch.service redis-server.service
Requires=elasticsearch.service redis-server.service

[Service]
Type=exec
User=tubearchivist
Group=tubearchivist
WorkingDirectory=/app
ExecStart=/app/start.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Configure Nginx
cat >/etc/nginx/sites-available/tubearchivist <<EOF
server {
    listen 80;
    server_name _;
    
    client_max_body_size 50M;
    
    location /static/ {
        alias /opt/tubearchivist/static/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    location /media/ {
        alias /opt/tubearchivist/media/;
        expires 1d;
    }
    
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/tubearchivist /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

systemctl daemon-reload
systemctl enable -q tubearchivist
systemctl restart -q nginx
systemctl start -q tubearchivist
msg_ok "Configured Services"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
