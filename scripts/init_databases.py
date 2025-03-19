#!/usr/bin/env python3
import argparse
import psycopg2
import subprocess
import os
import time
import requests

def create_database(args, client_name):
    """Create a new database for a client"""
    conn = None
    try:
        # Connect to PostgreSQL
        conn = psycopg2.connect(
            host=args.db_host,
            port=args.db_port,
            user=args.db_user,
            password=args.db_password,
            dbname='postgres'
        )
        conn.autocommit = True
        cursor = conn.cursor()
        
        db_name = client_name
        
        # Check if database exists
        cursor.execute("SELECT 1 FROM pg_database WHERE datname=%s", (db_name,))
        if cursor.fetchone():
            print(f"Database {db_name} already exists")
            return db_name
        
        # Create database
        print(f"Creating database {db_name}")
        cursor.execute(f"CREATE DATABASE {db_name} OWNER {args.db_user}")
        
        return db_name
        
    except Exception as e:
        print(f"Error creating database: {e}")
        raise
    finally:
        if conn:
            conn.close()

def initialize_odoo(args, client_name, db_name):
    """Initialize Odoo with the new database"""
    container_name = f"arcweb_{client_name}"
    
    # Wait for Odoo container to be up
    print(f"Waiting for {container_name} to be available...")
    
    # Initialize database
    command = [
        "docker", "exec", container_name,
        "odoo", "--stop-after-init",
        "--db_host", args.db_host,
        "--db_port", args.db_port,
        "--db_user", args.db_user,
        "--db_password", args.db_password,
        "-d", db_name,
        "-i", "base",
        "--without-demo=all",
        "--load-language", "en_US"
    ]
    
    print(f"Initializing Odoo database {db_name} in container {container_name}")
    subprocess.run(command, check=True)
    
    # Determine modules to install based on client name
    if client_name == "main":
        modules = "web,website,website_sale"
    else:
        # Get client number
        client_num = client_name.replace("client", "")
        modules = f"web,website,website_sale,arcweb_base,arcweb_ecommerce,theme_arcweb,client{client_num}_custom,client{client_num}_website"
    
    command = [
        "docker", "exec", container_name,
        "odoo", "--stop-after-init",
        "--db_host", args.db_host,
        "--db_port", args.db_port,
        "--db_user", args.db_user,
        "--db_password", args.db_password,
        "-d", db_name,
        "-i", modules
    ]
    
    print(f"Installing modules for {db_name} in container {container_name}")
    subprocess.run(command, check=True)
    
    # Set domain name in system parameters
    domain = "arcweb.com.au" if client_name == "main" else f"{client_name}.arcweb.com.au"
    update_domain_command = [
        "docker", "exec", container_name,
        "psql", "-h", args.db_host, 
        "-p", args.db_port,
        "-U", args.db_user,
        "-d", db_name,
        "-c", f"UPDATE ir_config_parameter SET value='{domain}' WHERE key='web.base.url'"
    ]
    
    print(f"Setting domain {domain} for {db_name}")
    subprocess.run(update_domain_command, check=True)
    
    print(f"Odoo initialization for {db_name} in container {container_name} completed successfully!")

def main():
    parser = argparse.ArgumentParser(description='Initialize Odoo databases for multiple clients')
    parser.add_argument('--db_host', required=True, help='Database host')
    parser.add_argument('--db_port', required=True, help='Database port')
    parser.add_argument('--db_user', required=True, help='Database user')
    parser.add_argument('--db_password', required=True, help='Database password')
    parser.add_argument('--init_main', action='store_true', help='Initialize main website')
    parser.add_argument('--client', help='Specific client to initialize (e.g., client1)')
    parser.add_argument('--all_clients', action='store_true', help='Initialize all clients')
    
    args = parser.parse_args()
    
    # Initialize main website if requested
    if args.init_main:
        db_name = create_database(args, "main")
        initialize_odoo(args, "main", db_name)
    
    # Initialize specific client if requested
    if args.client:
        db_name = create_database(args, args.client)
        initialize_odoo(args, args.client, db_name)
    
    # Initialize all clients if requested
    if args.all_clients:
        for i in range(1, 11):
            client_name = f"client{i}"
            db_name = create_database(args, client_name)
            initialize_odoo(args, client_name, db_name)

if __name__ == "__main__":
    main()
