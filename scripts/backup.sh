#!/bin/bash

# Backup script for Odoo multi-container environment
# Usage: ./backup.sh [database|files|all]

set -e

# Configuration
BACKUP_DIR="/backup/odoo"
DB_HOST="192.168.60.110"
DB_PORT="5432"
DB_USER="odoo"
DB_PASSWORD=$(cat /path/to/secrets/db_password.txt)
CLIENTS=("main" "client1" "client2" "client3" "client4" "client5" "client6" "client7" "client8" "client9" "client10")
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=14

# Ensure backup directory exists
mkdir -p "${BACKUP_DIR}/database"
mkdir -p "${BACKUP_DIR}/files"

# Function to backup database
backup_database() {
    echo "Starting database backups..."
    
    for CLIENT in "${CLIENTS[@]}"; do
        echo "Backing up database for ${CLIENT}..."
        DB_NAME="${CLIENT}"
        BACKUP_FILE="${BACKUP_DIR}/database/${CLIENT}_${DATE}.sql"
        
        # Use pg_dump to create backup
        PGPASSWORD="${DB_PASSWORD}" pg_dump \
            -h "${DB_HOST}" \
            -p "${DB_PORT}" \
            -U "${DB_USER}" \
            -d "${DB_NAME}" \
            -f "${BACKUP_FILE}"
        
        # Compress the backup
        gzip "${BACKUP_FILE}"
        echo "Database backup for ${CLIENT} completed: ${BACKUP_FILE}.gz"
    done
    
    echo "All database backups completed!"
}

# Function to backup files
backup_files() {
    echo "Starting file backups..."
    
    for CLIENT in "${CLIENTS[@]}"; do
        echo "Backing up files for ${CLIENT}..."
        CONTAINER_NAME="arcweb_${CLIENT}"
        BACKUP_FILE="${BACKUP_DIR}/files/${CLIENT}_${DATE}.tar.gz"
        
        # Create tar.gz of the volume
        docker run --rm \
            --volumes-from "${CONTAINER_NAME}" \
            -v "${BACKUP_DIR}/files:/backup" \
            alpine tar czf "/backup/${CLIENT}_${DATE}.tar.gz" /var/lib/odoo
        
        echo "File backup for ${CLIENT} completed: ${BACKUP_FILE}"
    done
    
    # Backup custom addons
    echo "Backing up custom addons..."
    ADDONS_BACKUP="${BACKUP_DIR}/files/addons_${DATE}.tar.gz"
    tar czf "${ADDONS_BACKUP}" -C /path/to/odoo-multicontainer/odoo addons
    echo "Addons backup completed: ${ADDONS_BACKUP}"
    
    echo "All file backups completed!"
}

# Function to clean old backups
cleanup_old_backups() {
    echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
    
    find "${BACKUP_DIR}/database" -name "*.gz" -type f -mtime +${RETENTION_DAYS} -delete
    find "${BACKUP_DIR}/files" -name "*.tar.gz" -type f -mtime +${RETENTION_DAYS} -delete
    
    echo "Cleanup completed!"
}

# Main execution
case "$1" in
    database)
        backup_database
        cleanup_old_backups
        ;;
    files)
        backup_files
        cleanup_old_backups
        ;;
    all)
        backup_database
        backup_files
        cleanup_old_backups
        ;;
    *)
        echo "Usage: $0 [database|files|all]"
        exit 1
        ;;
esac

echo "Backup process completed successfully!"
