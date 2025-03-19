# Multi-Container Odoo 18 Deployment

This repository contains configuration for a multi-tenant Odoo 18 deployment using Docker, with separate containers for each client, all connected to a shared PostgreSQL database server.

## Architecture Overview

- **Separate Container Architecture**: Each client has their own Odoo container
- **Database Isolation**: Each client has their own database
- **Subdomain Routing**: Each tenant accessible via their own subdomain (client1.arcweb.com.au, client2.arcweb.com.au, etc.)
- **Shared PostgreSQL**: External PostgreSQL cluster at 192.168.60.110
- **CI/CD Pipeline**: Automatic deployment through GitHub Actions
- **Resource Isolation**: Each client's container can be scaled independently

## Prerequisites

- Ubuntu server (on Proxmox)
- Docker and Docker Compose installed
- Access to PostgreSQL database server (192.168.60.110)
- Domain and DNS configuration for arcweb.com.au and subdomains
- GitHub repository for CI/CD

## Resource Recommendations

For a server hosting 10 client containers with e-commerce sites:
- **CPU**: 16+ cores
- **RAM**: 32GB+ (each container may need 2-3GB)
- **Storage**: 500GB+ SSD
- **Network**: 1Gbps

## Directory Structure

```
/
├── docker-compose.yml
├── odoo/
│   ├── Dockerfile            # Based on official Odoo 18.0 Dockerfile
│   ├── entrypoint.sh         # Container entrypoint
│   ├── wait-for-psql.py      # PostgreSQL connection check
│   ├── config/               # Configuration files for each container
│   │   ├── main.conf         # Main site configuration
│   │   ├── client1.conf      # Client 1 configuration
│   │   └── ...
│   └── addons/               # Custom addons
│       ├── shared/           # Shared addons for all clients
│       ├── main/             # Main site specific addons
│       ├── client1/          # Client 1 specific addons
│       └── ...
├── nginx/
│   ├── conf/                 # Nginx configuration
│   ├── certs/                # SSL certificates
│   └── letsencrypt/         # Let's Encrypt
├── secrets/
│   ├── db_password.txt       # Database password file
│   └── admin_password.txt    # Odoo admin password
└── scripts/
    ├── init_databases.py     # Database initialization
    ├── create_client.sh      # Create client directory structure
    └── backup.sh             # Backup script
```

## Setup Instructions

### 1. Initial Server Setup

1. Provision Ubuntu server on Proxmox with recommended specs:
   - 16+ CPU cores
   - 32+ GB RAM
   - 500GB+ storage
   - 1Gbps network

2. Install Docker and Docker Compose:
   ```bash
   apt update
   apt install -y docker.io docker-compose
   ```

3. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/odoo-multicontainer.git
   cd odoo-multicontainer
   ```

### 2. Configure Environment

1. Create directories:
   ```bash
   mkdir -p odoo/{addons/{shared,main,client{1..10}},config} nginx/{conf,certs,letsencrypt} secrets
   ```

2. Copy files from repository
   ```bash
   # Copy all files to appropriate locations
   ```

3. Create the password files:
   ```bash
   echo "your_secure_db_password" > secrets/db_password.txt
   echo "your_secure_admin_password" > secrets/admin_password.txt
   chmod 600 secrets/*.txt
   ```

4. Set up addon structure for shared modules:
   ```bash
   mkdir -p odoo/addons/shared/{arcweb_base,arcweb_ecommerce,theme_arcweb}
   ```

5. Create client directories using the script:
   ```bash
   for i in {1..10}; do
     bash scripts/create_client.sh $i
   done
   ```

### 3. Configure SSL Certificates

1. Install Certbot:
   ```bash
   apt install -y certbot
   ```

2. Generate certificates for each domain:
   ```bash
   certbot certonly --standalone -d arcweb.com.au
   for i in {1..10}; do
     certbot certonly --standalone -d client$i.arcweb.com.au
   done
   ```

3. Copy certificates to nginx/certs directory:
   ```bash
   mkdir -p nginx/certs/arcweb.com.au
   cp /etc/letsencrypt/live/arcweb.com.au/* nginx/certs/arcweb.com.au/
   
   for i in {1..10}; do
     mkdir -p nginx/certs/client$i.arcweb.com.au
     cp /etc/letsencrypt/live/client$i.arcweb.com.au/* nginx/certs/client$i.arcweb.com.au/
   done
   ```

### 4. Start the Services

1. Build and start containers:
   ```bash
   docker-compose up -d
   ```

2. Initialize the databases:
   ```bash
   # Initialize main database
   python3 scripts/init_databases.py \
     --db_host 192.168.60.110 \
     --db_port 5432 \
     --db_user odoo \
     --db_password your_secure_password \
     --init_main
   
   # Initialize all client databases
   python3 scripts/init_databases.py \
     --db_host 192.168.60.110 \
     --db_port 5432 \
     --db_user odoo \
     --db_password your_secure_password \
     --all_clients
   ```

### 5. GitHub CI/CD Setup

1. Create GitHub repository secrets:
   - `DOCKER_USERNAME`: Docker Hub username
   - `DOCKER_PASSWORD`: Docker Hub password
   - `SSH_HOST`: Server IP address
   - `SSH_USERNAME`: SSH username
   - `SSH_PRIVATE_KEY`: SSH private key for server access

2. Push the repository to GitHub:
   ```bash
   git add .
   git commit -m "Initial setup"
   git push origin main
   ```

## Maintenance and Updates

### Updating Odoo

The system is configured to automatically pull and deploy updates from the official Odoo Docker image whenever changes are pushed to the main branch. You can also trigger a manual update through GitHub Actions by selecting a specific client to update.

### Adding a New Client

1. Create client directory structure:
   ```bash
   bash scripts/create_client.sh <client_number>
   ```

2. Add client to docker-compose.yml (refer to output of create_client.sh)

3. Add DNS record for the new client subdomain

4. Generate SSL certificate:
   ```bash
   certbot certonly --standalone -d client<number>.arcweb.com.au
   mkdir -p nginx/certs/client<number>.arcweb.com.au
   cp /etc/letsencrypt/live/client<number>.arcweb.com.au/* nginx/certs/client<number>.arcweb.com.au/
   ```

5. Start the new container:
   ```bash
   docker-compose up -d client<number>
   ```

6. Initialize database:
   ```bash
   python3 scripts/init_databases.py \
     --db_host 192.168.60.110 \
     --db_port 5432 \
     --db_user odoo \
     --db_password your_secure_password \
     --client client<number>
   ```

### Resource Management

Each client container can be allocated specific resources in the docker-compose.yml file:

```yaml
client1:
  # ... existing configuration
  deploy:
    resources:
      limits:
        cpus: '2'
        memory: 3G
      reservations:
        cpus: '1'
        memory: 1G
```

### Backup Strategy

1. Database backups:
   ```bash
   # Schedule backups in crontab
   0 1 * * * /path/to/scripts/backup.sh database
   ```

2. File backups:
   ```bash
   # Schedule backups in crontab
   0 2 * * * /path/to/scripts/backup.sh files
   ```

## Troubleshooting

### Container Issues

1. Check container status:
   ```bash
   docker-compose ps
   ```

2. View container logs:
   ```bash
   docker-compose logs client1
   ```

3. Restart a specific client container:
   ```bash
   docker-compose restart client1
   ```

### Database Issues

1. Check database connection:
   ```bash
   docker exec arcweb_client1 python3 /usr/local/bin/wait-for-psql.py \
     --db_host 192.168.60.110 \
     --db_port 5432 \
     --db_user odoo \
     --db_password your_password \
     --timeout 5
   ```

2. Connect to database directly:
   ```bash
   docker exec -it arcweb_client1 psql -h 192.168.60.110 -U odoo -d client1
   ```

### Nginx Issues

1. Test Nginx configuration:
   ```bash
   docker exec arcweb_nginx nginx -t
   ```

2. View Nginx logs:
   ```bash
   docker-compose logs nginx
   ```

## Performance Optimization

1. Adjust worker count in each client's odoo.conf based on expected load
2. Implement a shared Redis server for session storage
3. Configure a CDN for static assets
4. Monitor container resources and adjust limits as needed
5. Consider horizontal scaling for high-traffic clients

## Security Considerations

1. Keep containers updated with the latest security patches
2. Implement network segmentation with Docker networks
3. Use secrets for sensitive information
4. Regularly update SSL certificates
5. Implement fail2ban for protection against brute force attacks
