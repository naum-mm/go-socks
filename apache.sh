#!/bin/bash

# ============================================
# Apache HTTP Server Setup Script
# Настройка веб-сервера для раздачи конфигов и QR кодов
# Версия: 2.1 (с управлением сервисом)
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Apache HTTP Server - Настройка${NC}"
echo -e "${GREEN}========================================${NC}"

# Global variables
OS=""
APACHE_SERVICE=""
APACHE_CONFIG_DIR=""
APACHE_USER=""
APACHE_GROUP=""
RANDOM_LINK=""
RANDOM_PORT=""
PROXY_CONFIG_DIR="/root/proxy_configs"
WEB_PROXY_DIR="/var/www/proxy_configs"
CONFIG_FILE=""
BACKUP_DIR="/root/apache_backups"

# Load proxy types from install_info
PROXY_TYPES=()
load_proxy_types() {
    if [ -f "$PROXY_CONFIG_DIR/install_info.txt" ]; then
        PROXY_TYPES_STR=$(grep "Установленные прокси:" "$PROXY_CONFIG_DIR/install_info.txt" | sed 's/.*: //')
        if [ -n "$PROXY_TYPES_STR" ]; then
            read -ra PROXY_TYPES <<< "$PROXY_TYPES_STR"
        fi
    fi
    
    # Default if not found
    if [ ${#PROXY_TYPES[@]} -eq 0 ]; then
        PROXY_TYPES=("socks5" "stunnel" "gost")
    fi
}

# Detect OS and set Apache variables
detect_os() {
    echo -e "${GREEN}Определение операционной системы...${NC}"
    
    if [ -f /etc/redhat-release ]; then
        OS="centos"
        APACHE_SERVICE="httpd"
        APACHE_CONFIG_DIR="/etc/httpd"
        APACHE_USER="apache"
        APACHE_GROUP="apache"
        CONFIG_FILE="$APACHE_CONFIG_DIR/conf.d/proxy_config.conf"
        echo -e "${GREEN}Обнаружен CentOS/RHEL${NC}"
    elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
        OS="ubuntu"
        APACHE_SERVICE="apache2"
        APACHE_CONFIG_DIR="/etc/apache2"
        APACHE_USER="www-data"
        APACHE_GROUP="www-data"
        CONFIG_FILE="$APACHE_CONFIG_DIR/sites-available/proxy_config.conf"
        echo -e "${GREEN}Обнаружен Ubuntu/Debian${NC}"
    else
        echo -e "${RED}Не удалось определить ОС${NC}"
        exit 1
    fi
}

# ============================================
# НОВЫЕ ФУНКЦИИ УПРАВЛЕНИЯ
# ============================================

# Check if web interface is enabled
is_web_enabled() {
    if [ -f "$CONFIG_FILE" ] && [ -L "$CONFIG_FILE" ] || [ -f "$CONFIG_FILE" ]; then
        # For Ubuntu, check if site is enabled
        if [ "$OS" = "ubuntu" ]; then
            if [ -L "$APACHE_CONFIG_DIR/sites-enabled/proxy_config.conf" ]; then
                return 0
            fi
        else
            # For CentOS, just check if config file exists
            return 0
        fi
    fi
    return 1
}

# Save current configuration before disabling
save_config_state() {
    mkdir -p "$BACKUP_DIR"
    
    # Save random link and port if they exist
    if [ -f "$WEB_PROXY_DIR/access_info.txt" ]; then
        cp "$WEB_PROXY_DIR/access_info.txt" "$BACKUP_DIR/access_info.txt.backup"
    fi
    
    # Save current port configuration
    if [ "$OS" = "centos" ]; then
        if [ -f "$APACHE_CONFIG_DIR/conf/httpd.conf" ]; then
            cp "$APACHE_CONFIG_DIR/conf/httpd.conf" "$BACKUP_DIR/httpd.conf.$(date +%Y%m%d_%H%M%S)"
        fi
    else
        if [ -f "$APACHE_CONFIG_DIR/ports.conf" ]; then
            cp "$APACHE_CONFIG_DIR/ports.conf" "$BACKUP_DIR/ports.conf.$(date +%Y%m%d_%H%M%S)"
        fi
    fi
    
    echo -e "${GREEN}✅ Состояние сохранено в $BACKUP_DIR${NC}"
}

# Restore port configuration
restore_port_config() {
    if [ "$OS" = "centos" ]; then
        if [ -f "$BACKUP_DIR/httpd.conf"* ]; then
            local backup_file=$(ls -t "$BACKUP_DIR"/httpd.conf.* 2>/dev/null | head -1)
            if [ -n "$backup_file" ]; then
                cp "$backup_file" "$APACHE_CONFIG_DIR/conf/httpd.conf"
                echo -e "${GREEN}✅ Порт восстановлен из бэкапа${NC}"
            fi
        fi
    else
        if [ -f "$BACKUP_DIR/ports.conf"* ]; then
            local backup_file=$(ls -t "$BACKUP_DIR"/ports.conf.* 2>/dev/null | head -1)
            if [ -n "$backup_file" ]; then
                cp "$backup_file" "$APACHE_CONFIG_DIR/ports.conf"
                echo -e "${GREEN}✅ Порт восстановлен из бэкапа${NC}"
            fi
        fi
    fi
}

# Disable web interface
disable_web() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Отключение веб-интерфейса${NC}"
    echo -e "${YELLOW}========================================${NC}"
    
    if ! is_web_enabled; then
        echo -e "${YELLOW}⚠️ Веб-интерфейс уже отключен${NC}"
        return 0
    fi
    
    # Save current state before disabling
    save_config_state
    
    # Disable the configuration
    if [ "$OS" = "ubuntu" ]; then
        a2dissite proxy_config.conf 2>/dev/null || true
        echo -e "${GREEN}✅ Сайт proxy_config отключен${NC}"
    else
        if [ -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_FILE" "${CONFIG_FILE}.disabled"
            echo -e "${GREEN}✅ Конфигурация отключена (переименована в .disabled)${NC}"
        fi
    fi
    
    # Restore original port (80)
    restore_port_config
    
    # Reload Apache
    systemctl reload $APACHE_SERVICE 2>/dev/null || systemctl restart $APACHE_SERVICE
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ Веб-интерфейс ОТКЛЮЧЕН${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "${YELLOW}⚠️ Apache теперь слушает стандартный порт 80${NC}"
    echo -e "${YELLOW}💡 Для включения используйте: sudo $0 --enable${NC}"
    echo -e "${YELLOW}💡 Для просмотра статуса: sudo $0 --status${NC}"
}

# Enable web interface
enable_web() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Включение веб-интерфейса${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    if is_web_enabled; then
        echo -e "${YELLOW}⚠️ Веб-интерфейс уже включен${NC}"
        
        # Show current access info
        if [ -f "$WEB_PROXY_DIR/access_info.txt" ]; then
            echo ""
            cat "$WEB_PROXY_DIR/access_info.txt"
        fi
        return 0
    fi
    
    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ] && [ ! -f "${CONFIG_FILE}.disabled" ]; then
        echo -e "${RED}❌ Конфигурация не найдена. Запустите полную настройку: sudo $0${NC}"
        return 1
    fi
    
    # Restore config file if it was disabled
    if [ "$OS" = "centos" ]; then
        if [ -f "${CONFIG_FILE}.disabled" ]; then
            mv "${CONFIG_FILE}.disabled" "$CONFIG_FILE"
            echo -e "${GREEN}✅ Конфигурация восстановлена${NC}"
        fi
    else
        if [ -f "$CONFIG_FILE" ]; then
            a2ensite proxy_config.conf 2>/dev/null
            echo -e "${GREEN}✅ Сайт proxy_config включен${NC}"
        fi
    fi
    
    # Restore random port from backup
    if [ -f "$BACKUP_DIR/access_info.txt.backup" ]; then
        RANDOM_PORT=$(grep "Apache:" "$BACKUP_DIR/access_info.txt.backup" 2>/dev/null | grep -oP 'порт: \K[0-9]+' || echo "")
        
        if [ -n "$RANDOM_PORT" ]; then
            # Configure Apache on random port
            if [ "$OS" = "centos" ]; then
                sed -i "s/^Listen 80/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/conf/httpd.conf"
                sed -i "s/^Listen [0-9]\+/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/conf/httpd.conf"
            else
                sed -i "s/^Listen 80/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/ports.conf"
                sed -i "s/^Listen [0-9]\+/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/ports.conf"
            fi
            echo -e "${GREEN}✅ Порт восстановлен: $RANDOM_PORT${NC}"
        else
            echo -e "${YELLOW}⚠️ Не удалось восстановить порт, используется порт 80${NC}"
        fi
    fi
    
    # Reload Apache
    systemctl reload $APACHE_SERVICE 2>/dev/null || systemctl restart $APACHE_SERVICE
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ Веб-интерфейс ВКЛЮЧЕН${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    # Show access info
    if [ -f "$WEB_PROXY_DIR/access_info.txt" ]; then
        echo ""
        cat "$WEB_PROXY_DIR/access_info.txt"
    else
        echo -e "${YELLOW}⚠️ Файл с информацией о доступе не найден${NC}"
        echo -e "${YELLOW}Запустите полную настройку для регенерации: sudo $0${NC}"
    fi
}

# Show web interface status
show_status() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}Статус веб-интерфейса${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    
    # Check Apache service
    if systemctl is-active --quiet $APACHE_SERVICE 2>/dev/null; then
        echo -e "${GREEN}✅ Apache сервис: АКТИВЕН${NC}"
    else
        echo -e "${RED}❌ Apache сервис: НЕ АКТИВЕН${NC}"
    fi
    
    echo ""
    
    # Check if web interface is enabled
    if is_web_enabled; then
        echo -e "${GREEN}✅ Веб-интерфейс: ВКЛЮЧЕН${NC}"
        
        # Show current port
        CURRENT_PORT=""
        if [ "$OS" = "centos" ]; then
            CURRENT_PORT=$(grep "^Listen" "$APACHE_CONFIG_DIR/conf/httpd.conf" 2>/dev/null | head -1 | grep -oP '[0-9]+' || echo "80")
        else
            CURRENT_PORT=$(grep "^Listen" "$APACHE_CONFIG_DIR/ports.conf" 2>/dev/null | head -1 | grep -oP '[0-9]+' || echo "80")
        fi
        echo -e "${YELLOW}🌐 Порт Apache: ${GREEN}$CURRENT_PORT${NC}"
        
        # Show access URL if available
        if [ -f "$WEB_PROXY_DIR/access_info.txt" ]; then
            URL=$(grep "URL:" "$WEB_PROXY_DIR/access_info.txt" 2>/dev/null | head -1 | sed 's/URL: //')
            if [ -n "$URL" ]; then
                echo -e "${YELLOW}🔗 URL доступа: ${GREEN}$URL${NC}"
            fi
        fi
        
        # Show config files
        echo ""
        echo -e "${YELLOW}Конфигурационные файлы:${NC}"
        if [ "$OS" = "ubuntu" ]; then
            if [ -L "$APACHE_CONFIG_DIR/sites-enabled/proxy_config.conf" ]; then
                echo -e "  ${GREEN}✅ $APACHE_CONFIG_DIR/sites-enabled/proxy_config.conf${NC}"
            fi
            if [ -f "$CONFIG_FILE" ]; then
                echo -e "  ${GREEN}✅ $CONFIG_FILE${NC}"
            fi
        else
            if [ -f "$CONFIG_FILE" ]; then
                echo -e "  ${GREEN}✅ $CONFIG_FILE${NC}"
            fi
        fi
    else
        echo -e "${RED}❌ Веб-интерфейс: ОТКЛЮЧЕН${NC}"
        
        # Check if disabled config exists
        if [ "$OS" = "centos" ]; then
            if [ -f "${CONFIG_FILE}.disabled" ]; then
                echo -e "${YELLOW}  📄 Конфигурация отключена: ${CONFIG_FILE}.disabled${NC}"
            fi
        else
            if [ -f "$CONFIG_FILE" ] && [ ! -L "$APACHE_CONFIG_DIR/sites-enabled/proxy_config.conf" ]; then
                echo -e "${YELLOW}  📄 Сайт существует но не включен${NC}"
            fi
        fi
    fi
    
    # Show web directory
    echo ""
    echo -e "${YELLOW}Веб-директория:${NC}"
    if [ -d "$WEB_PROXY_DIR" ]; then
        DIR_SIZE=$(du -sh "$WEB_PROXY_DIR" 2>/dev/null | cut -f1)
        FILE_COUNT=$(find "$WEB_PROXY_DIR" -type f 2>/dev/null | wc -l)
        echo -e "  ${GREEN}✅ $WEB_PROXY_DIR${NC}"
        echo -e "  📦 Размер: $DIR_SIZE, Файлов: $FILE_COUNT"
    else
        echo -e "  ${RED}❌ $WEB_PROXY_DIR не существует${NC}"
    fi
    
    # Show backup info
    if [ -d "$BACKUP_DIR" ]; then
        BACKUP_COUNT=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l)
        if [ $BACKUP_COUNT -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}💾 Бэкапы: ${GREEN}$BACKUP_DIR${NC} (${BACKUP_COUNT} файлов)"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${YELLOW}Команды управления:${NC}"
    echo -e "  ${GREEN}Отключить:${NC} sudo $0 --disable"
    echo -e "  ${GREEN}Включить:${NC}  sudo $0 --enable"
    echo -e "  ${GREEN}Статус:${NC}    sudo $0 --status"
    echo -e "  ${GREEN}Полная настройка:${NC} sudo $0"
    echo -e "${CYAN}========================================${NC}"
}

# ============================================
# ОСТАЛЬНЫЕ ФУНКЦИИ (без изменений)
# ============================================

# Check if source directory exists
check_source_directory() {
    echo -e "${GREEN}Проверка исходной директории...${NC}"
    
    if [ ! -d "$PROXY_CONFIG_DIR" ]; then
        echo -e "${RED}Ошибка: Директория $PROXY_CONFIG_DIR не существует${NC}"
        echo -e "${YELLOW}Пожалуйста, сначала создайте конфигурации с помощью основного скрипта${NC}"
        exit 1
    fi
    
    if [ ! -f "$PROXY_CONFIG_DIR/users.txt" ]; then
        echo -e "${RED}Ошибка: Файл $PROXY_CONFIG_DIR/users.txt не найден${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ Исходная директория найдена${NC}"
}

# Check if port is available
check_port_available() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    if ss -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    return 0
}

