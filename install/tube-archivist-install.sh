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
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -s -b <<< "verysecret"
msg_ok "Setup Elasticsearch"

msg_info "Installing Tube-Archivist"
# Create tubearchivist user
useradd --system --shell /bin/bash --home-dir /opt/tubearchivist --create-home tubearchivist

# Get latest release and download  
cd /opt
RELEASE=$(curl -fsSL https://api.github.com/repos/tubearchivist/tubearchivist/releases/latest | grep "tag_name" | awk '{print substr($2, 3, length($2)-4)}')
curl -fsSL "https://github.com/tubearchivist/tubearchivist/archive/refs/tags/v${RELEASE}.tar.gz" -o "v${RELEASE}.tar.gz"
$STD tar -xzf "v${RELEASE}.tar.gz"
mv tubearchivist-"${RELEASE}" tubearchivist
rm "v${RELEASE}.tar.gz"

cd tubearchivist

# Create virtual environment and install dependencies
$STD python3 -m venv venv
$STD /opt/tubearchivist/venv/bin/pip install --upgrade pip
$STD /opt/tubearchivist/venv/bin/pip install -r requirements.txt

# Create media directories
mkdir -p /opt/tubearchivist/media/{youtube,cache}
chown -R tubearchivist:tubearchivist /opt/tubearchivist

# Configure Django settings
cat >/opt/tubearchivist/tubearchivist/settings.py <<EOF
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

SECRET_KEY = '$(openssl rand -base64 32)'

DEBUG = False

ALLOWED_HOSTS = ['*']

INSTALLED_APPS = [
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',
    'rest_framework',
    'corsheaders',
    'home',
]

MIDDLEWARE = [
    'corsheaders.middleware.CorsMiddleware',
    'django.middleware.security.SecurityMiddleware',
    'whitenoise.middleware.WhiteNoiseMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'config.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.sqlite3',
        'NAME': BASE_DIR / 'db.sqlite3',
    }
}

STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'static'
STATICFILES_STORAGE = 'whitenoise.storage.CompressedManifestStaticFilesStorage'

MEDIA_URL = '/media/'
MEDIA_ROOT = '/opt/tubearchivist/media'

# Redis configuration
REDIS_CON = 'redis://127.0.0.1:6379'

# Elasticsearch configuration  
ES_URL = 'http://127.0.0.1:9200'
ELASTIC_PASSWORD = 'verysecret'

# Celery configuration
CELERY_BROKER_URL = REDIS_CON
CELERY_RESULT_BACKEND = REDIS_CON

# Application settings
TA_HOST = 'http://localhost:8000'
TA_USERNAME = 'tubearchivist'
TA_PASSWORD = 'verysecret'

TIME_ZONE = 'UTC'
USE_TZ = True
EOF

# Run Django migrations and create superuser
cd /opt/tubearchivist
$STD sudo -u tubearchivist /opt/tubearchivist/venv/bin/python manage.py migrate
$STD sudo -u tubearchivist /opt/tubearchivist/venv/bin/python manage.py collectstatic --noinput

# Create superuser
$STD sudo -u tubearchivist /opt/tubearchivist/venv/bin/python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='tubearchivist').exists():
    User.objects.create_superuser('tubearchivist', 'admin@tubearchivist.local', 'verysecret')
"
msg_ok "Installed Tube-Archivist"

msg_info "Configuring Services"
# Create systemd service for Tube-Archivist
cat >/etc/systemd/system/tubearchivist.service <<EOF
[Unit]
Description=Tube-Archivist Django Application
After=network.target elasticsearch.service redis-server.service
Requires=elasticsearch.service redis-server.service

[Service]
Type=exec
User=tubearchivist
Group=tubearchivist
WorkingDirectory=/opt/tubearchivist
Environment=PATH=/opt/tubearchivist/venv/bin
ExecStart=/opt/tubearchivist/venv/bin/python manage.py runserver 0.0.0.0:8000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for Celery
cat >/etc/systemd/system/celery-tubearchivist.service <<EOF
[Unit]
Description=Tube-Archivist Celery Worker
After=network.target redis-server.service
Requires=redis-server.service

[Service]
Type=exec
User=tubearchivist
Group=tubearchivist
WorkingDirectory=/opt/tubearchivist
Environment=PATH=/opt/tubearchivist/venv/bin
ExecStart=/opt/tubearchivist/venv/bin/celery -A config worker -l info
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
systemctl enable -q tubearchivist celery-tubearchivist
systemctl restart -q nginx
systemctl start -q celery-tubearchivist tubearchivist
msg_ok "Configured Services"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
