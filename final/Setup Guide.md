# Complete Multi-Tenant Odoo Setup Guide

This comprehensive guide explains how to set up multiple Odoo instances (tenants) on a single server, each with its own database and domain name.

## System Architecture

- **Main Odoo instance**: Running on the main domain (arcweb.com.au)
- **Additional tenant instances**: Each running on their own subdomain (e.g., app2.arcweb.com.au)
- **PostgreSQL database**: External PostgreSQL cluster with SSL enabled
- **Nginx**: Handles routing requests to the appropriate Odoo instance based on domain name
- **Docker**: Containerizes each Odoo instance for isolation

## Prerequisites

- Ubuntu server (Noble 24.04 or similar)
- Docker and Docker Compose installed
- Nginx installed
- SSL certificates from Let's Encrypt
- Access to a PostgreSQL database server
- Domain with DNS control

## 1. Setting Up the Main Odoo Instance

### 1.1 Directory Structure

First, create the base directory structure:

```bash
mkdir -p /opt/odoo/18.0 /opt/odoo/addons
```

### 1.2 Create Dockerfile

```bash
cat > /opt/odoo/Dockerfile << 'EOF'
FROM ubuntu:noble
MAINTAINER Odoo S.A. <info@odoo.com>

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]

# Generate locale C.UTF-8 for postgres and general locale data
ENV LANG en_US.UTF-8

# Retrieve the target architecture to install the correct wkhtmltopdf package
ARG TARGETARCH

# Install some deps, lessc and less-plugin-clean-css, and wkhtmltopdf
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dirmngr \
        fonts-noto-cjk \
        gnupg \
        libssl-dev \
        node-less \
        npm \
        python3-magic \
        python3-num2words \
        python3-odf \
        python3-pdfminer \
        python3-pip \
        python3-phonenumbers \
        python3-pyldap \
        python3-qrcode \
        python3-renderpm \
        python3-setuptools \
        python3-slugify \
        python3-vobject \
        python3-watchdog \
        python3-xlrd \
        python3-xlwt \
        xz-utils \
        python3-psycopg2 && \
    if [ -z "${TARGETARCH}" ]; then \
        TARGETARCH="$(dpkg --print-architecture)"; \
    fi; \
    WKHTMLTOPDF_ARCH=${TARGETARCH} && \
    case ${TARGETARCH} in \
    "amd64") WKHTMLTOPDF_ARCH=amd64 && WKHTMLTOPDF_SHA=967390a759707337b46d1c02452e2bb6b2dc6d59  ;; \
    "arm64")  WKHTMLTOPDF_SHA=90f6e69896d51ef77339d3f3a20f8582bdf496cc  ;; \
    "ppc64le" | "ppc64el") WKHTMLTOPDF_ARCH=ppc64el && WKHTMLTOPDF_SHA=5312d7d34a25b321282929df82e3574319aed25c  ;; \
    esac \
    && curl -o wkhtmltox.deb -sSL https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_${WKHTMLTOPDF_ARCH}.deb \
    && echo ${WKHTMLTOPDF_SHA} wkhtmltox.deb | sha1sum -c - \
    && apt-get install -y --no-install-recommends ./wkhtmltox.deb \
    && rm -rf /var/lib/apt/lists/* wkhtmltox.deb

# install latest postgresql-client
RUN echo 'deb http://apt.postgresql.org/pub/repos/apt/ noble-pgdg main' > /etc/apt/sources.list.d/pgdg.list \
    && GNUPGHOME="$(mktemp -d)" \
    && export GNUPGHOME \
    && repokey='B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8' \
    && gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "${repokey}" \
    && gpg --batch --armor --export "${repokey}" > /etc/apt/trusted.gpg.d/pgdg.gpg.asc \
    && gpgconf --kill all \
    && rm -rf "$GNUPGHOME" \
    && apt-get update  \
    && apt-get install --no-install-recommends -y postgresql-client \
    && rm -f /etc/apt/sources.list.d/pgdg.list \
    && rm -rf /var/lib/apt/lists/*

# Install rtlcss (on Debian buster)
RUN npm install -g rtlcss

# Install Odoo
ENV ODOO_VERSION 18.0
ARG ODOO_RELEASE=20250311
ARG ODOO_SHA=de629e8416caca2475aa59cf73049fc89bf5ea5b
RUN curl -o odoo.deb -sSL http://nightly.odoo.com/${ODOO_VERSION}/nightly/deb/odoo_${ODOO_VERSION}.${ODOO_RELEASE}_all.deb \
    && echo "${ODOO_SHA} odoo.deb" | sha1sum -c - \
    && apt-get update \
    && apt-get -y install --no-install-recommends ./odoo.deb \
    && rm -rf /var/lib/apt/lists/* odoo.deb

# Copy configuration files
COPY ./18.0/odoo.conf /etc/odoo/
COPY ./18.0/entrypoint.sh /entrypoint.sh
COPY ./18.0/wait-for-psql.py /usr/local/bin/wait-for-psql.py

# Set permissions and create directories
RUN chmod +x /entrypoint.sh /usr/local/bin/wait-for-psql.py \
    && chown odoo /etc/odoo/odoo.conf \
    && mkdir -p /mnt/extra-addons \
    && chown -R odoo /mnt/extra-addons

# Mount volumes
VOLUME ["/var/lib/odoo", "/mnt/extra-addons"]

# Expose Odoo services
EXPOSE 8069 8071 8072

# Set the default config file
ENV ODOO_RC /etc/odoo/odoo.conf

# Set default user when running the container
USER odoo

ENTRYPOINT ["/entrypoint.sh"]
CMD ["odoo"]
EOF
```