# Generate random port between 10000 and 60000
generate_random_port() {
    local max_attempts=10
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        RANDOM_PORT=$((RANDOM % 50000 + 10000))
        if check_port_available $RANDOM_PORT; then
            echo -e "${GREEN}Сгенерирован случайный порт: $RANDOM_PORT${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    
    echo -e "${RED}Не удалось найти свободный порт после $max_attempts попыток${NC}"
    exit 1
}

# Generate random directory name
generate_random_link() {
    RANDOM_LINK="proxy_$(openssl rand -hex 8)"
    echo -e "${GREEN}Сгенерирован случайный путь: /$RANDOM_LINK${NC}"
}

# Safe JSON escape function
json_escape() {
    local str="$1"
    str=$(echo "$str" | sed 's/\\/\\\\/g')
    str=$(echo "$str" | sed 's/"/\\"/g')
    str=$(echo "$str" | sed 's/	/\\t/g')
    str=$(echo "$str" | sed 's/\
/\\n/g')
    echo "$str"
}

# Get actual proxy ports from config files
get_proxy_ports() {
    echo -e "${GREEN}Определение портов прокси...${NC}"
    
    SOCKS5_PORT=1080
    STUNNEL_PORT=443
    GOST_PORT=8443
    
    if [ -f /etc/3proxy/3proxy.cfg ] && [[ " ${PROXY_TYPES[*]} " =~ " socks5 " ]]; then
        SOCKS5_PORT=$(grep -E "^socks" /etc/3proxy/3proxy.cfg 2>/dev/null | head -1 | grep -oP 'p\K[0-9]+' || echo "1080")
        echo -e "  ${GREEN}3proxy порт: $SOCKS5_PORT${NC}"
    fi
    
    if [ -f /etc/stunnel/stunnel.conf ] && [[ " ${PROXY_TYPES[*]} " =~ " stunnel " ]]; then
        STUNNEL_PORT=$(grep -E "^accept" /etc/stunnel/stunnel.conf 2>/dev/null | head -1 | grep -oP ':[0-9]+' | tr -d ':' || echo "443")
        echo -e "  ${GREEN}Stunnel порт: $STUNNEL_PORT${NC}"
    fi
    
    if [ -f /etc/gost/config.json ] && [[ " ${PROXY_TYPES[*]} " =~ " gost " ]]; then
        GOST_PORT=$(grep -E '"addr"' /etc/gost/config.json 2>/dev/null | head -1 | grep -oP ':[0-9]+' | tr -d ':' || echo "8443")
        echo -e "  ${GREEN}GOST порт: $GOST_PORT${NC}"
    fi
}

