#!/bin/bash

# AntiGravity CyberPanel MariaDB Tuneup Script for High Traffic WooCommerce
# Version 1.1 - Robust OS Detection & Pathing

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
# DETECT OS (Borrowed from CyberPanel Utility)
# ----------------------------------------------------------------------
check_OS() {
    if [[ ! -f /etc/os-release ]] ; then
        echo -e "${RED}Unable to detect the operating system...${NC}"
        exit 1
    fi

    if grep -q -E "CentOS Linux 7|CentOS Linux 8|CentOS Stream" /etc/os-release ; then
        Server_OS="CentOS"
    elif grep -q "Red Hat Enterprise Linux" /etc/os-release ; then
        Server_OS="RedHat"
    elif grep -q "AlmaLinux" /etc/os-release ; then
        Server_OS="AlmaLinux"
    elif grep -q "CloudLinux" /etc/os-release ; then
        Server_OS="CloudLinux"
    elif grep -q "Ubuntu" /etc/os-release ; then
        Server_OS="Ubuntu"
    elif grep -q "Rocky Linux" /etc/os-release ; then
        Server_OS="RockyLinux"
    elif grep -q "openEuler" /etc/os-release ; then
        Server_OS="openEuler"
    else
        Server_OS="Unknown"
    fi
    echo -e "${BLUE}Detected OS: ${Server_OS}${NC}"
}
check_OS

# ----------------------------------------------------------------------
# MEMORY DETECTION & CALCULATION
# ----------------------------------------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

echo -e "${YELLOW}Detected RAM:${NC} ${TOTAL_RAM_MB} MB (${TOTAL_RAM_GB} GB)"

# For a shared web/db server (CyberPanel), we don't want to use 80% RAM for DB.
# We'll aim for about 40-50% for InnoDB Buffer Pool.
# If you have a dedicated DB server, increase these manually.

if [ $TOTAL_RAM_MB -lt 2048 ]; then
    # < 2GB: Conservative
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
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 50 / 100))M
    MAX_CONNECTIONS=500
    INNODB_LOG_FILE_SIZE=512M
elif [ $TOTAL_RAM_MB -lt 32768 ]; then
    # 16GB - 32GB
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 60 / 100))M
    MAX_CONNECTIONS=800
    INNODB_LOG_FILE_SIZE=1G
else
    # 32GB+
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 60 / 100))M
    MAX_CONNECTIONS=1000
    INNODB_LOG_FILE_SIZE=2G
fi

# Common Optimization Variables for WooCommerce
QUERY_CACHE_TYPE=0
QUERY_CACHE_SIZE=0
KEY_BUFFER_SIZE=32M             
TMP_TABLE_SIZE=128M              
MAX_HEAP_TABLE_SIZE=128M
TABLE_OPEN_CACHE=4000
TABLE_DEF_CACHE=4000
INNODB_FLUSH_LOG_TRX_COMMIT=2    
INNODB_FLUSH_METHOD=O_DIRECT
INNODB_FILE_PER_TABLE=1
CONNECT_TIMEOUT=10
WAIT_TIMEOUT=600
INTERACTIVE_TIMEOUT=600
MAX_ALLOWED_PACKET=64M
OPEN_FILES_LIMIT=65535

# ----------------------------------------------------------------------
# DETERMINE CONFIG LOCATION
# ----------------------------------------------------------------------
# Prioritize clean includes in conf.d directories if they exist
TARGET_CONF=""
MAIN_MY_CNF=""

# Find main config first for backup purposes
if [[ -f "/etc/my.cnf" ]]; then
    MAIN_MY_CNF="/etc/my.cnf"
elif [[ -f "/etc/mysql/my.cnf" ]]; then
    MAIN_MY_CNF="/etc/mysql/my.cnf"
fi

if [[ -z "$MAIN_MY_CNF" ]]; then
    echo -e "${RED}Critical: Could not find my.cnf in standard locations!${NC}"
    exit 1
fi

# Determine where to write the tuneup config
if [[ "$Server_OS" == "Ubuntu" || "$Server_OS" == "Debian" ]]; then
    # Ubuntu usually has /etc/mysql/conf.d/ or /etc/mysql/mariadb.conf.d/
    if [[ -d "/etc/mysql/mariadb.conf.d" ]]; then
        TARGET_CONF="/etc/mysql/mariadb.conf.d/99-cyberpanel-tuneup.cnf"
    elif [[ -d "/etc/mysql/conf.d" ]]; then
        TARGET_CONF="/etc/mysql/conf.d/99-cyberpanel-tuneup.cnf"
    fi