### 1.3 Create Support Files

Create the entrypoint script:

```bash
cat > /opt/odoo/18.0/entrypoint.sh << 'EOF'
#!/bin/bash

set -e

if [ -v PASSWORD_FILE ]; then
    PASSWORD="$(< $PASSWORD_FILE)"
fi

# set the postgres database host, port, user and password according to the environment
# and pass them as arguments to the odoo process if not present in the config file
: ${HOST:=${DB_PORT_5432_TCP_ADDR:='db'}}
: ${PORT:=${DB_PORT_5432_TCP_PORT:=5432}}
: ${USER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:='odoo'}}}
: ${PASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}}

DB_ARGS=()
function check_config() {
    param="$1"
    value="$2"
    if grep -q -E "^\s*\b${param}\b\s*=" "$ODOO_RC" ; then       
        value=$(grep -E "^\s*\b${param}\b\s*=" "$ODOO_RC" |cut -d " " -f3|sed 's/["\n\r]//g')
    fi;
    DB_ARGS+=("--${param}")
    DB_ARGS+=("${value}")
}
check_config "db_host" "$HOST"
check_config "db_port" "$PORT"
check_config "db_user" "$USER"
check_config "db_password" "$PASSWORD"

case "$1" in
    -- | odoo)
        shift
        if [[ "$1" == "scaffold" ]] ; then
            exec odoo "$@"
        else
            wait-for-psql.py ${DB_ARGS[@]} --timeout=30
            exec odoo "$@" "${DB_ARGS[@]}"
        fi
        ;;
    -*)
        wait-for-psql.py ${DB_ARGS[@]} --timeout=30
        exec odoo "$@" "${DB_ARGS[@]}"
        ;;
    *)
        exec "$@"
esac

exit 1
EOF

chmod +x /opt/odoo/18.0/entrypoint.sh
```

Create the wait-for-psql script:

```bash
cat > /opt/odoo/18.0/wait-for-psql.py << 'EOF'
#!/usr/bin/env python3
import argparse
import psycopg2
import sys
import time


if __name__ == '__main__':
    arg_parser = argparse.ArgumentParser()
    arg_parser.add_argument('--db_host', required=True)
    arg_parser.add_argument('--db_port', required=True)
    arg_parser.add_argument('--db_user', required=True)
    arg_parser.add_argument('--db_password', required=True)
    arg_parser.add_argument('--timeout', type=int, default=5)

    args = arg_parser.parse_args()

    start_time = time.time()
    while (time.time() - start_time) < args.timeout:
        try:
            conn = psycopg2.connect(user=args.db_user, host=args.db_host, port=args.db_port, password=args.db_password, dbname='postgres')
            error = ''
            break
        except psycopg2.OperationalError as e:
            error = e
        else:
            conn.close()
        time.sleep(1)

    if error:
        print("Database connection failure: %s" % error, file=sys.stderr)
        sys.exit(1)
EOF

chmod +x /opt/odoo/18.0/wait-for-psql.py
```

### 1.4 Create Configuration File

