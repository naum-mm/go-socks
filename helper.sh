#!/bin/bash

# ============================================
# Multi-Proxy - Менеджер пользователей
# Управление пользователями для всех трех типов прокси
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Load config
if [ -f /root/proxy_configs/install_info.txt ]; then
    PROXY_TYPES=$(grep "Установленные прокси:" /root/proxy_configs/install_info.txt | sed 's/.*: //')
    OS=$(grep "ОС:" /root/proxy_configs/install_info.txt | awk '{print $2}')
else
    PROXY_TYPES="socks5 stunnel gost"
    if [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        OS="ubuntu"
    fi
fi

PORTS=(1080 443 8443)

# Get server IP
get_server_ip() {
    curl -s --max-time 5 ifconfig.me 2>/dev/null || \
    curl -s --max-time 5 ipinfo.io/ip 2>/dev/null || \
    hostname -I | awk '{print $1}'
}

# Update 3proxy config
update_3proxy_users() {
    if [[ ! " ${PROXY_TYPES[*]} " =~ " socks5 " ]]; then
        return
    fi
    
    echo -e "${BLUE}Обновление 3proxy пользователей...${NC}"
    
    # Build users string from users.txt
    USERS_STRING=""
    while IFS=' : ' read -r username password; do
        [[ -z "$username" || "$username" =~ ^=.*$ || "$username" =~ ^Дата.*$ ]] && continue
        USERS_STRING="$USERS_STRING $username:CL:$password"
    done < /root/proxy_configs/users.txt
    
    if [ -f /etc/3proxy/3proxy.cfg ]; then
        sed -i "s/^users.*/users$USERS_STRING/" /etc/3proxy/3proxy.cfg
        systemctl reload 3proxy
        echo -e "  ${GREEN}✅ 3proxy обновлен${NC}"
    fi
}

# Update stunnel (no user config, just restart)
update_stunnel() {
    if [[ ! " ${PROXY_TYPES[*]} " =~ " stunnel " ]]; then
        return
    fi
    
    echo -e "${BLUE}Обновление stunnel...${NC}"
    
    if [ "$OS" = "centos" ]; then
        systemctl restart stunnel
    else
        systemctl restart stunnel4 2>/dev/null || systemctl restart stunnel
    fi
    
    echo -e "  ${GREEN}✅ Stunnel перезапущен${NC}"
}

# Update GOST config
update_gost_users() {
    if [[ ! " ${PROXY_TYPES[*]} " =~ " gost " ]]; then
        return
    fi
    
    echo -e "${BLUE}Обновление GOST пользователей...${NC}"
    
    # Build users array
    GOST_USERS="[]"
    while IFS=' : ' read -r username password; do
        [[ -z "$username" || "$username" =~ ^=.*$ || "$username" =~ ^Дата.*$ ]] && continue
        GOST_USERS=$(echo "$GOST_USERS" | jq --arg u "$username" --arg p "$password" '. += [{"username": $u, "password": $p}]')
    done < /root/proxy_configs/users.txt
    
    if [ -f /etc/gost/config.json ]; then
        # Update the config while preserving structure
        jq --argjson users "$GOST_USERS" '.services[0].handler.auth.users = $users | .services[1].handler.auth.users = $users' /etc/gost/config.json > /etc/gost/config.json.tmp
        mv /etc/gost/config.json.tmp /etc/gost/config.json
        systemctl restart gost
        echo -e "  ${GREEN}✅ GOST обновлен${NC}"
    fi
}

# Regenerate QR codes for all users
regenerate_qrcodes() {
    echo -e "${BLUE}Регенерация QR кодов...${NC}"
    
    SERVER_IP=$(get_server_ip)
    mkdir -p /root/proxy_configs/qrcodes/{socks5,stunnel,gost}
    
    while IFS=' : ' read -r username password; do
        [[ -z "$username" || "$username" =~ ^=.*$ || "$username" =~ ^Дата.*$ ]] && continue
        
        # SOCKS5 direct
        CONN_STRING="socks5://$username:$password@$SERVER_IP:${PORTS[0]}"
        qrencode -o "/root/proxy_configs/qrcodes/socks5/${username}_socks5.png" "$CONN_STRING" 2>/dev/null
        
        # SOCKS5 over TLS (stunnel)
        CONN_STRING="socks5-tls://$username:$password@$SERVER_IP:${PORTS[1]}"
        qrencode -o "/root/proxy_configs/qrcodes/stunnel/${username}_stunnel.png" "$CONN_STRING" 2>/dev/null
        
        # SOCKS5 over TLS (GOST)
        CONN_STRING="socks5-tls://$username:$password@$SERVER_IP:${PORTS[2]}"
        qrencode -o "/root/proxy_configs/qrcodes/gost/${username}_gost.png" "$CONN_STRING" 2>/dev/null
        
        echo -e "  ${GREEN}✅ QR для $username обновлены${NC}"
    done < /root/proxy_configs/users.txt
}

# Regenerate client configs
regenerate_configs() {
    echo -e "${BLUE}Регенерация клиентских конфигураций...${NC}"
    
    SERVER_IP=$(get_server_ip)
    mkdir -p /root/proxy_configs/client_configs/{clash,shadowrocket,universal}
    mkdir -p /root/proxy_configs/{socks5,stunnel,gost}
    
    while IFS=' : ' read -r username password; do
        [[ -z "$username" || "$username" =~ ^=.*$ || "$username" =~ ^Дата.*$ ]] && continue
        
        # Save connection strings
        echo "socks5://$username:$password@$SERVER_IP:${PORTS[0]}" > "/root/proxy_configs/socks5/${username}_socks5.txt"
        echo "socks5-tls://$username:$password@$SERVER_IP:${PORTS[1]}" > "/root/proxy_configs/stunnel/${username}_stunnel.txt"
        echo "socks5-tls://$username:$password@$SERVER_IP:${PORTS[2]}" > "/root/proxy_configs/gost/${username}_gost.txt"
        
        # Clash config
        cat > "/root/proxy_configs/client_configs/clash/${username}_clash.yaml" << EOF
proxies:
  - name: "SOCKS5-Direct-${username}"
    type: socks5
    server: ${SERVER_IP}
    port: ${PORTS[0]}
    username: ${username}
    password: ${password}
    udp: true

  - name: "SOCKS5-Stunnel-${username}"
    type: socks5
    server: ${SERVER_IP}
    port: ${PORTS[1]}
    username: ${username}
    password: ${password}
    tls: true
    skip-cert-verify: true
    udp: true

  - name: "SOCKS5-GOST-${username}"
    type: socks5
    server: ${SERVER_IP}
    port: ${PORTS[2]}
    username: ${username}
    password: ${password}
    tls: true
    skip-cert-verify: true
    udp: true

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "SOCKS5-Direct-${username}"
      - "SOCKS5-Stunnel-${username}"
      - "SOCKS5-GOST-${username}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

        # Shadowrocket
        echo "shadowrocket://add?server=${SERVER_IP}&port=${PORTS[0]}&password=${password}&username=${username}&method=socks5&remarks=SOCKS5-Direct-${username}" > "/root/proxy_configs/client_configs/shadowrocket/${username}_direct.txt"
        echo "shadowrocket://add?server=${SERVER_IP}&port=${PORTS[1]}&password=${password}&username=${username}&method=socks5&remarks=SOCKS5-Stunnel-${username}&tls=1" > "/root/proxy_configs/client_configs/shadowrocket/${username}_stunnel.txt"
        echo "shadowrocket://add?server=${SERVER_IP}&port=${PORTS[2]}&password=${password}&username=${username}&method=socks5&remarks=SOCKS5-GOST-${username}&tls=1" > "/root/proxy_configs/client_configs/shadowrocket/${username}_gost.txt"
        
        echo -e "  ${GREEN}✅ Конфиги для $username обновлены${NC}"
    done < /root/proxy_configs/users.txt
}

# Show all users
show_users() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Список пользователей${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    if [ -f /root/proxy_configs/users.txt ]; then
        cat /root/proxy_configs/users.txt
    else
        echo -e "${RED}Файл с пользователями не найден${NC}"
    fi
}

# Add new user
add_user() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Добавление нового пользователя${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    read -p "Имя пользователя: " USERNAME
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}Имя не может быть пустым${NC}"
        return 1
    fi
    
    # Check if user exists
    if grep -q "^$USERNAME :" /root/proxy_configs/users.txt 2>/dev/null; then
        echo -e "${RED}Пользователь $USERNAME уже существует${NC}"
        return 1
    fi
    
    read -s -p "Пароль (Enter для генерации): " PASSWORD
    echo
    
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
        echo -e "${YELLOW}Сгенерирован пароль: $PASSWORD${NC}"
    fi
    
    read -s -p "Подтвердите пароль: " PASSWORD2
    echo
    
    if [ "$PASSWORD" != "$PASSWORD2" ]; then
        echo -e "${RED}Пароли не совпадают${NC}"
        return 1
    fi
    
    # Add to users.txt
    echo "$USERNAME : $PASSWORD" >> /root/proxy_configs/users.txt
    
    # Update all services
    update_3proxy_users
    update_gost_users
    update_stunnel
    
    # Regenerate QR and configs for all users
    regenerate_qrcodes
    regenerate_configs
    
    # Update summary
    update_summary
    
    echo -e "${GREEN}✅ Пользователь $USERNAME добавлен${NC}"
    echo -e "${YELLOW}Строки подключения:${NC}"
    SERVER_IP=$(get_server_ip)
    echo "  SOCKS5:     socks5://$USERNAME:$PASSWORD@$SERVER_IP:${PORTS[0]}"
    echo "  SOCKS5+TLS (stunnel): socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:${PORTS[1]}"
    echo "  SOCKS5+TLS (GOST):    socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:${PORTS[2]}"
}