# Copy files to web directory
copy_files_to_web() {
    echo -e "${GREEN}Копирование файлов в веб-директорию...${NC}"
    
    if [ ! -d "$WEB_PROXY_DIR" ]; then
        mkdir -p "$WEB_PROXY_DIR"
        mkdir -p "$WEB_PROXY_DIR/qrcodes/socks5"
        mkdir -p "$WEB_PROXY_DIR/qrcodes/stunnel"
        mkdir -p "$WEB_PROXY_DIR/qrcodes/gost"
        mkdir -p "$WEB_PROXY_DIR/client_configs/clash"
        mkdir -p "$WEB_PROXY_DIR/client_configs/shadowrocket"
        mkdir -p "$WEB_PROXY_DIR/client_configs/universal"
    fi
    
    if [ -d "$PROXY_CONFIG_DIR/qrcodes" ]; then
        cp -r "$PROXY_CONFIG_DIR/qrcodes/"* "$WEB_PROXY_DIR/qrcodes/" 2>/dev/null || echo -e "${YELLOW}  ⚠️ Некоторые QR коды не скопированы${NC}"
        echo -e "${GREEN}✅ QR коды скопированы${NC}"
    else
        echo -e "${YELLOW}⚠️ Директория qrcodes не найдена, пропускаем${NC}"
    fi
    
    if [ -d "$PROXY_CONFIG_DIR/client_configs" ]; then
        cp -r "$PROXY_CONFIG_DIR/client_configs/"* "$WEB_PROXY_DIR/client_configs/" 2>/dev/null || echo -e "${YELLOW}  ⚠️ Некоторые конфиги не скопированы${NC}"
        echo -e "${GREEN}✅ Клиентские конфиги скопированы${NC}"
    else
        echo -e "${YELLOW}⚠️ Директория client_configs не найдена, пропускаем${NC}"
    fi
    
    if [[ " ${PROXY_TYPES[*]} " =~ " socks5 " ]] && [ -d "$PROXY_CONFIG_DIR/socks5" ]; then
        cp -r "$PROXY_CONFIG_DIR/socks5" "$WEB_PROXY_DIR/" 2>/dev/null
        echo -e "${GREEN}✅ SOCKS5 строки скопированы${NC}"
    fi
    
    if [[ " ${PROXY_TYPES[*]} " =~ " stunnel " ]] && [ -d "$PROXY_CONFIG_DIR/stunnel" ]; then
        cp -r "$PROXY_CONFIG_DIR/stunnel" "$WEB_PROXY_DIR/" 2>/dev/null
        echo -e "${GREEN}✅ Stunnel строки скопированы${NC}"
    fi
    
    if [[ " ${PROXY_TYPES[*]} " =~ " gost " ]] && [ -d "$PROXY_CONFIG_DIR/gost" ]; then
        cp -r "$PROXY_CONFIG_DIR/gost" "$WEB_PROXY_DIR/" 2>/dev/null
        echo -e "${GREEN}✅ GOST строки скопированы${NC}"
    fi
    
    cp "$PROXY_CONFIG_DIR/users.txt" "$WEB_PROXY_DIR/" 2>/dev/null || true
    cp "$PROXY_CONFIG_DIR/SUMMARY.txt" "$WEB_PROXY_DIR/" 2>/dev/null || true
    
    chown -R $APACHE_USER:$APACHE_GROUP "$WEB_PROXY_DIR" 2>/dev/null || true
    chmod -R 755 "$WEB_PROXY_DIR"
    
    echo -e "${GREEN}✅ Файлы скопированы в: $WEB_PROXY_DIR${NC}"
}

