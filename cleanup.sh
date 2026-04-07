#!/bin/bash

# ============================================
# Полная очистка системы
# Удаление всех прокси сервисов и конфигураций
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${RED}========================================${NC}"
echo -e "${RED}⚠️  ПОЛНАЯ ОЧИСТКА СИСТЕМЫ ⚠️${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}Этот скрипт удалит:${NC}"
echo "  • Все прокси сервисы (3proxy, stunnel, GOST)"
echo "  • Веб-сервер Apache (опционально)"
echo "  • Все конфигурационные файлы"
echo "  • SSL сертификаты"
echo "  • Логи и временные файлы"
echo "  • Пользовательские данные"
echo "  • Пакеты: 3proxy, stunnel, gost, qrencode, jq, apache (опционально)"
echo ""
echo -e "${RED}ВНИМАНИЕ! Это действие необратимо!${NC}"
echo ""
read -p "Вы уверены, что хотите продолжить? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo -e "${GREEN}Очистка отменена.${NC}"
    exit 0
fi

# Global variables
OS=""
APACHE_SERVICE=""
ORIGINAL_CRON_BACKUP="/root/proxy_configs_backup/crontab.backup.$(date +%Y%m%d_%H%M%S)"
PACKAGES_TO_REMOVE=()

# Backup crontab
backup_crontab() {
    echo -e "${GREEN}Создание резервной копии crontab...${NC}"
    mkdir -p /root/proxy_configs_backup
    crontab -l 2>/dev/null > "$ORIGINAL_CRON_BACKUP" || true
    [ -f "$ORIGINAL_CRON_BACKUP" ] && [ -s "$ORIGINAL_CRON_BACKUP" ] && \
        echo -e "  ${GREEN}✅ Резервная копия crontab: $ORIGINAL_CRON_BACKUP${NC}"
}

# Detect OS
detect_os() {
    echo -e "${GREEN}Определение операционной системы...${NC}"
    
    if [ -f /etc/redhat-release ]; then
        OS="centos"
        APACHE_SERVICE="httpd"
        echo -e "${GREEN}Обнаружен CentOS/RHEL${NC}"
    elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
        OS="ubuntu"
        APACHE_SERVICE="apache2"
        echo -e "${GREEN}Обнаружен Ubuntu/Debian${NC}"
    else
        OS="unknown"
        APACHE_SERVICE="apache2"
    fi
}

# Stop all services
stop_services() {
    echo -e "${YELLOW}Остановка сервисов...${NC}"
    
    for service in 3proxy gost stunnel stunnel4 $APACHE_SERVICE; do
        if systemctl list-unit-files | grep -q "$service.service" 2>/dev/null; then
            systemctl stop $service 2>/dev/null || true
            systemctl disable $service 2>/dev/null || true
            echo -e "  ${GREEN}✅ $service остановлен${NC}"
        fi
    done
    
    killall 3proxy gost stunnel stunnel4 2>/dev/null || true
}

# Remove configuration files
remove_configs() {
    echo -e "${YELLOW}Удаление конфигурационных файлов...${NC}"
    
    # Directories
    for dir in /etc/3proxy /etc/stunnel /etc/gost /etc/ssl/3proxy /etc/ssl/gost /etc/ssl/proxy; do
        [ -d "$dir" ] && rm -rf "$dir" && echo -e "  ${GREEN}✅ $dir удален${NC}"
    done
    
    # Apache configs
    [ -f "/etc/apache2/sites-available/proxy_config.conf" ] && {
        a2dissite proxy_config.conf 2>/dev/null || true
        rm -f /etc/apache2/sites-available/proxy_config.conf
        echo -e "  ${GREEN}✅ Apache конфиг удален${NC}"
    }
    [ -f "/etc/httpd/conf.d/proxy_config.conf" ] && {
        rm -f /etc/httpd/conf.d/proxy_config.conf
        echo -e "  ${GREEN}✅ Apache конфиг удален${NC}"
    }
    
    # Systemd services
    for service in 3proxy gost; do
        [ -f "/etc/systemd/system/$service.service" ] && {
            rm -f "/etc/systemd/system/$service.service"
            echo -e "  ${GREEN}✅ systemd сервис $service удален${NC}"
        }
    done
    
    systemctl daemon-reload 2>/dev/null || true
}

# Remove certificates
remove_certificates() {
    echo -e "${YELLOW}Удаление SSL сертификатов...${NC}"
    
    for cert in /etc/ssl/3proxy /etc/ssl/gost /etc/ssl/proxy; do
        [ -d "$cert" ] && rm -rf "$cert" && echo -e "  ${GREEN}✅ $cert удален${NC}"
    done
    
    for file in /etc/ssl/certs/apache-selfsigned.crt /etc/ssl/private/apache-selfsigned.key; do
        [ -f "$file" ] && rm -f "$file" && echo -e "  ${GREEN}✅ $file удален${NC}"
    done
}

# Remove user data
remove_user_data() {
    echo -e "${YELLOW}Удаление пользовательских данных...${NC}"
    
    for dir in /root/proxy_configs /var/www/proxy_configs; do
        [ -d "$dir" ] && rm -rf "$dir" && echo -e "  ${GREEN}✅ $dir удален${NC}"
    done
    
    for script in /root/sync_proxy_configs.sh /root/adduser.sh; do
        [ -f "$script" ] && rm -f "$script" && echo -e "  ${GREEN}✅ $script удален${NC}"
    done
}