# Remove user
remove_user() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Удаление пользователя${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    read -p "Имя пользователя для удаления: " USERNAME
    
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}Имя не может быть пустым${NC}"
        return 1
    fi
    
    # Check if user exists
    if ! grep -q "^$USERNAME :" /root/proxy_configs/users.txt 2>/dev/null; then
        echo -e "${RED}Пользователь $USERNAME не найден${NC}"
        return 1
    fi
    
    # Remove from users.txt
    sed -i "/^$USERNAME :/d" /root/proxy_configs/users.txt
    
    # Remove related files
    rm -f /root/proxy_configs/socks5/${USERNAME}_*
    rm -f /root/proxy_configs/stunnel/${USERNAME}_*
    rm -f /root/proxy_configs/gost/${USERNAME}_*
    rm -f /root/proxy_configs/qrcodes/socks5/${USERNAME}_*
    rm -f /root/proxy_configs/qrcodes/stunnel/${USERNAME}_*
    rm -f /root/proxy_configs/qrcodes/gost/${USERNAME}_*
    rm -f /root/proxy_configs/client_configs/clash/${USERNAME}_*
    rm -f /root/proxy_configs/client_configs/shadowrocket/${USERNAME}_*
    rm -f /root/proxy_configs/client_configs/universal/${USERNAME}_*
    
    # Update services
    update_3proxy_users
    update_gost_users
    update_stunnel
    
    # Update summary
    update_summary
    
    echo -e "${GREEN}✅ Пользователь $USERNAME удален${NC}"
}

