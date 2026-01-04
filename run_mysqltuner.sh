#!/bin/bash

# AntiGravity CyberPanel MariaDB Ultimate Optimizer
# Version 2.1 - Combined Analyzer & Auto-Tuner (Support for 64GB+ RAM)

# ----------------------------------------------------------------------
# COLORS
# ----------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ----------------------------------------------------------------------
# CHECK ROOT
# ----------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root.${NC}"
   exit 1
fi

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}      CyberPanel MariaDB Ultimate Optimizer (Analysis + Fix)    ${NC}"
echo -e "${BLUE}================================================================${NC}"

# ----------------------------------------------------------------------
# 1. SETUP & CREDENTIALS
# ----------------------------------------------------------------------
MYSQL_PASS_FILE="/etc/cyberpanel/mysqlPassword"
DB_USER="root"
DB_PASS=""

if [[ -f "$MYSQL_PASS_FILE" ]]; then
    DB_PASS=$(cat "$MYSQL_PASS_FILE")
    echo -e "${GREEN}✔ Found MariaDB password.${NC}"
else
    echo -e "${YELLOW}⚠ Password file not found. Will attempt passwordless login.${NC}"
fi

check_OS() {
    if [[ -f /etc/os-release ]]; then
        if grep -q "Ubuntu" /etc/os-release; then Server_OS="Ubuntu"
        elif grep -q "CentOS" /etc/os-release; then Server_OS="CentOS"
        elif grep -q "AlmaLinux" /etc/os-release; then Server_OS="AlmaLinux"
        else Server_OS="Linux"; fi
    else Server_OS="Linux"; fi
}
check_OS

# ----------------------------------------------------------------------
# 2. RUN MYSQLTUNER
# ----------------------------------------------------------------------
TUNER_PATH="/usr/local/bin/mysqltuner.pl"

echo -e "${BLUE}[Phase 1] Analyzing Database Health...${NC}"
if [[ ! -f "$TUNER_PATH" ]]; then
    echo -e "Downloading MySQLTuner..."
    wget -q -O "$TUNER_PATH" "http://mysqltuner.pl/mysqltuner.pl"
    chmod +x "$TUNER_PATH"
fi

TEMP_CNF=$(mktemp)
echo "[client]" > "$TEMP_CNF"
echo "user=$DB_USER" >> "$TEMP_CNF"
if [[ -n "$DB_PASS" ]]; then echo "password=$DB_PASS" >> "$TEMP_CNF"; fi

TUNER_OUTPUT_FILE="/tmp/mysqltuner_result.txt"
export MYSQL_PWD="$DB_PASS"
perl "$TUNER_PATH" --user "$DB_USER" --pass "$DB_PASS" --nocolor > "$TUNER_OUTPUT_FILE"

# Show Results
echo -e "\n${BLUE}=== ANALYSIS REPORT ===${NC}"
grep -E "\[!!\]|\[OK\]" "$TUNER_OUTPUT_FILE" | grep -E "Total buffers|Maximum possible memory|InnoDB buffer pool|Ratio|fragmented" 
echo -e "${YELLOW}Full report saved to: ${TUNER_OUTPUT_FILE}${NC}\n"

# Remove temp credentials
rm "$TEMP_CNF" 2>/dev/null

# ----------------------------------------------------------------------
# 3. ASK TO TUNE
# ----------------------------------------------------------------------
echo -e "${BLUE}[Phase 2] Optimization${NC}"
echo -e "We can now apply optimal settings for your specific RAM and WooCommerce traffic."
echo -e "This will:"
echo -e "  1. Config Optimal Buffer Pool (40-70% RAM)"
echo -e "  2. Disable Query Cache (Critical for Woo)"
echo -e "  3. Set unsafe-but-fast commit logic (Speed up Checkout)"
echo -e ""

read -p "Do you want to apply these fixes now? (y/n): " APPLY
if [[ "$APPLY" != "y" ]]; then
    echo "Exiting without changes."
    exit 0
fi

# ----------------------------------------------------------------------
# 4. TUNING LOGIC (With 64GB+ Support)
# ----------------------------------------------------------------------

# CALCULATION
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))