elif [[ "$Server_OS" == "CentOS" || "$Server_OS" == "AlmaLinux" || "$Server_OS" == "RockyLinux" || "$Server_OS" == "CloudLinux" ]]; then
    # RHEL based usually has /etc/my.cnf.d/
    if [[ -d "/etc/my.cnf.d" ]]; then
        TARGET_CONF="/etc/my.cnf.d/cyberpanel-tuneup.cnf"
    fi
fi

# Fallback: If no distinct directory found, append to main config
if [[ -z "$TARGET_CONF" ]]; then
    TARGET_CONF="$MAIN_MY_CNF"
    APPEND_MODE=true
else
    APPEND_MODE=false
fi

# ----------------------------------------------------------------------
# PREVIEW
# ----------------------------------------------------------------------
echo -e "${BLUE}Proposed Settings:${NC}"
echo -e " - innodb_buffer_pool_size: ${GREEN}${INNODB_BUFFER_POOL_SIZE}${NC}"
echo -e " - innodb_log_file_size:    ${GREEN}${INNODB_LOG_FILE_SIZE}${NC}"
echo -e " - max_connections:         ${GREEN}${MAX_CONNECTIONS}${NC}"
echo -e " - Target Config File:      ${YELLOW}${TARGET_CONF}${NC}"
echo -e ""

if [[ "$1" != "-y" ]]; then
    read -p "Do you want to proceed? (y/n): " PROCEED
    if [[ "$PROCEED" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ----------------------------------------------------------------------
# BACKUP
# ----------------------------------------------------------------------
BACKUP_FILE="${MAIN_MY_CNF}.backup.$(date +%F_%T)"
cp "$MAIN_MY_CNF" "$BACKUP_FILE"
echo -e "${GREEN}Main config backed up to ${BACKUP_FILE}${NC}"

if [[ "$APPEND_MODE" == "false" && -f "$TARGET_CONF" ]]; then
    cp "$TARGET_CONF" "${TARGET_CONF}.backup.$(date +%F_%T)"
fi

# ----------------------------------------------------------------------
# GENERATE CONTENT
# ----------------------------------------------------------------------
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

# ----------------------------------------------------------------------
# APPLY CONFIG
# ----------------------------------------------------------------------
if [[ "$APPEND_MODE" == "true" ]]; then
    # Check if we already added it
    if grep -q "CYBERPANEL WOOCOMMERCE TUNEUP" "$TARGET_CONF"; then
        echo -e "${YELLOW}Tuneup block found in main config. Appending new block anyway (last entry wins).${NC}"
    fi
    echo -e "\n${CONFIG_CONTENT}" >> "$TARGET_CONF"
else
    echo -e "${BLUE}Writing dedicated config file: ${TARGET_CONF}${NC}"
    echo "$CONFIG_CONTENT" > "$TARGET_CONF"
fi

# ----------------------------------------------------------------------
# RESTART SERVICE
# ----------------------------------------------------------------------
SERVICE_NAME="mariadb"
if ! systemctl list-unit-files | grep -q mariadb.service; then
    if systemctl list-unit-files | grep -q mysql.service; then
        SERVICE_NAME="mysql"
    fi
fi

echo -e "${BLUE}Restarting ${SERVICE_NAME}...${NC}"
systemctl restart "$SERVICE_NAME"

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}Success! ${SERVICE_NAME} restarted with new settings.${NC}"
    echo -e "${BLUE}Optimized for high-traffic WooCommerce.${NC}"
else
    echo -e "${RED}${SERVICE_NAME} failed to restart! Reverting changes...${NC}"
    
    # Revert logic
    if [[ "$APPEND_MODE" == "true" ]]; then
        cp "$BACKUP_FILE" "$MAIN_MY_CNF"
    else
        rm "$TARGET_CONF"
        # If there was a previous version of the target file, we might want to restore it,
        # but usually we are creating a NEW file. If we overwrote an existing one, verify backup.
        # Simple revert: remove the file causing issues.
    fi
    
    systemctl restart "$SERVICE_NAME"
    echo -e "${YELLOW}Changes reverted. Check /var/log/mysql/error.log or journalctl -xe.${NC}"
    exit 1
fi