# Install Apache if not installed
install_apache() {
    echo -e "${GREEN}Проверка установки Apache...${NC}"
    
    if command -v systemctl &> /dev/null && systemctl list-unit-files 2>/dev/null | grep -q "$APACHE_SERVICE.service"; then
        echo -e "${GREEN}✅ Apache уже установлен${NC}"
    else
        echo -e "${YELLOW}Установка Apache...${NC}"
        
        if [ "$OS" = "centos" ]; then
            dnf install -y httpd httpd-tools mod_ssl
            systemctl enable "$APACHE_SERVICE"
        else
            apt update -y
            apt install -y apache2 apache2-utils
            systemctl enable "$APACHE_SERVICE"
        fi
        
        echo -e "${GREEN}✅ Apache установлен${NC}"
    fi
}

# Configure Apache on random port
configure_apache_port() {
    echo -e "${GREEN}Настройка Apache на порт $RANDOM_PORT...${NC}"
    
    if [ "$OS" = "centos" ]; then
        if [ -f "$APACHE_CONFIG_DIR/conf/httpd.conf" ]; then
            cp "$APACHE_CONFIG_DIR/conf/httpd.conf" "$BACKUP_DIR/httpd.conf.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            sed -i "s/^Listen 80/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/conf/httpd.conf"
            sed -i "s/^Listen [0-9]\+/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/conf/httpd.conf"
        fi
    else
        if [ -f "$APACHE_CONFIG_DIR/ports.conf" ]; then
            cp "$APACHE_CONFIG_DIR/ports.conf" "$BACKUP_DIR/ports.conf.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
            sed -i "s/^Listen 80/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/ports.conf"
            sed -i "s/^Listen [0-9]\+/Listen $RANDOM_PORT/" "$APACHE_CONFIG_DIR/ports.conf"
        fi
    fi
    
    echo -e "${GREEN}✅ Apache настроен на порт $RANDOM_PORT${NC}"
}

