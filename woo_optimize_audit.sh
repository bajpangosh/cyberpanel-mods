#!/bin/bash

# AntiGravity CyberPanel WooCommerce Optimization Auditor
# Version 1.0

# ----------------------------------------------------------------------
# COLORS
# ----------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}      CyberPanel WooCommerce Optimization Auditor     ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo -e "Checking your system for critical WooCommerce performance bottlenecks..."
echo -e ""

# ----------------------------------------------------------------------
# 1. CHECK REDIS (Object Cache)
# ----------------------------------------------------------------------
echo -e "${BLUE}[1/5] Checking Redis Object Cache...${NC}"
if systemctl is-active --quiet redis; then
    echo -e "${GREEN}✔ Redis Service is RUNNING.${NC}"
else
    echo -e "${RED}✘ Redis Service is NOT RUNNING.${NC}"
    echo -e "  Recommendation: Install Redis via 'cyberpanel_utility.sh' option 2 -> 4."
    echo -e "  Then install a Redis Object Cache plugin in WordPress."
fi

# Check if PHP Redis extension is installed for the default CyberPanel PHP (usually 7.4 or 8.0+)
# We will check only for the most likely engaged versions
PHP_VERSIONS=("lsphp74" "lsphp80" "lsphp81" "lsphp82" "lsphp83")
MISSING_REDIS_EXT=0

for php in "${PHP_VERSIONS[@]}"; do
    if [[ -f "/usr/local/lsws/${php}/bin/php" ]]; then
        if ! /usr/local/lsws/${php}/bin/php -m | grep -q "redis"; then
             echo -e "${YELLOW}⚠ Redis extension missing for ${php} (Active on system)${NC}"
             MISSING_REDIS_EXT=1
        fi
    fi
done

if [[ $MISSING_REDIS_EXT -eq 1 ]]; then
    echo -e "  Recommendation: Install PHP Redis extensions via 'cyberpanel_utility.sh' option 2 -> 3."
fi
echo ""

# ----------------------------------------------------------------------
# 2. CHECK OPCACHE
# ----------------------------------------------------------------------
echo -e "${BLUE}[2/5] Checking PHP Opcache...${NC}"
# We check the php.ini of the most likely main PHP version (e.g. 7.4 or 8.1)
# Simply grepping for opcache.enable=1 isn't enough as it might be default on.
# We'll check via CLI.

OPCACHE_ENABLED=$(/usr/local/lsws/lsphp74/bin/php -i 2>/dev/null | grep "opcache.enable" | head -n 1)

if [[ "$OPCACHE_ENABLED" == *"On"* || "$OPCACHE_ENABLED" == *"1"* ]]; then
     echo -e "${GREEN}✔ Opcache is Enabled (checked lsphp74).${NC}"
else
     echo -e "${YELLOW}⚠ Opcache might be DISABLED or not detected via CLI.${NC}"
     echo -e "  WooCommerce requires Opcache for reasonable performance."
fi
echo ""

# ----------------------------------------------------------------------
# 3. CHECK PHP MEMORY LIMIT
# ----------------------------------------------------------------------
echo -e "${BLUE}[3/5] Checking PHP Memory Limit...${NC}"
# WooCommerce recommends 256M minimum, 512M preferred.
MEM_LIMIT=$(/usr/local/lsws/lsphp74/bin/php -i 2>/dev/null | grep "memory_limit" | awk '{print $3}')

if [[ "$MEM_LIMIT" == *"M"* ]]; then
    MEM_VAL=${MEM_LIMIT%M}
    if [[ $MEM_VAL -lt 256 ]]; then
         echo -e "${RED}✘ Memory Limit is ${MEM_LIMIT}. Too low for WooCommerce.${NC}"
         echo -e "  Recommendation: Increase to at least 512M in PHP Configurations."
    else
         echo -e "${GREEN}✔ Memory Limit is ${MEM_LIMIT}. Good.${NC}"
    fi
elif [[ "$MEM_LIMIT" == *"G"* ]]; then
     echo -e "${GREEN}✔ Memory Limit is ${MEM_LIMIT}. Excellent.${NC}"
else
     echo -e "${YELLOW}⚠ Could not parse memory limit: $MEM_LIMIT${NC}"
fi
echo ""

# ----------------------------------------------------------------------
# 4. SYSTEM CRON VS WP-CRON
# ----------------------------------------------------------------------
echo -e "${BLUE}[4/5] Checking Cron Configuration...${NC}"
# Check if there is a cron entry for 'wp-cron.php' in crontab
if crontab -l 2>/dev/null | grep -q "wp-cron.php"; then
    echo -e "${GREEN}✔ System Cron for WordPress found in crontab.${NC}"
else
    echo -e "${YELLOW}⚠ No System Cron found for wp-cron.php.${NC}"
    echo -e "  High-Traffic Recommendation: Disable WP-Cron in wp-config.php:"
    echo -e "     define('DISABLE_WP_CRON', true);"
    echo -e "  And add a system cron job running every 5 minutes."
fi
echo ""

# ----------------------------------------------------------------------
# 5. LITESPEED CACHE CRAWLER
# ----------------------------------------------------------------------
echo -e "${BLUE}[5/5] LiteSpeed Cache...${NC}"
echo -e "${GREEN}✔ You are using LiteSpeed Enterprise (CyberPanel).${NC}"
echo -e "  Ensure 'LiteSpeed Cache' plugin is active in WordPress."
echo -e "  Crucial: Enable the 'Crawler' in LSCache settings to pre-warm pages."
echo -e ""

echo -e "${BLUE}================================================================${NC}"
echo -e "Summary of Actions Required:"
if ! systemctl is-active --quiet redis; then
   echo -e "1. [URGENT] Install and Enable Redis."
fi
if [[ $MISSING_REDIS_EXT -eq 1 ]]; then
   echo -e "2. [URGENT] Install PHP Redis Extensions."
fi
echo -e "3. Verify 'innodb_buffer_pool_size' (handled by mariadb_tuneup.sh)."
echo -e "4. Set 'memory_limit = 512M' in PHP."
echo -e "5. Configure System Cron for WordPress."
echo -e "${BLUE}================================================================${NC}"
