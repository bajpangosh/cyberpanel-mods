#!/bin/bash

# AntiGravity CyberPanel MariaDB Tuneup Script for High Traffic WooCommerce
# Version 1.2 - Authenticated Checks & Specific Path Handling

# ----------------------------------------------------------------------
# COLORS
# ----------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ----------------------------------------------------------------------
# CHECK ROOT
# ----------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root.${NC}"
   exit 1
fi

# ----------------------------------------------------------------------
# FETCH CREDENTIALS
# ----------------------------------------------------------------------
# As requested: Read root password from CyberPanel specific path
MYSQL_PASS_FILE="/etc/cyberpanel/mysqlPassword"
DB_USER="root"
DB_PASS=""

if [[ -f "$MYSQL_PASS_FILE" ]]; then
    DB_PASS=$(cat "$MYSQL_PASS_FILE")
    echo -e "${GREEN}Found MySQL password in ${MYSQL_PASS_FILE}.${NC}"
else
    echo -e "${YELLOW}Warning: ${MYSQL_PASS_FILE} not found. Assuming passwordless or socket auth.${NC}"
fi

# Verify Login Function
check_db_connection() {
    if [[ -n "$DB_PASS" ]]; then
         mysql -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1;" &> /dev/null
    else
         mysql -u "$DB_USER" -e "SELECT 1;" &> /dev/null
    fi
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Database connection successful.${NC}"
        return 0
    else
        echo -e "${RED}Error: Cannot connect to MariaDB with provided credentials.${NC}"
        echo -e "${RED}Please check /etc/cyberpanel/mysqlPassword.${NC}"
        # We proceed anyway because we are editing config files, not querying data,
        # but it's good to warn.
        return 1
    fi
}
check_db_connection

# ----------------------------------------------------------------------
# DETECT OS & PATHS
# ----------------------------------------------------------------------
check_OS() {
    if [[ -f /etc/os-release ]]; then
        if grep -q "Ubuntu" /etc/os-release; then
            Server_OS="Ubuntu"
        elif grep -q "CentOS" /etc/os-release; then
            Server_OS="CentOS"
        elif grep -q "AlmaLinux" /etc/os-release; then
            Server_OS="AlmaLinux"
        else
            Server_OS="Linux"
        fi
    else
        Server_OS="Linux"
    fi
}
check_OS

# ----------------------------------------------------------------------
# DETERMINE CONFIG CONFIGURATION
# ----------------------------------------------------------------------
# User specified path: /etc/mysql/mariadb.conf.d/50-server.cnf
USER_SPECIFIED_PATH="/etc/mysql/mariadb.conf.d/50-server.cnf"

# Intelligent path selection
WRITE_MODE="OVERRIDE" 
# OVERRIDE = Create a 99- file to override settings (Cleaner, safer)
# APPEND = Append to the main file

if [[ -f "$USER_SPECIFIED_PATH" ]]; then
    MAIN_CONFIG="$USER_SPECIFIED_PATH"
    # Since this is a .d directory, we should create a sibling file for overrides
    # to avoid modifying the package-maintained 50-server.cnf directly.
    CONF_DIR=$(dirname "$USER_SPECIFIED_PATH")
    TARGET_CONFIG="${CONF_DIR}/99-cyberpanel-tuneup.cnf"
    echo -e "${BLUE}Detected Main Config: ${MAIN_CONFIG}${NC}"
    echo -e "${BLUE}Targeting Override File: ${TARGET_CONFIG}${NC}"
elif [[ -d "/etc/mysql/mariadb.conf.d" ]]; then
    TARGET_CONFIG="/etc/mysql/mariadb.conf.d/99-cyberpanel-tuneup.cnf"
    MAIN_CONFIG="/etc/mysql/my.cnf" # Fallback for backup
elif [[ -d "/etc/my.cnf.d" ]]; then
    TARGET_CONFIG="/etc/my.cnf.d/cyberpanel-tuneup.cnf"
    MAIN_CONFIG="/etc/my.cnf"
else
    # Fallback to appending to /etc/my.cnf
    TARGET_CONFIG="/etc/my.cnf"
    MAIN_CONFIG="/etc/my.cnf"
    WRITE_MODE="APPEND"
fi

# ----------------------------------------------------------------------
# MEMORY DETECTION & CALCULATION
# ----------------------------------------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

echo -e "${YELLOW}Detected RAM:${NC} ${TOTAL_RAM_MB} MB (${TOTAL_RAM_GB} GB)"

# ----------------------------------------------------------------------
# TUNING LOGIC
# ----------------------------------------------------------------------
# For Shared/CyberPanel environments (Web + DB on same node)
# Standard recommendation: 40-50% for InnoDB Buffer Pool.

if [ $TOTAL_RAM_MB -lt 2048 ]; then
    # < 2GB
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 30 / 100))M
    MAX_CONNECTIONS=80
    INNODB_LOG_FILE_SIZE=64M
elif [ $TOTAL_RAM_MB -lt 4096 ]; then
    # 2GB - 4GB
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 40 / 100))M
    MAX_CONNECTIONS=150
    INNODB_LOG_FILE_SIZE=128M
elif [ $TOTAL_RAM_MB -lt 8192 ]; then
    # 4GB - 8GB
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 50 / 100))M
    MAX_CONNECTIONS=300
    INNODB_LOG_FILE_SIZE=256M
elif [ $TOTAL_RAM_MB -lt 16384 ]; then
    # 8GB - 16GB
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 55 / 100))M
    MAX_CONNECTIONS=500
    INNODB_LOG_FILE_SIZE=512M