```bash
cat > /opt/odoo/18.0/odoo.conf << 'EOF'
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
db_host = 192.168.60.110
db_port = 5432
db_user = odoo
db_password = cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf
db_name = odoo
db_sslmode = prefer
db_maxconn = 4
proxy_mode = True
website_name = arcweb.com.au
without_demo = all

; server parameters
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 120
limit_time_real = 240
max_cron_threads = 1
workers = 2
EOF
```

### 1.5 Create Docker Compose File

```bash
cat > /opt/odoo/docker-compose.yml << 'EOF'
version: '3'
services:
  odoo:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8069:8069"
      - "8071:8071"
      - "8072:8072"
    volumes:
      - odoo-data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
    environment:
      - HOST=192.168.60.110
      - PORT=5432
      - USER=odoo
      - PASSWORD=cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf
      - DB_NAME=odoo
      - VIRTUAL_HOST=arcweb.com.au
      - VIRTUAL_PORT=8069
      - PGSSLMODE=prefer
      - DB_MAXCONN=4
    command: ["odoo", "--without-demo=all"]
    restart: always

volumes:
  odoo-data:
EOF
```

### 1.6 Start the Main Odoo Container

```bash
cd /opt/odoo
docker-compose up -d
```

### 1.7 Initialize the Database

```bash
docker-compose run --rm odoo odoo --init base --database odoo --db_host 192.168.60.110 --db_port 5432 --db_user odoo --db_password cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf --without-demo=all
```

## 2. Setting up Additional Tenants

### 2.1 Creating the app2 Tenant

First, create the directory structure:

```bash
mkdir -p /opt/odoo-app2/18.0 /opt/odoo-app2/addons
```

### 2.2 Create Configuration Files

```bash
# Copy files from main instance
cp /opt/odoo/Dockerfile /opt/odoo-app2/
cp /opt/odoo/18.0/entrypoint.sh /opt/odoo-app2/18.0/
cp /opt/odoo/18.0/wait-for-psql.py /opt/odoo-app2/18.0/

# Create Odoo configuration
cat > /opt/odoo-app2/18.0/odoo.conf << 'EOF'
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
db_host = 192.168.60.110
db_port = 5432
db_user = odoo
db_password = cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf
db_name = odoo_app2
db_sslmode = prefer
db_maxconn = 2
proxy_mode = True
website_name = app2.arcweb.com.au
without_demo = all

; server parameters
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 120
limit_time_real = 240
max_cron_threads = 0
workers = 2
EOF

# Create Docker Compose file
cat > /opt/odoo-app2/docker-compose.yml << 'EOF'
version: '3'
services:
  odoo-app2:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8171:8069"
      - "8172:8071"
      - "8173:8072"
    volumes:
      - odoo-app2-data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
    environment:
      - HOST=192.168.60.110
      - PORT=5432
      - USER=odoo
      - PASSWORD=cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf
      - DB_NAME=odoo_app2
      - VIRTUAL_HOST=app2.arcweb.com.au
      - VIRTUAL_PORT=8069
      - PGSSLMODE=prefer
      - DB_MAXCONN=2
    command: ["odoo", "--without-demo=all", "--max-cron-threads=0"]
    restart: always

volumes:
  odoo-app2-data:
EOF
```

### 2.3 Start the app2 Container

```bash
cd /opt/odoo-app2
docker-compose up -d
```

### 2.4 Create the Database for app2

```bash
# Create the database
PGPASSWORD=cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf psql -h 192.168.60.110 -U odoo -c "CREATE DATABASE odoo_app2 OWNER odoo;"

# Initialize the database
docker-compose run --rm odoo-app2 odoo --init base --database odoo_app2 --db_host 192.168.60.110 --db_port 5432 --db_user odoo --db_password cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf --without-demo=all
```

## 3. Setting up Nginx

### 3.1 Create Nginx Configuration Files

Create the main site configuration:

```bash
cat > /etc/nginx/sites-available/arcweb.com.au.conf << 'EOF'
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

# Main Odoo server
upstream odoo_main {
   server 127.0.0.1:8069;
}
upstream odoochat_main {
   server 127.0.0.1:8072;
}

# HTTP redirects to HTTPS
server {
   listen 80;
   server_name arcweb.com.au www.arcweb.com.au;
   
   # Redirect to HTTPS
   return 301 https://$host$request_uri;
}

# Main Odoo server (arcweb.com.au)
server {
   listen 443 ssl http2;
   server_name arcweb.com.au www.arcweb.com.au;

   ssl_certificate /etc/letsencrypt/live/arcweb.com.au/fullchain.pem;
   ssl_certificate_key /etc/letsencrypt/live/arcweb.com.au/privkey.pem;

   # log
   access_log /var/log/nginx/arcweb.com.au.access.log;
   error_log /var/log/nginx/arcweb.com.au.error.log;

   proxy_read_timeout 720s;
   proxy_connect_timeout 720s;
   proxy_send_timeout 720s;

   # Redirect websocket requests
   location /websocket {
      proxy_pass http://odoochat_main;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Real-IP $remote_addr;
   }

   # Redirect longpoll requests
   location /longpolling {
      proxy_pass http://odoochat_main;
   }

   # Redirect requests to odoo backend server
   location / {
      # Add Headers for odoo proxy mode
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_redirect off;
      proxy_pass http://odoo_main;
      client_max_body_size 512M;
   }

   location ~* /web/static/ {
      proxy_cache_valid 200 90m;
      proxy_buffering on;
      expires 864000;
      proxy_pass http://odoo_main;
   }

   # common gzip
   gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
   gzip on;
}
EOF
```

Create the app2 site configuration:

```bash
cat > /etc/nginx/sites-available/app2.arcweb.com.au.conf << 'EOF'
# Variables set in the main arcweb config
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

# App2 Odoo server
upstream odoo_app2 {
   server 127.0.0.1:8171;
}
upstream odoochat_app2 {
   server 127.0.0.1:8173;
}

# HTTP redirect to HTTPS
server {
   listen 80;
   server_name app2.arcweb.com.au;
   
   # Redirect to HTTPS
   return 301 https://$host$request_uri;
}

# App2 tenant (app2.arcweb.com.au)
server {
   listen 443 ssl http2;
   server_name app2.arcweb.com.au;

   ssl_certificate /etc/letsencrypt/live/arcweb.com.au/fullchain.pem;
   ssl_certificate_key /etc/letsencrypt/live/arcweb.com.au/privkey.pem;

   # log
   access_log /var/log/nginx/app2.arcweb.com.au.access.log;
   error_log /var/log/nginx/app2.arcweb.com.au.error.log;

   proxy_read_timeout 720s;
   proxy_connect_timeout 720s;
   proxy_send_timeout 720s;

   # Redirect websocket requests
   location /websocket {
      proxy_pass http://odoochat_app2;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Real-IP $remote_addr;
   }

   # Redirect longpoll requests
   location /longpolling {
      proxy_pass http://odoochat_app2;
   }

   # Redirect requests to odoo backend server
   location / {
      # Add Headers for odoo proxy mode
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_redirect off;
      proxy_pass http://odoo_app2;
      client_max_body_size 512M;
   }

   location ~* /web/static/ {
      proxy_cache_valid 200 90m;
      proxy_buffering on;
      expires 864000;
      proxy_pass http://odoo_app2;
   }

   # common gzip
   gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
   gzip on;
}
EOF
```

### 3.2 Enable the sites

```bash
# Remove old configuration if it exists
rm -f /etc/nginx/sites-enabled/arcweb.conf

# Enable the new configurations
ln -sf /etc/nginx/sites-available/arcweb.com.au.conf /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/app2.arcweb.com.au.conf /etc/nginx/sites-enabled/

# Test Nginx configuration
nginx -t

# Restart Nginx
systemctl restart nginx
```

## 4. Setting up DNS

Add the following DNS records for your domain:

| Type | Name | Content | Proxied |
|------|------|---------|---------|
| A | arcweb.com.au | YOUR_SERVER_IP | Yes |
| A | www.arcweb.com.au | YOUR_SERVER_IP | Yes |
| A | app2.arcweb.com.au | YOUR_SERVER_IP | Yes |

## 5. SSL Certificates

Obtain SSL certificates using Let's Encrypt:

```bash
# Install Certbot
apt-get update
apt-get install -y certbot python3-certbot-nginx

# Get wildcard certificate (with DNS validation)
certbot certonly --manual --preferred-challenges dns \
  -d arcweb.com.au -d *.arcweb.com.au \
  --agree-tos -m info@archost.com
```

During this process, you'll need to create a TXT record in your DNS to prove domain ownership.

## 6. Tenant Creation Script

For easier creation of future tenants, create a script:

```bash
cat > /opt/create-tenant.sh << 'EOF'
#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 tenant_name database_name"
    echo "Example: $0 customer1 odoo_customer1"
    exit 1
fi

TENANT=$1
DB_NAME=$2
TENANT_DIR="/opt/odoo-$TENANT"
BASE_PORT=$((8090 + RANDOM % 100))  # Random port between 8090-8190
HTTP_PORT=$BASE_PORT
HTTPS_PORT=$((BASE_PORT+1))
CHAT_PORT=$((BASE_PORT+2))

echo "Creating new tenant: $TENANT"
echo "Database name: $DB_NAME"
echo "Ports: HTTP=$HTTP_PORT, HTTPS=$HTTPS_PORT, Chat=$CHAT_PORT"

# Check if directory already exists
if [ -d "$TENANT_DIR" ]; then
    echo "Warning: Tenant directory already exists. Removing it to start fresh."
    rm -rf "$TENANT_DIR"
fi

# Create directories
mkdir -p "$TENANT_DIR/18.0" "$TENANT_DIR/addons"

# Create docker-compose.yml
cat > "$TENANT_DIR/docker-compose.yml" << 'EODCF'
version: '3'
services:
  odoo-TENANT_PLACEHOLDER:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "HTTP_PORT_PLACEHOLDER:8069"
      - "HTTPS_PORT_PLACEHOLDER:8071"
      - "CHAT_PORT_PLACEHOLDER:8072"
    volumes:
      - odoo-TENANT_PLACEHOLDER-data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
    environment:
      - HOST=192.168.60.110
      - PORT=5432
      - USER=odoo
      - PASSWORD=cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf
      - DB_NAME=DB_NAME_PLACEHOLDER
      - VIRTUAL_HOST=TENANT_PLACEHOLDER.arcweb.com.au
      - VIRTUAL_PORT=8069
      - PGSSLMODE=prefer
      - DB_MAXCONN=2
    command: ["odoo", "--without-demo=all", "--max-cron-threads=0"]
    restart: always

volumes:
  odoo-TENANT_PLACEHOLDER-data:
EODCF

# Replace placeholders
sed -i "s/TENANT_PLACEHOLDER/$TENANT/g" "$TENANT_DIR/docker-compose.yml"
sed -i "s/HTTP_PORT_PLACEHOLDER/$HTTP_PORT/g" "$TENANT_DIR/docker-compose.yml"
sed -i "s/HTTPS_PORT_PLACEHOLDER/$HTTPS_PORT/g" "$TENANT_DIR/docker-compose.yml"
sed -i "s/CHAT_PORT_PLACEHOLDER/$CHAT_PORT/g" "$TENANT_DIR/docker-compose.yml"
sed -i "s/DB_NAME_PLACEHOLDER/$DB_NAME/g" "$TENANT_DIR/docker-compose.yml"

# Create odoo.conf
cat > "$TENANT_DIR/18.0/odoo.conf" << 'EOCNF'
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
db_host = 192.168.60.110
db_port = 5432
db_user = odoo
db_password = cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf
db_name = DB_NAME_PLACEHOLDER
db_sslmode = prefer
db_maxconn = 2
proxy_mode = True
website_name = TENANT_PLACEHOLDER.arcweb.com.au
without_demo = all

; server parameters
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 120
limit_time_real = 240
max_cron_threads = 0
workers = 2
EOCNF

# Replace placeholders
sed -i "s/TENANT_PLACEHOLDER/$TENANT/g" "$TENANT_DIR/18.0/odoo.conf"
sed -i "s/DB_NAME_PLACEHOLDER/$DB_NAME/g" "$TENANT_DIR/18.0/odoo.conf"

# Copy required files
cp /opt/odoo/Dockerfile "$TENANT_DIR/"
cp /opt/odoo/18.0/entrypoint.sh "$TENANT_DIR/18.0/"
cp /opt/odoo/18.0/wait-for-psql.py "$TENANT_DIR/18.0/"

# Create or replace the database
PGPASSWORD=cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf psql -h 192.168.60.110 -U odoo -c "DROP DATABASE IF EXISTS $DB_NAME;"
PGPASSWORD=cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf psql -h 192.168.60.110 -U odoo -c "CREATE DATABASE $DB_NAME OWNER odoo;"

# Create Nginx configuration file
cat > /etc/nginx/sites-available/$TENANT.arcweb.com.au.conf << 'EONGINX'
# Variables set in the main arcweb config
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

# TENANT_PLACEHOLDER Odoo server
upstream odoo_TENANT_PLACEHOLDER {
   server 127.0.0.1:HTTP_PORT_PLACEHOLDER;
}
upstream odoochat_TENANT_PLACEHOLDER {
   server 127.0.0.1:CHAT_PORT_PLACEHOLDER;
}

# HTTP redirect to HTTPS
server {
   listen 80;
   server_name TENANT_PLACEHOLDER.arcweb.com.au;
   
   # Redirect to HTTPS
   return 301 https://$host$request_uri;
}

# TENANT_PLACEHOLDER tenant (TENANT_PLACEHOLDER.arcweb.com.au)
server {
   listen 443 ssl http2;
   server_name TENANT_PLACEHOLDER.arcweb.com.au;

   ssl_certificate /etc/letsencrypt/live/arcweb.com.au/fullchain.pem;
   ssl_certificate_key /etc/letsencrypt/live/arcweb.com.au/privkey.pem;

   # log
   access_log /var/log/nginx/TENANT_PLACEHOLDER.arcweb.com.au.access.log;
   error_log /var/log/nginx/TENANT_PLACEHOLDER.arcweb.com.au.error.log;

   proxy_read_timeout 720s;
   proxy_connect_timeout 720s;
   proxy_send_timeout 720s;

   # Redirect websocket requests
   location /websocket {
      proxy_pass http://odoochat_TENANT_PLACEHOLDER;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Real-IP $remote_addr;
   }

   # Redirect longpoll requests
   location /longpolling {
      proxy_pass http://odoochat_TENANT_PLACEHOLDER;
   }

   # Redirect requests to odoo backend server
   location / {
      # Add Headers for odoo proxy mode
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_redirect off;
      proxy_pass http://odoo_TENANT_PLACEHOLDER;
      client_max_body_size 512M;
   }

   location ~* /web/static/ {
      proxy_cache_valid 200 90m;
      proxy_buffering on;
      expires 864000;
      proxy_pass http://odoo_TENANT_PLACEHOLDER;
   }

   # common gzip
   gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
   gzip on;
}
EONGINX

# Replace placeholders
sed -i "s/TENANT_PLACEHOLDER/$TENANT/g" /etc/nginx/sites-available/$TENANT.arcweb.com.au.conf
sed -i "s/HTTP_PORT_PLACEHOLDER/$HTTP_PORT/g" /etc/nginx/sites-available/$TENANT.arcweb.com.au.conf
sed -i "s/CHAT_PORT_PLACEHOLDER/$CHAT_PORT/g" /etc/nginx/sites-available/$TENANT.arcweb.com.au.conf

# Enable the Nginx configuration
ln -sf /etc/nginx/sites-available/$TENANT.arcweb.com.au.conf /etc/nginx/sites-enabled/

echo "Starting the new tenant..."
cd "$TENANT_DIR"
docker-compose up -d

echo "Initializing the database without demo data..."
docker-compose run --rm odoo-$TENANT odoo --init base --database $DB_NAME --db_host 192.168.60.110 --db_port 5432 --db_user odoo --db_password cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf --without-demo=all

# Test and restart Nginx
nginx -t && systemctl restart nginx

echo "Tenant $TENANT has been created successfully!"
echo "You can access it at https://$TENANT.arcweb.com.au"
EOF

chmod +x /opt/create-tenant.sh

## 7. Managing Multiple Tenants

Here are some best practices for managing multiple Odoo tenants:

### 7.1 Resource Management

- Monitor server resources to ensure you have enough capacity for all tenants
- Adjust the number of workers and memory limits based on tenant usage
- Consider using monitoring tools like Prometheus/Grafana to track performance

### 7.2 Backup Strategy

Create a backup script for all tenants:

```bash
cat > /opt/backup-tenants.sh << 'EOF'
#!/bin/bash

