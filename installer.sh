#!/bin/bash

# ============================================
# Multi-Proxy Server Installer
# Установка для трех вариантов прокси:
# 1. SOCKS5 (3proxy)
# 2. SOCKS5+TLS (stunnel)
# 3. SOCKS5+TLS (GOST)
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Multi-Proxy Server - Установщик${NC}"
echo -e "${GREEN}========================================${NC}"

# Global variables
OS=""
OS_VERSION=""
ARCH=""
INSTALL_APACHE=false
PROXY_TYPES=()
STUNNEL_SERVICE="stunnel"

# Detect OS
detect_os() {
    echo -e "${GREEN}Определение операционной системы...${NC}"
    
    if [ -f /etc/redhat-release ]; then
        OS_VERSION=$(cat /etc/redhat-release)
        if [[ "$OS_VERSION" =~ CentOS.*[0-9] ]]; then
            CENTOS_VERSION=$(echo "$OS_VERSION" | grep -oE '[0-9]+' | head -1)
            if [ "$CENTOS_VERSION" -lt 8 ]; then
                echo -e "${RED}CentOS $CENTOS_VERSION слишком старая. Используйте CentOS 8 или новее.${NC}"
                exit 1
            fi
        fi
        OS="centos"
        echo -e "${GREEN}Обнаружена: $OS_VERSION${NC}"
    elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
        OS="ubuntu"
        echo -e "${GREEN}Обнаружена: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)${NC}"
    else
        echo -e "${RED}Неподдерживаемая ОС. Только CentOS 8+ и Ubuntu 18.04+/Debian 10+.${NC}"
        exit 1
    fi
    
    # Check architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        ARCH="amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        ARCH="arm64"
    else
        echo -e "${RED}Неподдерживаемая архитектура: $ARCH${NC}"
        exit 1
    fi
    echo -e "${GREEN}Архитектура: $ARCH${NC}"
}

# Check resources
check_resources() {
    echo -e "${GREEN}Проверка системных ресурсов...${NC}"
    
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_RAM" -lt 512 ]; then
        echo -e "${YELLOW}Внимание: Мало RAM (${TOTAL_RAM}MB). Рекомендуется минимум 512MB.${NC}"
    else
        echo -e "${GREEN}RAM: ${TOTAL_RAM}MB${NC}"
    fi
    
    FREE_SPACE=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$FREE_SPACE" -lt 1024 ]; then
        echo -e "${YELLOW}Внимание: Мало места (${FREE_SPACE}MB). Рекомендуется минимум 1GB.${NC}"
    else
        echo -e "${GREEN}Свободно места: ${FREE_SPACE}MB${NC}"
    fi
}

# Ask which proxy types to install
ask_proxy_types() {
    echo -e "${YELLOW}Выберите типы прокси для установки:${NC}"
    echo "  1) Только SOCKS5 (3proxy)"
    echo "  2) SOCKS5 + TLS (stunnel)"
    echo "  3) SOCKS5 + TLS (GOST)"
    echo "  4) Все три варианта"
    echo ""
    read -p "Ваш выбор (1-4): " PROXY_CHOICE
    
    case $PROXY_CHOICE in
        1)
            PROXY_TYPES=("socks5")
            ;;
        2)
            PROXY_TYPES=("socks5" "stunnel")
            ;;
        3)
            PROXY_TYPES=("socks5" "gost")
            ;;
        4)
            PROXY_TYPES=("socks5" "stunnel" "gost")
            ;;
        *)
            echo -e "${RED}Неверный выбор, устанавливаем все три варианта${NC}"
            PROXY_TYPES=("socks5" "stunnel" "gost")
            ;;
    esac
    
    echo -e "${GREEN}Будут установлены: ${PROXY_TYPES[*]}${NC}"
}

# Ask about Apache installation
ask_apache() {
    echo ""
    read -p "Установить и настроить Apache веб-сервер для раздачи конфигов? (y/n): " INSTALL_APACHE_CONFIRM
    if [[ $INSTALL_APACHE_CONFIRM =~ ^[Yy]$ ]]; then
        INSTALL_APACHE=true
        echo -e "${GREEN}Apache будет установлен${NC}"
    else
        INSTALL_APACHE=false
        echo -e "${YELLOW}Apache не будет установлен${NC}"
    fi
}