elif [ $TOTAL_RAM_MB -lt 32768 ]; then
    # 16GB - 32GB
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 60 / 100))M
    MAX_CONNECTIONS=800
    INNODB_LOG_FILE_SIZE=1G
else
    # 32GB+
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 65 / 100))M
    MAX_CONNECTIONS=1200
    INNODB_LOG_FILE_SIZE=2G
fi

# WooCommerce Specific Optimization
QUERY_CACHE_TYPE=0      # Disable Query Cache (Lock contention in high write/update scenarios)
QUERY_CACHE_SIZE=0
KEY_BUFFER_SIZE=32M             
TMP_TABLE_SIZE=128M     # Complex Woo queries often use temp tables         
MAX_HEAP_TABLE_SIZE=128M
TABLE_OPEN_CACHE=4000
TABLE_DEF_CACHE=4000
INNODB_FLUSH_LOG_TRX_COMMIT=2    # 2 = Write to OS cache on commit, flush to disk every 1s. Critical for speed.
INNODB_FLUSH_METHOD=O_DIRECT
INNODB_FILE_PER_TABLE=1
CONNECT_TIMEOUT=15
WAIT_TIMEOUT=600
INTERACTIVE_TIMEOUT=600
MAX_ALLOWED_PACKET=64M
OPEN_FILES_LIMIT=65535

# ----------------------------------------------------------------------
# PREVIEW
# ----------------------------------------------------------------------
echo -e "${BLUE}Proposed Settings:${NC}"
echo -e " - innodb_buffer_pool_size: ${GREEN}${INNODB_BUFFER_POOL_SIZE}${NC}"
echo -e " - innodb_log_file_size:    ${GREEN}${INNODB_LOG_FILE_SIZE}${NC}"
echo -e " - max_connections:         ${GREEN}${MAX_CONNECTIONS}${NC}"
echo -e " - innodb_flush_log_at_trx_commit: ${GREEN}2${NC}"
echo -e ""
echo -e "Writing to: ${YELLOW}${TARGET_CONFIG}${NC}"

if [[ "$1" != "-y" ]]; then
    read -p "Do you want to proceed? (y/n): " PROCEED
    if [[ "$PROCEED" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ----------------------------------------------------------------------
# BACKUP & WRITE
# ----------------------------------------------------------------------
# Backup the MAIN config just in case, even if we assume we are writing to a new file
if [[ -f "$MAIN_CONFIG" ]]; then
    BACKUP_NAME="${MAIN_CONFIG}.backup.$(date +%F_%T)"
    cp "$MAIN_CONFIG" "$BACKUP_NAME"
    echo -e "${GREEN}Backup of main config created: ${BACKUP_NAME}${NC}"
fi

# If we are overwriting an existing override file, backup that too
if [[ "$WRITE_MODE" == "OVERRIDE" && -f "$TARGET_CONFIG" ]]; then
      cp "$TARGET_CONFIG" "${TARGET_CONFIG}.backup.$(date +%F_%T)"
fi

CONFIG_CONTENT="# -----------------------------------------
# CYBERPANEL WOOCOMMERCE TUNEUP
# Generated by AntiGravity on $(date)
# -----------------------------------------
[mysqld]
# InnoDB Settings
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE}
innodb_log_file_size = ${INNODB_LOG_FILE_SIZE}
innodb_file_per_table = 1
innodb_flush_method = ${INNODB_FLUSH_METHOD}
innodb_flush_log_at_trx_commit = ${INNODB_FLUSH_LOG_TRX_COMMIT}
innodb_io_capacity = 1000
innodb_io_capacity_max = 2000

# Connection Settings
max_connections = ${MAX_CONNECTIONS}
skip-name-resolve
wait_timeout = ${WAIT_TIMEOUT}
interactive_timeout = ${INTERACTIVE_TIMEOUT}

# Buffers & Caches
key_buffer_size = ${KEY_BUFFER_SIZE}
query_cache_type = ${QUERY_CACHE_TYPE}
query_cache_size = ${QUERY_CACHE_SIZE}
tmp_table_size = ${TMP_TABLE_SIZE}
max_heap_table_size = ${MAX_HEAP_TABLE_SIZE}
table_open_cache = ${TABLE_OPEN_CACHE}
table_definition_cache = ${TABLE_DEF_CACHE}

# Performance
thread_cache_size = 50
open_files_limit = ${OPEN_FILES_LIMIT}
max_allowed_packet = ${MAX_ALLOWED_PACKET}
"

if [[ "$WRITE_MODE" == "APPEND" ]]; then
     echo -e "\n${CONFIG_CONTENT}" >> "$TARGET_CONFIG"
else
     echo "$CONFIG_CONTENT" > "$TARGET_CONFIG"
fi

echo -e "${GREEN}Configuration written to ${TARGET_CONFIG}${NC}"

# ----------------------------------------------------------------------
# RESTART SERVICE
# ----------------------------------------------------------------------
# Try to restart mariadb
echo -e "${BLUE}Restarting MariaDB...${NC}"
systemctl restart mariadb

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}Success! MariaDB is running with new settings.${NC}"
else
    echo -e "${RED}Failed to restart MariaDB.${NC}"
    echo -e "${YELLOW}Attempting to verify config...${NC}"
    # Verify process is dead or alive
    systemctl status mariadb --no-pager
    
    echo -e "${RED}Reverting changes...${NC}"
    if [[ "$WRITE_MODE" == "APPEND" ]]; then
        # This is hard to revert automatically without risky logic, so we restore backup
        cp "$BACKUP_NAME" "$MAIN_CONFIG"
    else
        rm "$TARGET_CONFIG"
    fi
    systemctl restart mariadb
    echo -e "${YELLOW}Reverted. Please check logs.${NC}"
fi