# Remove logs
remove_logs() {
    echo -e "${YELLOW}Удаление логов...${NC}"
    
    for log in /var/log/3proxy /var/log/stunnel /var/log/gost /var/log/proxy_sync.log; do
        [ -d "$log" ] && rm -rf "$log" && echo -e "  ${GREEN}✅ $log удален${NC}"
        [ -f "$log" ] && rm -f "$log" && echo -e "  ${GREEN}✅ $log удален${NC}"
    done
    
    for log in /var/log/apache2/proxy_access.log /var/log/httpd/proxy_access.log; do
        [ -f "$log" ] && rm -f "$log" && echo -e "  ${GREEN}✅ $log удален${NC}"
    done
}

# Remove cron jobs
remove_cron_jobs() {
    echo -e "${YELLOW}Удаление заданий cron...${NC}"
    backup_crontab
    
    TEMP_CRON=$(mktemp)
    crontab -l 2>/dev/null > "$TEMP_CRON" || true
    
    if grep -q "sync_proxy_configs.sh" "$TEMP_CRON" 2>/dev/null; then
        sed -i '/sync_proxy_configs\.sh/d' "$TEMP_CRON"
        sed -i '/3proxy/d' "$TEMP_CRON"
        sed -i '/gost/d' "$TEMP_CRON"
        crontab "$TEMP_CRON" 2>/dev/null || true
        echo -e "  ${GREEN}✅ Прокси-задания удалены из crontab${NC}"
    fi
    
    rm -f "$TEMP_CRON"
}

# Remove firewall rules
remove_firewall_rules() {
    echo -e "${YELLOW}Удаление правил файрвола...${NC}"
    
    PORTS=(1080 1081 1082 443 8443)
    
    if [ "$OS" = "centos" ]; then
        if systemctl is-active --quiet firewalld; then
            for PORT in "${PORTS[@]}"; do
                firewall-cmd --permanent --remove-port=$PORT/tcp 2>/dev/null || true
            done
            firewall-cmd --reload 2>/dev/null || true
            echo -e "  ${GREEN}✅ Правила firewalld удалены${NC}"
        fi
    else
        if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
            for PORT in "${PORTS[@]}"; do
                echo "y" | ufw delete allow $PORT/tcp 2>/dev/null || true
            done
            echo -e "  ${GREEN}✅ Правила UFW удалены${NC}"
        fi
    fi
}

# Remove packages
remove_packages() {
    echo -e "${YELLOW}Удаление пакетов...${NC}"
    echo ""
    read -p "Удалить пакеты прокси? (y/n): " REMOVE_PKGS
    
    if [[ $REMOVE_PKGS =~ ^[Yy]$ ]]; then
        if [ "$OS" = "centos" ]; then
            dnf remove -y 3proxy stunnel qrencode jq httpd 2>/dev/null || true
            dnf autoremove -y 2>/dev/null || true
        else
            apt remove --purge -y 3proxy stunnel4 qrencode jq apache2 2>/dev/null || true
            apt autoremove --purge -y 2>/dev/null || true
            apt clean 2>/dev/null || true
        fi
        
        # Remove GOST binary
        rm -f /usr/local/bin/gost 2>/dev/null || true
        
        echo -e "  ${GREEN}✅ Пакеты удалены${NC}"
    else
        echo -e "  ${YELLOW}Пакеты сохранены${NC}"
    fi
}

# Clean temp files
clean_temp_files() {
    echo -e "${YELLOW}Очистка временных файлов...${NC}"
    
    rm -f /var/run/3proxy.pid /var/run/stunnel.pid /var/run/stunnel4.pid /var/run/gost.pid 2>/dev/null || true
    rm -f /tmp/.3proxy 2>/dev/null || true
    rm -rf /tmp/3proxy* /tmp/gost* /tmp/stunnel* 2>/dev/null || true
    find /root/proxy_configs_backup -type f -mtime +7 -delete 2>/dev/null || true
    
    echo -e "  ${GREEN}✅ Временные файлы удалены${NC}"
}

# Show summary
show_summary() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ ОЧИСТКА ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Что было удалено:${NC}"
    echo "  ✅ Остановлены все сервисы"
    echo "  ✅ Удалены конфигурационные файлы"
    echo "  ✅ Удалены SSL сертификаты"
    echo "  ✅ Удалены пользовательские данные"
    echo "  ✅ Удалены логи"
    echo "  ✅ Удалены прокси-задания из crontab"
    echo "  ✅ Удалены правила файрвола"
    echo "  ✅ Очищены временные файлы"
    
    if [[ $REMOVE_PKGS =~ ^[Yy]$ ]]; then
        echo "  ✅ Удалены пакеты"
    fi
    echo ""
    
    [ -f "$ORIGINAL_CRON_BACKUP" ] && [ -s "$ORIGINAL_CRON_BACKUP" ] && \
        echo -e "${YELLOW}📁 Резервная копия crontab: $ORIGINAL_CRON_BACKUP${NC}"
    
    echo ""
    read -p "Перезагрузить сервер сейчас? (y/n): " REBOOT_NOW
    if [[ $REBOOT_NOW =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Перезагрузка сервера...${NC}"
        reboot
    else
        echo -e "${YELLOW}Рекомендуется перезагрузить сервер позже: sudo reboot${NC}"
    fi
}

# Main
main() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Пожалуйста, запустите с root правами (используйте sudo)${NC}"
        exit 1
    fi
    
    detect_os
    stop_services
    remove_configs
    remove_certificates
    remove_user_data
    remove_logs
    remove_cron_jobs
    remove_firewall_rules
    clean_temp_files
    remove_packages
    show_summary
}

main