BACKUP_DIR="/opt/backups/$(date +%Y-%m-%d)"
mkdir -p $BACKUP_DIR

# Backup each database
for dir in /opt/odoo /opt/odoo-*; do
  if [ -d "$dir" ] && [ -f "$dir/docker-compose.yml" ]; then
    # Extract the database name
    DB_NAME=$(grep "DB_NAME=" "$dir/docker-compose.yml" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | head -1)
    
    if [ ! -z "$DB_NAME" ]; then
      echo "Backing up database: $DB_NAME"
      PGPASSWORD=cnV2abjbDpbh64e12987wR4mj5kQ3456Y0Qf pg_dump -h 192.168.60.110 -U odoo -F c -b -v -f "$BACKUP_DIR/$DB_NAME.backup" "$DB_NAME"
    fi
  fi
done

# Backup the Nginx configurations
cp /etc/nginx/sites-available/*.arcweb.com.au.conf $BACKUP_DIR/

# Backup the SSL certificates
cp -r /etc/letsencrypt/live/arcweb.com.au $BACKUP_DIR/

echo "Backup completed at $BACKUP_DIR"
EOF

chmod +x /opt/backup-tenants.sh
```

Set up a daily cron job for backups:

```bash
echo "0 2 * * * root /opt/backup-tenants.sh" > /etc/cron.d/odoo-backup
```

### 7.3 Updating All Tenants

Create a script to update all tenant containers:

```bash
cat > /opt/update-tenants.sh << 'EOF'
#!/bin/bash

# Update and restart all tenants
for dir in /opt/odoo /opt/odoo-*; do
  if [ -d "$dir" ] && [ -f "$dir/docker-compose.yml" ]; then
    echo "Updating tenant in $dir"
    cd "$dir"
    docker-compose pull
    docker-compose down
    docker-compose up -d
  fi
done

echo "All tenants updated"
EOF

chmod +x /opt/update-tenants.sh
```

## 8. Troubleshooting

### 8.1 Checking Logs

To check logs for a specific tenant:

```bash
cd /opt/odoo-tenant_name
docker-compose logs -f
```

To check Nginx logs:

```bash
tail -f /var/log/nginx/tenant_name.arcweb.com.au.error.log
```

### 8.2 Connection Issues

If you encounter SSL SYSCALL errors in the logs, you may need to adjust the SSL mode:

```bash
# Update all tenant configurations with a script
cat > /opt/fix-ssl-mode.sh << 'EOF'
#!/bin/bash

# Update all tenant configurations
for dir in /opt/odoo /opt/odoo-*; do
  if [ -d "$dir" ]; then
    echo "Updating configuration in $dir..."
    
    # Update docker-compose.yml
    if grep -q "PGSSLMODE" "$dir/docker-compose.yml"; then
      sed -i 's/PGSSLMODE=.*/PGSSLMODE=prefer/' "$dir/docker-compose.yml"
    else
      sed -i '/PASSWORD=/ a\      - PGSSLMODE=prefer' "$dir/docker-compose.yml"
    fi
    
    # Update odoo.conf
    if [ -f "$dir/18.0/odoo.conf" ]; then
      if grep -q "db_sslmode" "$dir/18.0/odoo.conf"; then
        sed -i 's/db_sslmode = .*/db_sslmode = prefer/' "$dir/18.0/odoo.conf"
      else
        echo "db_sslmode = prefer" >> "$dir/18.0/odoo.conf"
      fi
    fi
    
    # Restart the container
    cd "$dir"
    docker-compose down
    docker-compose up -d
  fi
