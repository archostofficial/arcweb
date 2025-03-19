#!/bin/bash

# This script creates the necessary files and directories for a new client

if [ $# -ne 1 ]; then
    echo "Usage: $0 <client_number>"
    exit 1
fi

CLIENT_NUM=$1
CLIENT_NAME="client${CLIENT_NUM}"

# Create directory structure
echo "Creating directory structure for ${CLIENT_NAME}..."
mkdir -p "odoo/addons/${CLIENT_NAME}/${CLIENT_NAME}_custom"
mkdir -p "odoo/addons/${CLIENT_NAME}/${CLIENT_NAME}_website"
mkdir -p "odoo/config"
mkdir -p "nginx/certs/${CLIENT_NAME}.arcweb.com.au"

# Create __manifest__.py files
echo "Creating Odoo addon manifests..."
cat > "odoo/addons/${CLIENT_NAME}/${CLIENT_NAME}_custom/__manifest__.py" << EOF
{
    'name': 'Client ${CLIENT_NUM} Custom',
    'version': '1.0',
    'category': 'Hidden',
    'summary': 'Custom modifications for Client ${CLIENT_NUM}',
    'description': """
        Custom modules for Client ${CLIENT_NUM}
    """,
    'depends': ['base', 'arcweb_base', 'arcweb_ecommerce'],
    'data': [],
    'installable': True,
    'application': False,
}
EOF

cat > "odoo/addons/${CLIENT_NAME}/${CLIENT_NAME}_website/__manifest__.py" << EOF
{
    'name': 'Client ${CLIENT_NUM} Website',
    'version': '1.0',
    'category': 'Website',
    'summary': 'Website customizations for Client ${CLIENT_NUM}',
    'description': """
        Website customizations for Client ${CLIENT_NUM}
    """,
    'depends': ['website', 'website_sale', 'theme_arcweb'],
    'data': [],
    'installable': True,
    'application': False,
}
EOF

# Create __init__.py files
touch "odoo/addons/${CLIENT_NAME}/${CLIENT_NAME}_custom/__init__.py"
touch "odoo/addons/${CLIENT_NAME}/${CLIENT_NAME}_website/__init__.py"

# Create symbolic links for shared modules
echo "Creating symbolic links to shared modules..."
ln -sf "../../shared/arcweb_base" "odoo/addons/${CLIENT_NAME}/"
ln -sf "../../shared/arcweb_ecommerce" "odoo/addons/${CLIENT_NAME}/"
ln -sf "../../shared/theme_arcweb" "odoo/addons/${CLIENT_NAME}/"

# Create Odoo configuration file
echo "Creating Odoo configuration file..."
cat > "odoo/config/${CLIENT_NAME}.conf" << EOF
[options]
addons_path = /mnt/extra-addons/${CLIENT_NAME},/mnt/extra-addons/shared
data_dir = /var/lib/odoo
admin_passwd = \${ADMIN_PASSWORD}
db_host = 192.168.60.110
db_port = 5432
db_user = odoo
db_password = \${DB_PASSWORD}
dbfilter = ^${CLIENT_NAME}$
db_name = ${CLIENT_NAME}
proxy_mode = True
workers = 2
max_cron_threads = 1
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 120
limit_time_real = 240
log_level = info
logfile = /var/log/odoo/odoo-server.log
longpolling_port = 8072
email_from = noreply@${CLIENT_NAME}.arcweb.com.au
smtp_server = smtp.arcweb.com.au
smtp_port = 587
smtp_user = \${SMTP_USER}
smtp_password = \${SMTP_PASSWORD}
smtp_ssl = True
EOF

# Create Nginx configuration
echo "Creating Nginx configuration..."
cat > "nginx/conf/${CLIENT_NAME}.conf" << EOF
server {
    listen 80;
    server_name ${CLIENT_NAME}.arcweb.com.au;
    
    # Redirect to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
    
    # Let's Encrypt validation
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}

server {
    listen 443 ssl;
    server_name ${CLIENT_NAME}.arcweb.com.au;
    
    ssl_certificate /etc/nginx/certs/${CLIENT_NAME}.arcweb.com.au/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/${CLIENT_NAME}.arcweb.com.au/privkey.pem;
    
    # SSL configurations
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers "EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH";
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # Proxy to Client Odoo
    location / {
        proxy_pass http://${CLIENT_NAME}:8069;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    # Static files
    location ~* /web/static/ {
        proxy_cache_valid 200 60m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://${CLIENT_NAME}:8069;
    }
    
    # Longpolling
    location /longpolling {
        proxy_pass http://${CLIENT_NAME}:8072;
    }
    
    # Increase maximum upload size
    client_max_body_size 100M;
}
EOF

# Update docker-compose.yml
echo "To add this client to docker-compose.yml, add the following:"
echo "
  # Client ${CLIENT_NUM}
  ${CLIENT_NAME}:
    build:
      context: ./odoo
      dockerfile: Dockerfile
      args:
        - ODOO_VERSION=18.0
    image: arcweb/odoo:18.0
    container_name: arcweb_${CLIENT_NAME}
    restart: always
    volumes:
      - odoo-${CLIENT_NAME}-data:/var/lib/odoo
      - ./odoo/addons/shared:/mnt/extra-addons/shared
      - ./odoo/addons/${CLIENT_NAME}:/mnt/extra-addons/${CLIENT_NAME}
      - ./odoo/config/${CLIENT_NAME}.conf:/etc/odoo/odoo.conf
    environment:
      - HOST=192.168.60.110
      - PORT=5432
      - USER=odoo
      - PASSWORD_FILE=/run/secrets/db_password
      - ADMIN_PASSWORD_FILE=/run/secrets/admin_password
    networks:
      - odoo_network
    secrets:
      - db_password
      - admin_password

# Add to volumes section:
  odoo-${CLIENT_NAME}-data:
"

echo "Also add ${CLIENT_NAME} to the nginx depends_on section."

echo "Done. Directory structure for ${CLIENT_NAME} created."
echo "Don't forget to generate SSL certificates for ${CLIENT_NAME}.arcweb.com.au"