# Create Apache configuration
create_apache_config() {
    echo -e "${GREEN}Создание конфигурации Apache...${NC}"
    
    cat > "$CONFIG_FILE" << EOF
# Apache configuration for proxy configs and QR codes
# Generated: $(date)
# Random path: /$RANDOM_LINK
# Random port: $RANDOM_PORT

<VirtualHost *:$RANDOM_PORT>
    ServerName _default_
    DocumentRoot /var/www/html
    
    Alias /$RANDOM_LINK "$WEB_PROXY_DIR"
    
    <Directory "$WEB_PROXY_DIR">
        Options -Indexes -FollowSymLinks
        AllowOverride None
        
        Header set X-Content-Type-Options "nosniff"
        Header set X-Frame-Options "DENY"
        Header set X-XSS-Protection "1; mode=block"
        
        Require all granted
        
        <FilesMatch "\.(txt|yaml|png|html|jpg|jpeg|gif|pdf|json|yml|conf|cfg)$">
            Require all granted
        </FilesMatch>
        
        <FilesMatch "^\.">
            Require all denied
        </FilesMatch>
    </Directory>
    
    <Location "/$RANDOM_LINK">
        ErrorDocument 403 "Access Forbidden - Proxy Configuration Area"
        ErrorDocument 404 "Not Found - Proxy Configuration Area"
    </Location>
    
    SetEnvIf Request_URI "^/$RANDOM_LINK" proxy_access
    CustomLog \${APACHE_LOG_DIR}/proxy_access.log combined env=proxy_access
</VirtualHost>
EOF

    if [ "$OS" = "ubuntu" ]; then
        a2ensite proxy_config.conf 2>/dev/null || true
        a2enmod headers 2>/dev/null || true
        a2enmod alias 2>/dev/null || true
        a2dismod autoindex 2>/dev/null || true
    fi
    
    chmod 644 "$CONFIG_FILE"
    echo -e "${GREEN}✅ Конфигурация Apache создана${NC}"
}