echo -e "${YELLOW}Detected RAM:${NC} ${TOTAL_RAM_MB} MB (${TOTAL_RAM_GB} GB)"

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
elif [ $TOTAL_RAM_MB -lt 49152 ]; then
    # 32GB - 48GB
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 65 / 100))M
    MAX_CONNECTIONS=1200
    INNODB_LOG_FILE_SIZE=2G
else
    # 48GB+ (Includes 64GB, 128GB...)
    # For large memory servers, we can safely allocate 70% to DB if web server load is managed
    INNODB_BUFFER_POOL_SIZE=$((TOTAL_RAM_MB * 70 / 100))M
    MAX_CONNECTIONS=2000
    # 2GB Log File is generally safe standard. 
    INNODB_LOG_FILE_SIZE=2G
fi

# CONFIG PATH SELECTION
USER_SPECIFIED_PATH="/etc/mysql/mariadb.conf.d/50-server.cnf"
WRITE_MODE="OVERRIDE"

if [[ -f "$USER_SPECIFIED_PATH" ]]; then
    MAIN_CONFIG="$USER_SPECIFIED_PATH"
    CONF_DIR=$(dirname "$USER_SPECIFIED_PATH")
    TARGET_CONFIG="${CONF_DIR}/99-cyberpanel-tuneup.cnf"
elif [[ -d "/etc/mysql/mariadb.conf.d" ]]; then
    TARGET_CONFIG="/etc/mysql/mariadb.conf.d/99-cyberpanel-tuneup.cnf"
    MAIN_CONFIG="/etc/mysql/my.cnf"
elif [[ -d "/etc/my.cnf.d" ]]; then
    TARGET_CONFIG="/etc/my.cnf.d/cyberpanel-tuneup.cnf"
    MAIN_CONFIG="/etc/my.cnf"
else
    TARGET_CONFIG="/etc/my.cnf"
    MAIN_CONFIG="/etc/my.cnf"
    WRITE_MODE="APPEND"
fi

# BACKUP
if [[ -f "$MAIN_CONFIG" ]]; then cp "$MAIN_CONFIG" "${MAIN_CONFIG}.backup.$(date +%F_%T)"; fi
if [[ "$WRITE_MODE" == "OVERRIDE" && -f "$TARGET_CONFIG" ]]; then cp "$TARGET_CONFIG" "${TARGET_CONFIG}.backup.$(date +%F_%T)"; fi

# WRITE CONFIG
CONFIG_CONTENT="# -----------------------------------------
# CYBERPANEL WOOCOMMERCE TUNEUP
# Generated by AntiGravity on $(date)
# -----------------------------------------
[mysqld]
# InnoDB Settings
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_SIZE}
innodb_log_file_size = ${INNODB_LOG_FILE_SIZE}
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000

# Connection Settings
max_connections = ${MAX_CONNECTIONS}
skip-name-resolve
wait_timeout = 600
interactive_timeout = 600

# Buffers & Caches
key_buffer_size = 64M
query_cache_type = 0
query_cache_size = 0
tmp_table_size = 256M
max_heap_table_size = 256M
table_open_cache = 8000
table_definition_cache = 8000

# Performance
thread_cache_size = 100
open_files_limit = 65535
max_allowed_packet = 128M
"

if [[ "$WRITE_MODE" == "APPEND" ]]; then
     echo -e "\n${CONFIG_CONTENT}" >> "$TARGET_CONFIG"
else
     echo "$CONFIG_CONTENT" > "$TARGET_CONFIG"
fi

echo -e "${GREEN}✔ Configuration optimized and saved to ${TARGET_CONFIG}${NC}"

# RESTART
echo -e "${BLUE}Restarting MariaDB...${NC}"
systemctl restart mariadb

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}SUCCESS! Database is tuned and running.${NC}"
    echo -e "${BLUE}Detected 64GB+ Settings Applied? $([ $TOTAL_RAM_MB -gt 48000 ] && echo 'Yes' || echo 'No (Lower RAM Detected)') ${NC}"
else
    echo -e "${RED}FAILED to restart. Reverting...${NC}"
    if [[ "$WRITE_MODE" == "APPEND" ]]; then
        cp "${MAIN_CONFIG}.backup.*" "$MAIN_CONFIG" 
    else
        rm "$TARGET_CONFIG"
    fi
    systemctl restart mariadb
    echo -e "${YELLOW}Reverted changes.${NC}"
fi