# Install base packages
install_base_packages() {
    echo -e "${GREEN}Установка базовых пакетов...${NC}"
    
    if [ "$OS" = "centos" ]; then
        dnf clean all
        dnf makecache
        dnf update -y
        dnf install -y epel-release
        dnf install -y openssl wget curl firewalld bc net-tools
    else
        apt update -y
        apt upgrade -y
        apt install -y openssl wget curl ufw bc net-tools
    fi
}

# Install qrencode
install_qrencode() {
    echo -e "${GREEN}Установка qrencode для генерации QR кодов...${NC}"
    
    if command -v qrencode &> /dev/null; then
        echo -e "${GREEN}✅ qrencode уже установлен${NC}"
        return
    fi
    
    if [ "$OS" = "centos" ]; then
        dnf install -y qrencode
    else
        apt install -y qrencode
    fi
    
    if command -v qrencode &> /dev/null; then
        echo -e "${GREEN}✅ qrencode успешно установлен${NC}"
    else
        echo -e "${YELLOW}⚠️ Не удалось установить qrencode. QR коды не будут созданы.${NC}"
    fi
}

# Install jq
install_jq() {
    echo -e "${GREEN}Установка jq для обработки JSON...${NC}"
    
    if command -v jq &> /dev/null; then
        echo -e "${GREEN}✅ jq уже установлен: $(jq --version)${NC}"
        return
    fi
    
    if [ "$OS" = "centos" ]; then
        dnf install -y jq
    else
        apt install -y jq
    fi
    
    if command -v jq &> /dev/null; then
        echo -e "${GREEN}✅ jq успешно установлен: $(jq --version)${NC}"
    else
        echo -e "${YELLOW}⚠️ Не удалось установить jq.${NC}"
    fi
}