# Change user password
change_password() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Смена пароля пользователя${NC}"
    echo -e "${GREEN}========================================${NC}"
    
    read -p "Имя пользователя: " USERNAME
    
    if [ -z "$USERNAME" ]; then
        echo -e "${RED}Имя не может быть пустым${NC}"
        return 1
    fi
    
    # Check if user exists
    if ! grep -q "^$USERNAME :" /root/proxy_configs/users.txt 2>/dev/null; then
        echo -e "${RED}Пользователь $USERNAME не найден${NC}"
        return 1
    fi
    
    read -s -p "Новый пароль (Enter для генерации): " NEW_PASSWORD
    echo
    
    if [ -z "$NEW_PASSWORD" ]; then
        NEW_PASSWORD=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
        echo -e "${YELLOW}Сгенерирован пароль: $NEW_PASSWORD${NC}"
    fi
    
    read -s -p "Подтвердите пароль: " PASSWORD2
    echo
    
    if [ "$NEW_PASSWORD" != "$PASSWORD2" ]; then
        echo -e "${RED}Пароли не совпадают${NC}"
        return 1
    fi
    
    # Update password in users.txt
    sed -i "s/^$USERNAME : .*/$USERNAME : $NEW_PASSWORD/" /root/proxy_configs/users.txt
    
    # Update services
    update_3proxy_users
    update_gost_users
    update_stunnel
    
    # Regenerate QR and configs
    regenerate_qrcodes
    regenerate_configs
    
    # Update summary
    update_summary
    
    echo -e "${GREEN}✅ Пароль для $USERNAME изменен${NC}"
}