# Build users JSON safely
build_users_json() {
    local users_json="["
    local first=true
    
    while IFS=' : ' read -r username password; do
        [[ -z "$username" || -z "$password" ]] && continue
        [[ "$username" =~ ^=.*$ || "$username" =~ ^Дата.*$ || "$username" =~ ^Количество.*$ || "$username" =~ ^Сгенерированные.*$ ]] && continue
        [[ "$username" =~ ^[[:space:]]*$ ]] && continue
        
        username_escaped=$(json_escape "$username")
        password_escaped=$(json_escape "$password")
        
        if [ "$first" = true ]; then
            first=false
        else
            users_json="$users_json,"
        fi
        users_json="$users_json{\"username\":\"$username_escaped\",\"password\":\"$password_escaped\"}"
    done < "$PROXY_CONFIG_DIR/users.txt"
    
    users_json="$users_json]"
    echo "$users_json"
}

# Create index page
create_index_page() {
    echo -e "${GREEN}Создание индексной страницы...${NC}"
    
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
    
    USERS_JSON=$(build_users_json)
    USERS_JSON_JS=$(echo "$USERS_JSON" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    get_proxy_ports
    
    # HTML content (сокращено для brevity, но полная версия из предыдущего скрипта)
    cat > "$WEB_PROXY_DIR/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Multi-Proxy Configuration Portal</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); min-height: 100vh; padding: 20px; }
        .container { max-width: 1400px; margin: 0 auto; background: white; border-radius: 15px; box-shadow: 0 20px 60px rgba(0,0,0,0.3); overflow: hidden; }
        .header { background: linear-gradient(135deg, #0f3460 0%, #16213e 100%); color: white; padding: 30px; text-align: center; }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .content { padding: 30px; }
        .server-info { background: #f8f9fa; border-radius: 10px; padding: 20px; margin-bottom: 30px; border-left: 4px solid #0f3460; }
        .proxy-types { display: flex; gap: 20px; margin-bottom: 30px; flex-wrap: wrap; }
        .proxy-card { flex: 1; background: #f8f9fa; border-radius: 10px; padding: 20px; text-align: center; border-top: 4px solid #0f3460; }
        .proxy-card .port { font-size: 2em; font-weight: bold; color: #e94560; margin: 10px 0; }
        .users-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(400px, 1fr)); gap: 20px; margin-top: 20px; }
        .user-card { background: white; border: 1px solid #e0e0e0; border-radius: 10px; overflow: hidden; }
        .user-header { background: #0f3460; color: white; padding: 15px; font-size: 1.2em; font-weight: bold; }
        .user-body { padding: 20px; }
        .connection-row { background: #f8f9fa; padding: 10px; border-radius: 5px; margin: 10px 0; font-family: monospace; font-size: 0.85em; word-break: break-all; }
        .btn { display: inline-block; padding: 8px 12px; margin: 5px; background: #0f3460; color: white; text-decoration: none; border-radius: 5px; font-size: 0.85em; }
        .btn:hover { background: #e94560; }
        .footer { background: #f8f9fa; padding: 20px; text-align: center; color: #666; }
        .warning { background: #fff3cd; border-left: 4px solid #ffc107; padding: 15px; margin: 20px 0; border-radius: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔐 Multi-Proxy Configuration Portal</h1>
            <p>Secure access to proxy configurations</p>
        </div>
        <div class="content">
            <div class="server-info">
                <h3>📡 Server Information</h3>
                <p><strong>Server IP:</strong> <code id="server-ip"></code></p>
                <div class="warning">⚠️ <strong>Security Notice:</strong> Keep your credentials secure.</div>
            </div>
            
            <h2>📡 Available Proxy Types</h2>
            <div class="proxy-types">
                <div class="proxy-card"><h4>🔓 SOCKS5 Direct</h4><div class="port" id="port-socks5">1080</div></div>
                <div class="proxy-card"><h4>🔒 SOCKS5+TLS (Stunnel)</h4><div class="port" id="port-stunnel">443</div></div>
                <div class="proxy-card"><h4>🔒 SOCKS5+TLS (GOST)</h4><div class="port" id="port-gost">8443</div></div>
            </div>
            
            <h2>👥 Available Users</h2>
            <div class="users-grid" id="users-grid"></div>
        </div>
        <div class="footer">
            <p>Generated on: GENERATED_DATE_PLACEHOLDER</p>
        </div>
    </div>
    
    <script>
        const SERVER_IP = 'SERVER_IP_PLACEHOLDER';
        const RANDOM_LINK = 'RANDOM_LINK_PLACEHOLDER';
        const PORTS = { socks5: 'SOCKS5_PORT_PLACEHOLDER', stunnel: 'STUNNEL_PORT_PLACEHOLDER', gost: 'GOST_PORT_PLACEHOLDER' };
        
        let users = [];
        try {
            users = JSON.parse("USERS_DATA_PLACEHOLDER");
        } catch(e) {
            console.error('Failed to parse users:', e);
        }
        
        document.getElementById('server-ip').textContent = SERVER_IP;
        document.getElementById('port-socks5').textContent = PORTS.socks5;
        document.getElementById('port-stunnel').textContent = PORTS.stunnel;
        document.getElementById('port-gost').textContent = PORTS.gost;
        
        function createUserCard(user) {
            return '<div class="user-card"><div class="user-header">👤 ' + user.username + '</div><div class="user-body">' +
                '<div class="connection-row"><strong>🔑 Password:</strong> ' + user.password + '</div>' +
                '<div class="connection-row"><strong>🔓 SOCKS5 Direct:</strong><br><code>socks5://' + user.username + ':' + user.password + '@' + SERVER_IP + ':' + PORTS.socks5 + '</code></div>' +
                '<div class="connection-row"><strong>🔒 SOCKS5+TLS (Stunnel):</strong><br><code>socks5-tls://' + user.username + ':' + user.password + '@' + SERVER_IP + ':' + PORTS.stunnel + '</code></div>' +
                '<div class="connection-row"><strong>🔒 SOCKS5+TLS (GOST):</strong><br><code>socks5-tls://' + user.username + ':' + user.password + '@' + SERVER_IP + ':' + PORTS.gost + '</code></div>' +
                '<div style="text-align: center; margin-top: 15px;">' +
                '<a href="/' + RANDOM_LINK + '/client_configs/clash/' + user.username + '_clash.yaml" class="btn" download>📥 Clash</a>' +
                '<a href="/' + RANDOM_LINK + '/qrcodes/socks5/' + user.username + '_socks5.png" class="btn" target="_blank">📷 QR (Direct)</a>' +
                '<a href="/' + RANDOM_LINK + '/qrcodes/stunnel/' + user.username + '_stunnel.png" class="btn" target="_blank">📷 QR (Stunnel)</a>' +
                '<a href="/' + RANDOM_LINK + '/qrcodes/gost/' + user.username + '_gost.png" class="btn" target="_blank">📷 QR (GOST)</a>' +
                '</div></div></div>';
        }
        
        const usersGrid = document.getElementById('users-grid');
        if (!users || users.length === 0) {
            usersGrid.innerHTML = '<div style="text-align: center; padding: 40px;"><p>No users found.</p></div>';
        } else {
            for (let i = 0; i < users.length; i++) {
                if (users[i] && users[i].username) {
                    usersGrid.innerHTML += createUserCard(users[i]);
                }
            }
        }
    </script>
</body>
</html>
HTML

    sed -i "s/SERVER_IP_PLACEHOLDER/$SERVER_IP/g" "$WEB_PROXY_DIR/index.html"
    sed -i "s|RANDOM_LINK_PLACEHOLDER|$RANDOM_LINK|g" "$WEB_PROXY_DIR/index.html"
    sed -i "s/SOCKS5_PORT_PLACEHOLDER/$SOCKS5_PORT/g" "$WEB_PROXY_DIR/index.html"
    sed -i "s/STUNNEL_PORT_PLACEHOLDER/$STUNNEL_PORT/g" "$WEB_PROXY_DIR/index.html"
    sed -i "s/GOST_PORT_PLACEHOLDER/$GOST_PORT/g" "$WEB_PROXY_DIR/index.html"
    sed -i "s/GENERATED_DATE_PLACEHOLDER/$(date)/g" "$WEB_PROXY_DIR/index.html"
    
    perl -i -pe "s|USERS_DATA_PLACEHOLDER|$USERS_JSON_JS|g" "$WEB_PROXY_DIR/index.html"
    
    chown $APACHE_USER:$APACHE_GROUP "$WEB_PROXY_DIR/index.html" 2>/dev/null || true
    echo -e "${GREEN}✅ Индексная страница создана${NC}"
}

# Create access script
create_access_script() {
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
    
    cat > "$WEB_PROXY_DIR/access_info.txt" << EOF
========================================
ВЕБ-ДОСТУП К КОНФИГУРАЦИЯМ
========================================
URL: http://$SERVER_IP:$RANDOM_PORT/$RANDOM_LINK/
Полный путь: $WEB_PROXY_DIR

Что доступно:
- Веб-интерфейс: http://$SERVER_IP:$RANDOM_PORT/$RANDOM_LINK/index.html
- QR коды: http://$SERVER_IP:$RANDOM_PORT/$RANDOM_LINK/qrcodes/
- Конфиги: http://$SERVER_IP:$RANDOM_PORT/$RANDOM_LINK/client_configs/

========================================
УПРАВЛЕНИЕ
========================================
Статус:   sudo $0 --status
Отключить: sudo $0 --disable
Включить:  sudo $0 --enable

========================================
НАСТРОЙКА ФАЙРВОЛА
========================================
Не забудьте открыть порт $RANDOM_PORT в файрволе!
========================================
EOF
    
    chown $APACHE_USER:$APACHE_GROUP "$WEB_PROXY_DIR/access_info.txt" 2>/dev/null || true
    echo -e "${GREEN}✅ Информация о доступе: $WEB_PROXY_DIR/access_info.txt${NC}"
}

# Create sync script
create_sync_script() {
    cat > /root/sync_proxy_configs.sh << 'EOF'
#!/bin/bash
PROXY_CONFIG_DIR="/root/proxy_configs"
WEB_PROXY_DIR="/var/www/proxy_configs"

get_apache_user() {
    if [ -f /etc/redhat-release ]; then
        echo "apache"
    else
        echo "www-data"
    fi
}

APACHE_USER=$(get_apache_user)

if [ -d "$PROXY_CONFIG_DIR/qrcodes" ]; then
    cp -r "$PROXY_CONFIG_DIR/qrcodes/"* "$WEB_PROXY_DIR/qrcodes/" 2>/dev/null
fi

if [ -d "$PROXY_CONFIG_DIR/client_configs" ]; then
    cp -r "$PROXY_CONFIG_DIR/client_configs/"* "$WEB_PROXY_DIR/client_configs/" 2>/dev/null
fi

cp "$PROXY_CONFIG_DIR/users.txt" "$WEB_PROXY_DIR/" 2>/dev/null
cp "$PROXY_CONFIG_DIR/SUMMARY.txt" "$WEB_PROXY_DIR/" 2>/dev/null

chown -R "$APACHE_USER":"$APACHE_USER" "$WEB_PROXY_DIR" 2>/dev/null
chmod -R 755 "$WEB_PROXY_DIR"

echo "Sync completed at $(date)" >> /var/log/proxy_sync.log
EOF

    chmod +x /root/sync_proxy_configs.sh
    
    crontab -l 2>/dev/null | grep -v "sync_proxy_configs.sh" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "*/30 * * * * /root/sync_proxy_configs.sh") | crontab - 2>/dev/null
    
    echo -e "${GREEN}✅ Создан скрипт синхронизации и добавлен в cron${NC}"
}

# Show summary after full setup
show_summary() {
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)
    [ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ НАСТРОЙКА APACHE ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Веб-доступ к конфигурациям:${NC}"
    echo -e "  🔗 URL: ${GREEN}http://$SERVER_IP:$RANDOM_PORT/$RANDOM_LINK/${NC}"
    echo ""
    echo -e "${YELLOW}Управление веб-интерфейсом:${NC}"
    echo -e "  📊 Статус:   ${GREEN}sudo $0 --status${NC}"
    echo -e "  🔴 Отключить: ${GREEN}sudo $0 --disable${NC}"
    echo -e "  🟢 Включить:  ${GREEN}sudo $0 --enable${NC}"
    echo ""
    echo -e "${RED}⚠️  ВАЖНО: Не забудьте открыть порт $RANDOM_PORT в файрволе!${NC}"
    echo ""
}

# ============================================
# MAIN
# ============================================

main() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Пожалуйста, запустите с root правами (используйте sudo)${NC}"
        exit 1
    fi
    
    detect_os
    
    # Parse command line arguments
    case "${1:-}" in
        --disable)
            disable_web
            exit 0
            ;;
        --enable)
            enable_web
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --help|-h)
            echo -e "${GREEN}Использование: sudo $0 [OPTION]${NC}"
            echo ""
            echo -e "${YELLOW}Опции:${NC}"
            echo "  (без опций)   Полная настройка веб-сервера"
            echo "  --disable     Отключить веб-интерфейс"
            echo "  --enable      Включить веб-интерфейс"
            echo "  --status      Показать статус веб-интерфейса"
            echo "  --help, -h    Показать эту справку"
            echo ""
            echo -e "${YELLOW}Примеры:${NC}"
            echo "  sudo $0              # Первоначальная настройка"
            echo "  sudo $0 --status     # Проверить статус"
            echo "  sudo $0 --disable    # Отключить веб-доступ"
            echo "  sudo $0 --enable     # Включить веб-доступ"
            exit 0
            ;;
        "")
            # Полная настройка
            load_proxy_types
            check_source_directory
            install_apache
            generate_random_port
            generate_random_link
            configure_apache_port
            copy_files_to_web
            create_apache_config
            create_index_page
            create_access_script
            create_sync_script
            
            # Test configuration
            if [ "$OS" = "centos" ]; then
                apachectl configtest 2>/dev/null || true
            else
                apache2ctl configtest 2>/dev/null || true
            fi
            
            systemctl restart $APACHE_SERVICE
            
            sleep 2
            if systemctl is-active --quiet $APACHE_SERVICE; then
                echo -e "${GREEN}✅ Apache успешно запущен${NC}"
            else
                echo -e "${RED}❌ Ошибка запуска Apache${NC}"
                exit 1
            fi
            
            show_summary
            ;;
        *)
            echo -e "${RED}❌ Неизвестная опция: $1${NC}"
            echo -e "${YELLOW}Используйте: sudo $0 --help для справки${NC}"
            exit 1
            ;;
    esac
}

main "$@"