# Install 3proxy
install_3proxy() {
    echo -e "${GREEN}Установка 3proxy...${NC}"
    
    if command -v 3proxy &> /dev/null; then
        echo -e "${GREEN}✅ 3proxy уже установлен${NC}"
        return
    fi
    
    if [ "$OS" = "centos" ]; then
        if dnf install -y 3proxy 2>/dev/null; then
            echo -e "${GREEN}✅ 3proxy установлен из EPEL${NC}"
        else
            echo -e "${YELLOW}Компиляция 3proxy из исходников...${NC}"
            dnf install -y gcc make git
            TMP_DIR=$(mktemp -d)
            cd "$TMP_DIR"
            git clone https://github.com/3proxy/3proxy.git
            cd 3proxy
            make -f Makefile.Linux
            cp bin/3proxy /usr/bin/
            mkdir -p /etc/3proxy
            cd /
            rm -rf "$TMP_DIR"
            echo -e "${GREEN}✅ 3proxy скомпилирован${NC}"
        fi
    else
        LATEST_VERSION=$(curl -s https://api.github.com/repos/3proxy/3proxy/releases/latest | grep -oP '"tag_name": "\K(.*?)(?=")' || echo "0.9.4")
        
        if [ "$ARCH" = "amd64" ]; then
            DEB_FILE="3proxy-${LATEST_VERSION}.x86_64.deb"
        else
            DEB_FILE="3proxy-${LATEST_VERSION}.arm64.deb"
        fi
        
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        if wget -q "https://github.com/3proxy/3proxy/releases/download/${LATEST_VERSION}/${DEB_FILE}"; then
            dpkg -i "$DEB_FILE" 2>/dev/null || apt-get install -f -y && dpkg -i "$DEB_FILE"
            echo -e "${GREEN}✅ 3proxy установлен из .deb${NC}"
        else
            apt install -y 3proxy
            echo -e "${GREEN}✅ 3proxy установлен из репозитория${NC}"
        fi
        
        cd /
        rm -rf "$TMP_DIR"
    fi
}

# Install stunnel
install_stunnel() {
    echo -e "${GREEN}Установка stunnel...${NC}"
    
    if [ "$OS" = "centos" ]; then
        dnf install -y stunnel
        STUNNEL_SERVICE="stunnel"
    else
        apt install -y stunnel4
        STUNNEL_SERVICE="stunnel4"
        sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✅ Stunnel установлен${NC}"
}

# Install GOST (latest stable version)
install_gost() {
    echo -e "${GREEN}Установка последней версии GOST...${NC}"
    
    # Check if already installed
    if command -v gost &> /dev/null; then
        CURRENT_VERSION=$(gost -V 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?' || echo "unknown")
        echo -e "${GREEN}✅ GOST уже установлен (версия: $CURRENT_VERSION)${NC}"
        
        read -p "Обновить до последней версии? (y/n): " UPDATE_GOST
        if [[ ! $UPDATE_GOST =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    # Get latest release version from GitHub API
    echo -e "${YELLOW}Получение информации о последней версии...${NC}"
    
    # Try to get version from GitHub API
    LATEST_VERSION=$(curl -s https://api.github.com/repos/go-gost/gost/releases/latest 2>/dev/null | grep -oP '"tag_name": "\Kv?([0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?)' | sed 's/^v//' | head -1)
    
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}Не удалось определить последнюю версию через API. Использую fallback метод...${NC}"
        LATEST_VERSION=$(curl -sL https://github.com/go-gost/gost/releases/latest 2>/dev/null | grep -oP 'releases/tag/v?\K[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?' | head -1)
    fi
    
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}❌ Не удалось определить версию GOST. Установка невозможна.${NC}"
        echo -e "${YELLOW}Пожалуйста, установите GOST вручную с https://github.com/go-gost/gost/releases${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Найдена последняя версия: $LATEST_VERSION${NC}"
    
    # Prepare download URL
    DOWNLOAD_URL="https://github.com/go-gost/gost/releases/download/v${LATEST_VERSION}/gost_${LATEST_VERSION}_linux_${ARCH}.tar.gz"
    
    echo -e "${YELLOW}Загрузка GOST ${LATEST_VERSION} для ${ARCH}...${NC}"
    
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    # Download and extract
    if wget -q --show-progress "$DOWNLOAD_URL" -O gost.tar.gz; then
        tar -xzf gost.tar.gz
        
        # Find the gost binary
        if [ -f "gost" ]; then
            mv gost /usr/local/bin/gost
        elif [ -f "bin/gost" ]; then
            mv bin/gost /usr/local/bin/gost
        else
            GOST_BIN=$(find . -name "gost" -type f -executable 2>/dev/null | head -1)
            if [ -n "$GOST_BIN" ]; then
                mv "$GOST_BIN" /usr/local/bin/gost
            fi
        fi
        
        if [ -f "/usr/local/bin/gost" ]; then
            chmod +x /usr/local/bin/gost
            INSTALLED_VERSION=$(/usr/local/bin/gost -V 2>&1 | head -1)
            echo -e "${GREEN}✅ GOST успешно установлен: $INSTALLED_VERSION${NC}"
        else
            echo -e "${RED}❌ Не удалось найти бинарный файл GOST${NC}"
            cd /
            rm -rf "$TMP_DIR"
            return 1
        fi
    else
        echo -e "${RED}❌ Не удалось загрузить GOST${NC}"
        echo -e "${YELLOW}Попробуйте установить вручную:${NC}"
        echo -e "  wget $DOWNLOAD_URL"
        cd /
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    cd /
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}✅ GOST установлен успешно${NC}"
}

# Install Apache
install_apache() {
    if [ "$INSTALL_APACHE" = false ]; then
        return
    fi
    
    echo -e "${GREEN}Установка Apache веб-сервера...${NC}"
    
    if [ "$OS" = "centos" ]; then
        if ! command -v httpd &> /dev/null; then
            dnf install -y httpd httpd-tools mod_ssl
            systemctl enable httpd
            echo -e "${GREEN}✅ Apache (httpd) установлен${NC}"
        fi
    else
        if ! command -v apache2 &> /dev/null; then
            apt install -y apache2 apache2-utils
            systemctl enable apache2
            echo -e "${GREEN}✅ Apache (apache2) установлен${NC}"
        fi
    fi
}

# Create directories
create_directories() {
    echo -e "${GREEN}Создание директорий...${NC}"
    
    mkdir -p /etc/3proxy
    mkdir -p /etc/stunnel
    mkdir -p /etc/gost
    mkdir -p /var/log/3proxy
    mkdir -p /var/log/stunnel
    mkdir -p /var/log/gost
    mkdir -p /etc/ssl/proxy
    mkdir -p /root/proxy_configs
    mkdir -p /root/proxy_configs/qrcodes
    mkdir -p /root/proxy_configs/client_configs
    mkdir -p /root/proxy_configs/socks5
    mkdir -p /root/proxy_configs/stunnel
    mkdir -p /root/proxy_configs/gost
    
    chmod 755 /var/log/3proxy 2>/dev/null || true
    chmod 755 /var/log/stunnel 2>/dev/null || true
    chmod 755 /var/log/gost 2>/dev/null || true
    
    echo -e "${GREEN}✅ Директории созданы${NC}"
}

# Create systemd services
create_services() {
    # 3proxy service
    cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/3proxy /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # GOST service
    cat > /etc/systemd/system/gost.service << 'EOF'
[Unit]
Description=GOST Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}✅ systemd сервисы созданы${NC}"
}

# Save install info
save_install_info() {
    cat > /root/proxy_configs/install_info.txt << EOF
========================================
Информация об установке
========================================
ОС: $OS
Версия ОС: ${OS_VERSION:-$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)}
Дата установки: $(date)
Архитектура: $ARCH
Установленные прокси: ${PROXY_TYPES[*]}
Apache установлен: $INSTALL_APACHE
Stunnel сервис: $STUNNEL_SERVICE
========================================
3proxy версия: $(3proxy --version 2>&1 | head -1 || echo "не установлен")
GOST версия: $(gost -V 2>&1 | head -1 || echo "не установлен")
jq версия: $(jq --version 2>/dev/null || echo "не установлен")
qrencode версия: $(qrencode --version 2>&1 | head -1 || echo "не установлен")
========================================
EOF
    echo -e "${GREEN}✅ Информация сохранена в /root/proxy_configs/install_info.txt${NC}"
}

# Show summary
show_summary() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Установленные компоненты:${NC}"
    for proxy in "${PROXY_TYPES[@]}"; do
        case $proxy in
            socks5)  echo -e "  • SOCKS5 (3proxy) - порт 1080${NC}" ;;
            stunnel) echo -e "  • SOCKS5+TLS (stunnel) - порт 443${NC}" ;;
            gost)    echo -e "  • SOCKS5+TLS (GOST) - порт 8443${NC}" ;;
        esac
    done
    [ "$INSTALL_APACHE" = true ] && echo -e "  • Apache веб-сервер"
    echo ""
    echo -e "${YELLOW}Следующие шаги:${NC}"
    echo -e "  1. Запустите конфигуратор: ${GREEN}sudo ./configurator.sh${NC}"
    if [ "$INSTALL_APACHE" = true ]; then
        echo -e "  2. Настройте веб-доступ: ${GREEN}sudo ./apache.sh${NC}"
    fi
    echo -e "  3. Управление пользователями: ${GREEN}sudo ./helpers.sh${NC}"
    echo -e "  4. Очистка системы: ${GREEN}sudo ./cleanup.sh${NC}"
    echo ""
}

# Main execution
main() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Пожалуйста, запустите с root правами (используйте sudo)${NC}"
        exit 1
    fi
    
    detect_os
    check_resources
    ask_proxy_types
    ask_apache
    
    install_base_packages
    install_qrencode
    install_jq
    
    for proxy in "${PROXY_TYPES[@]}"; do
        case $proxy in
            socks5)  install_3proxy ;;
            stunnel) install_stunnel ;;
            gost)    install_gost ;;
        esac
    done
    
    install_apache
    create_directories
    create_services
    save_install_info
    show_summary
}

main