done

echo "All tenant configurations have been updated to use SSL prefer mode."
EOF

chmod +x /opt/fix-ssl-mode.sh
```

## 9. Security Considerations

### 9.1 Restricting Database Access

To restrict access to the database manager interface:

```bash
# Edit the Nginx configuration for each site
sed -i '/location ~\* \/web\/database\/manager/a\    allow 192.168.1.0/24;\n    deny all;' /etc/nginx/sites-available/*.arcweb.com.au.conf
```

### 9.2 Odoo Master Password

Set a strong master password in each odoo.conf file:

```bash
# Generate a random password
MASTER_PASSWORD=$(openssl rand -base64 32)

# Add it to all configuration files
for conf in /opt/odoo*/18.0/odoo.conf; do
  sed -i "/\[options\]/a admin_passwd = $MASTER_PASSWORD" $conf
done
```

### 9.3 Firewall Configuration

Ensure your firewall allows only the necessary ports:

```bash
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 8069:8200/tcp  # Block direct access to Odoo ports
```

## Conclusion

This guide provides a comprehensive setup for running multiple Odoo instances on a single server, each with its own domain name and database. The modular approach with separate configuration files makes maintenance easier and allows for better scalability.

By following these steps, you can create a robust multi-tenant Odoo environment that is secure, maintainable, and efficient.