# Update summary file
update_summary() {
    SERVER_IP=$(get_server_ip)
    
    cat > /root/proxy_configs/SUMMARY.txt << EOF
========================================
Multi-Proxy - Итоговая информация
========================================
Сервер: $SERVER_IP
Последнее обновление: $(date)

========================================
ДОСТУПНЫЕ ПРОКСИ
========================================

1. SOCKS5 Direct (без TLS)
   Порт: ${PORTS[0]}
   Формат: socks5://user:pass@$SERVER_IP:${PORTS[0]}

2. SOCKS5 over TLS (Stunnel)
   Порт: ${PORTS[1]}
   Формат: socks5-tls://user:pass@$SERVER_IP:${PORTS[1]}

3. SOCKS5 over TLS (GOST)
   Порт: ${PORTS[2]}
   Формат: socks5-tls://user:pass@$SERVER_IP:${PORTS[2]}

========================================
ПОЛЬЗОВАТЕЛИ
========================================

EOF

    while IFS=' : ' read -r username password; do
        [[ -z "$username" || "$username" =~ ^=.*$ || "$username" =~ ^Дата.*$ || "$username" =~ ^Количество.*$ || "$username" =~ ^Сгенерированные.*$ ]] && continue
        
        cat >> /root/proxy_configs/SUMMARY.txt << EOF
--- $username ---
Пароль: $password

Прямое подключение:
  socks5://$username:$password@$SERVER_IP:${PORTS[0]}

Stunnel (TLS):
  socks5-tls://$username:$password@$SERVER_IP:${PORTS[1]}

GOST (TLS):
  socks5-tls://$username:$password@$SERVER_IP:${PORTS[2]}

EOF
    done < /root/proxy_configs/users.txt

    cat >> /root/proxy_configs/SUMMARY.txt << EOF
========================================
ФАЙЛЫ
========================================
QR коды: /root/proxy_configs/qrcodes/
  - socks5/  - SOCKS5 direct
  - stunnel/ - SOCKS5+TLS (stunnel)
  - gost/    - SOCKS5+TLS (GOST)

Конфиги: /root/proxy_configs/client_configs/
Строки: /root/proxy_configs/{socks5,stunnel,gost}/

========================================
EOF
}

# Check status
check_status() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Статус сервисов${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    echo -e "${YELLOW}--- 3proxy (SOCKS5) ---${NC}"
    if systemctl is-active --quiet 3proxy 2>/dev/null; then
        echo -e "  ${GREEN}✅ Активен${NC}"
    else
        echo -e "  ${RED}❌ Не активен${NC}"
    fi
    
    echo -e "${YELLOW}--- Stunnel (SOCKS5+TLS) ---${NC}"
    if systemctl is-active --quiet stunnel 2>/dev/null || systemctl is-active --quiet stunnel4 2>/dev/null; then
        echo -e "  ${GREEN}✅ Активен${NC}"
    else
        echo -e "  ${RED}❌ Не активен${NC}"
    fi
    
    echo -e "${YELLOW}--- GOST (SOCKS5+TLS) ---${NC}"
    if systemctl is-active --quiet gost 2>/dev/null; then
        echo -e "  ${GREEN}✅ Активен${NC}"
    else
        echo -e "  ${RED}❌ Не активен${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}--- Порты ---${NC}"
    netstat -tlnp 2>/dev/null | grep -E "(${PORTS[0]}|${PORTS[1]}|${PORTS[2]}|1081|1082)" | while read line; do
        echo -e "  ${GREEN}$line${NC}"
    done
    
    echo ""
    echo -e "${YELLOW}--- Количество пользователей ---${NC}"
    USER_COUNT=$(grep -c "^[a-z_]* :" /root/proxy_configs/users.txt 2>/dev/null || echo "0")
    echo -e "  ${GREEN}$USER_COUNT пользователей${NC}"
}

# Show menu
show_menu() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Multi-Proxy - Менеджер${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "1. Показать всех пользователей"
    echo "2. Добавить пользователя"
    echo "3. Удалить пользователя"
    echo "4. Сменить пароль"
    echo "5. Проверить статус"
    echo "6. Показать итоговую информацию"
    echo "7. Регенерировать QR коды"
    echo "8. Регенерировать все конфиги"
    echo "9. Выход"
    echo -e "${GREEN}========================================${NC}"
    
    read -p "Выберите действие: " choice
    
    case $choice in
        1) show_users ;;
        2) add_user ;;
        3) remove_user ;;
        4) change_password ;;
        5) check_status ;;
        6) cat /root/proxy_configs/SUMMARY.txt ;;
        7) regenerate_qrcodes ;;
        8) regenerate_configs ;;
        9) exit 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
    
    echo
    read -p "Нажмите Enter для продолжения..."
    show_menu
}

# Main
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите с root правами${NC}"
    exit 1
fi

show_menu

