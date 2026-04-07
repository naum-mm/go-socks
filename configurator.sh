#!/bin/bash

# ============================================
# Multi-Proxy Configurator v2
# Настройка трех вариантов прокси:
# 1. SOCKS5+TLS (GOST) - порт 443 (ПРИОРИТЕТ)
# 2. SOCKS5+TLS (stunnel) - порт 1443
# 3. SOCKS5 (3proxy) - случайные порты
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Multi-Proxy v2 - Конфигуратор${NC}"
echo -e "${GREEN}========================================${NC}"

# Load install info
if [ -f /root/proxy_configs/install_info.txt ]; then
    PROXY_TYPES=$(grep "Установленные прокси:" /root/proxy_configs/install_info.txt | sed 's/.*: //')
    OS=$(grep "ОС:" /root/proxy_configs/install_info.txt | awk '{print $2}')
    STUNNEL_SERVICE=$(grep "Stunnel сервис:" /root/proxy_configs/install_info.txt | awk '{print $3}')
else
    PROXY_TYPES="socks5 stunnel gost"
    if [ -f /etc/redhat-release ]; then
        OS="centos"
        STUNNEL_SERVICE="stunnel"
    else
        OS="ubuntu"
        STUNNEL_SERVICE="stunnel4"
    fi
fi

# Ports - NEW LOGIC
GOST_PORT=443              # Приоритетный порт (бывший stunnel)
STUNNEL_PORT=1443          # Второй TLS порт
SOCKS5_PORT=$(shuf -i 20000-60000 -n 1)    # Случайный порт для SOCKS5
SOCKS5_ALT_PORT=$(shuf -i 60001-65000 -n 1) # Альтернативный случайный порт
GOST_PLAIN_PORT=$(shuf -i 10000-19999 -n 1) # Прямой SOCKS5 от GOST

# Global arrays
USERS=()
USERNAMES=()
PASSWORDS=()

# Generate random password
generate_random_password() {
    openssl rand -base64 12 | tr -d "=+/" | cut -c1-12
}

# Generate random port
generate_random_port() {
    echo $(shuf -i 10000-65000 -n 1)
}

# Generate users
generate_users() {
    echo -e "${GREEN}Генерация пользователей...${NC}"
    read -p "Количество пользователей (по умолчанию 5): " USER_COUNT
    USER_COUNT=${USER_COUNT:-5}
    
    if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ]; then
        echo -e "${RED}Неверное количество${NC}"
        USER_COUNT=5
    fi
    
    for i in $(seq 1 $USER_COUNT); do
        USERNAME="user_${i}"
        PASSWORD=$(generate_random_password)
        USERS+=("$USERNAME:$PASSWORD")
        USERNAMES+=("$USERNAME")
        PASSWORDS+=("$PASSWORD")
        echo -e "${GREEN}  ✅ $USERNAME / $PASSWORD${NC}"
    done
    
    # Save users
    cat > /root/proxy_configs/users.txt << EOF
========================================
Сгенерированные пользователи
========================================
Дата: $(date)
Количество: ${#USERS[@]}
========================================

EOF
    
    for user_pass in "${USERS[@]}"; do
        USERNAME=$(echo "$user_pass" | cut -d: -f1)
        PASSWORD=$(echo "$user_pass" | cut -d: -f2)
        echo "$USERNAME : $PASSWORD" >> /root/proxy_configs/users.txt
    done
}

# Get server IP
get_server_ip() {
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null)
    fi
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi
    echo "$SERVER_IP"
}

# Create SSL certificate
create_certificate() {
    echo -e "${GREEN}Создание SSL сертификата...${NC}"
    
    read -p "Домен или IP для сертификата: " CERT_DOMAIN
    CERT_DOMAIN=${CERT_DOMAIN:-$(get_server_ip)}
    
    mkdir -p /etc/ssl/proxy
    cd /etc/ssl/proxy
    
    openssl req -new -x509 -days 365 -nodes \
        -out proxy.pem \
        -keyout proxy.pem \
        -subj "/C=US/ST=State/L=City/O=Proxy/CN=$CERT_DOMAIN"
    
    chmod 600 proxy.pem
    cp proxy.pem /etc/ssl/proxy/stunnel.pem 2>/dev/null || true
    cp proxy.pem /etc/ssl/proxy/gost.pem 2>/dev/null || true
    
    echo -e "${GREEN}✅ Сертификат создан${NC}"
}

# Configure 3proxy (SOCKS5) - random ports
configure_3proxy() {
    if [[ ! " ${PROXY_TYPES[*]} " =~ " socks5 " ]]; then
        return
    fi
    
    echo -e "${GREEN}Настройка 3proxy (SOCKS5) на случайных портах...${NC}"
    echo -e "${YELLOW}  Основной порт: $SOCKS5_PORT${NC}"
    echo -e "${YELLOW}  Резервный порт: $SOCKS5_ALT_PORT${NC}"
    
    # Build users string
    USERS_STRING=""
    for user_pass in "${USERS[@]}"; do
        USERNAME=$(echo "$user_pass" | cut -d: -f1)
        PASSWORD=$(echo "$user_pass" | cut -d: -f2)
        USERS_STRING="$USERS_STRING $USERNAME:CL:$PASSWORD"
    done
    
    cat > /etc/3proxy/3proxy.cfg << EOF
daemon
nserver 8.8.8.8
nserver 8.8.4.4

log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R %r %O %I %T %i %o %e %Tt %Tt"
rotate 30

auth strong
users$USERS_STRING

# SOCKS5 on random ports
socks -i0.0.0.0 -p$SOCKS5_PORT
socks -i0.0.0.0 -p$SOCKS5_ALT_PORT

maxconn 100
service 3proxy
pidfile /var/run/3proxy.pid
timeout 60

allow * * * 80-65535
proxy -n -a
EOF

    systemctl restart 3proxy
    echo -e "${GREEN}✅ 3proxy настроен (порты: $SOCKS5_PORT, $SOCKS5_ALT_PORT)${NC}"
}

# Configure stunnel - port 1443
configure_stunnel() {
    if [[ ! " ${PROXY_TYPES[*]} " =~ " stunnel " ]]; then
        return
    fi
    
    echo -e "${GREEN}Настройка stunnel на порту $STUNNEL_PORT...${NC}"
    
    cat > /etc/stunnel/stunnel.conf << EOF
pid = /var/run/stunnel.pid
debug = 7
output = /var/log/stunnel/stunnel.log

cert = /etc/ssl/proxy/proxy.pem
key = /etc/ssl/proxy/proxy.pem

[socks5-tls]
accept = 0.0.0.0:$STUNNEL_PORT
connect = 127.0.0.1:$SOCKS5_PORT
TIMEOUTclose = 0
EOF

    if [ "$OS" = "ubuntu" ]; then
        sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4 2>/dev/null || true
        mkdir -p /etc/systemd/system/stunnel4.service.d
        cat > /etc/systemd/system/stunnel4.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/stunnel4 /etc/stunnel/stunnel.conf
Restart=always
RestartSec=5
EOF
    fi
    
    systemctl daemon-reload
    systemctl restart $STUNNEL_SERVICE 2>/dev/null || systemctl restart stunnel4 2>/dev/null
    
    echo -e "${GREEN}✅ Stunnel настроен (порт $STUNNEL_PORT) -> подключается к 3proxy :$SOCKS5_PORT${NC}"
}

# Configure GOST - priority port 443
configure_gost() {
    if [[ ! " ${PROXY_TYPES[*]} " =~ " gost " ]]; then
        return
    fi
    
    echo -e "${GREEN}Настройка GOST (ПРИОРИТЕТ) на порту $GOST_PORT...${NC}"
    
    # Build users array for GOST config
    GOST_USERS="[]"
    for user_pass in "${USERS[@]}"; do
        USERNAME=$(echo "$user_pass" | cut -d: -f1)
        PASSWORD=$(echo "$user_pass" | cut -d: -f2)
        GOST_USERS=$(echo "$GOST_USERS" | jq --arg u "$USERNAME" --arg p "$PASSWORD" '. += [{"username": $u, "password": $p}]')
    done
    
    cat > /etc/gost/config.json << EOF
{
    "services": [
        {
            "name": "socks5-tls-primary",
            "addr": ":$GOST_PORT",
            "handler": {
                "type": "socks5",
                "auth": {
                    "users": $GOST_USERS
                }
            },
            "listener": {
                "type": "tls",
                "config": {
                    "certificate": "/etc/ssl/proxy/proxy.pem",
                    "privateKey": "/etc/ssl/proxy/proxy.pem"
                }
            }
        },
        {
            "name": "socks5-plain",
            "addr": ":$GOST_PLAIN_PORT",
            "handler": {
                "type": "socks5",
                "auth": {
                    "users": $GOST_USERS
                }
            },
            "listener": {
                "type": "tcp"
            }
        }
    ]
}
EOF

    systemctl restart gost
    echo -e "${GREEN}✅ GOST настроен (TLS порт: $GOST_PORT, прямой порт: $GOST_PLAIN_PORT)${NC}"
}

# Generate connection strings
generate_connection_strings() {
    echo -e "${GREEN}Генерация строк подключения...${NC}"
    
    SERVER_IP=$(get_server_ip)
    
    for i in "${!USERS[@]}"; do
        USERNAME="${USERNAMES[$i]}"
        PASSWORD="${PASSWORDS[$i]}"
        
        # SOCKS5 direct (3proxy) - random ports
        SOCKS5_DIRECT="socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_PORT"
        SOCKS5_DIRECT_ALT="socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_ALT_PORT"
        
        # SOCKS5 direct (GOST plain)
        SOCKS5_GOST_PLAIN="socks5://$USERNAME:$PASSWORD@$SERVER_IP:$GOST_PLAIN_PORT"
        
        # SOCKS5 over TLS (stunnel) - port 1443
        SOCKS5_STUNNEL="socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$STUNNEL_PORT"
        
        # SOCKS5 over TLS (GOST) - priority port 443
        SOCKS5_GOST="socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$GOST_PORT"
        
        # Save to files
        echo "$SOCKS5_DIRECT" > "/root/proxy_configs/socks5/${USERNAME}_socks5.txt"
        echo "$SOCKS5_DIRECT_ALT" > "/root/proxy_configs/socks5/${USERNAME}_socks5_alt.txt"
        echo "$SOCKS5_GOST_PLAIN" > "/root/proxy_configs/socks5/${USERNAME}_gost_plain.txt"
        echo "$SOCKS5_STUNNEL" > "/root/proxy_configs/stunnel/${USERNAME}_stunnel.txt"
        echo "$SOCKS5_GOST" > "/root/proxy_configs/gost/${USERNAME}_gost.txt"
    done
    
    echo -e "${GREEN}✅ Строки подключения сохранены${NC}"
}

# Generate QR codes
generate_qrcodes() {
    echo -e "${GREEN}Генерация QR кодов...${NC}"
    
    SERVER_IP=$(get_server_ip)
    mkdir -p /root/proxy_configs/qrcodes/{socks5,stunnel,gost}
    
    for i in "${!USERS[@]}"; do
        USERNAME="${USERNAMES[$i]}"
        PASSWORD="${PASSWORDS[$i]}"
        
        # SOCKS5 direct (3proxy main)
        CONN_STRING="socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_PORT"
        qrencode -o "/root/proxy_configs/qrcodes/socks5/${USERNAME}_socks5.png" "$CONN_STRING" 2>/dev/null
        
        # SOCKS5 direct alt port
        CONN_STRING="socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_ALT_PORT"
        qrencode -o "/root/proxy_configs/qrcodes/socks5/${USERNAME}_socks5_alt.png" "$CONN_STRING" 2>/dev/null
        
        # SOCKS5 over TLS (stunnel)
        CONN_STRING="socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$STUNNEL_PORT"
        qrencode -o "/root/proxy_configs/qrcodes/stunnel/${USERNAME}_stunnel.png" "$CONN_STRING" 2>/dev/null
        
        # SOCKS5 over TLS (GOST - priority)
        CONN_STRING="socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$GOST_PORT"
        qrencode -o "/root/proxy_configs/qrcodes/gost/${USERNAME}_gost.png" "$CONN_STRING" 2>/dev/null
        
        echo -e "${GREEN}  ✅ QR для $USERNAME созданы${NC}"
    done
}

# Generate client configs
generate_client_configs() {
    echo -e "${GREEN}Генерация клиентских конфигураций...${NC}"
    
    SERVER_IP=$(get_server_ip)
    mkdir -p /root/proxy_configs/client_configs/{clash,shadowrocket,universal}
    
    for i in "${!USERS[@]}"; do
        USERNAME="${USERNAMES[$i]}"
        PASSWORD="${PASSWORDS[$i]}"
        
        # Clash config with all proxy types
        cat > "/root/proxy_configs/client_configs/clash/${USERNAME}_clash.yaml" << EOF
proxies:
  # SOCKS5 direct (3proxy - main port)
  - name: "SOCKS5-Direct-${USERNAME}"
    type: socks5
    server: ${SERVER_IP}
    port: ${SOCKS5_PORT}
    username: ${USERNAME}
    password: ${PASSWORD}
    udp: true

  # SOCKS5 direct (3proxy - alt port)
  - name: "SOCKS5-Direct-Alt-${USERNAME}"
    type: socks5
    server: ${SERVER_IP}
    port: ${SOCKS5_ALT_PORT}
    username: ${USERNAME}
    password: ${PASSWORD}
    udp: true

  # SOCKS5 direct (GOST plain)
  - name: "SOCKS5-GOST-Plain-${USERNAME}"
    type: socks5
    server: ${SERVER_IP}
    port: ${GOST_PLAIN_PORT}
    username: ${USERNAME}
    password: ${PASSWORD}
    udp: true

  # SOCKS5 over TLS (stunnel) - port 1443
  - name: "SOCKS5-Stunnel-${USERNAME}"
    type: socks5
    server: ${SERVER_IP}
    port: ${STUNNEL_PORT}
    username: ${USERNAME}
    password: ${PASSWORD}
    tls: true
    skip-cert-verify: true
    udp: true

  # SOCKS5 over TLS (GOST - PRIORITY) - port 443
  - name: "SOCKS5-GOST-TLS-${USERNAME}"
    type: socks5
    server: ${SERVER_IP}
    port: ${GOST_PORT}
    username: ${USERNAME}
    password: ${PASSWORD}
    tls: true
    skip-cert-verify: true
    udp: true

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "SOCKS5-GOST-TLS-${USERNAME}"
      - "SOCKS5-Stunnel-${USERNAME}"
      - "SOCKS5-Direct-${USERNAME}"
      - "SOCKS5-Direct-Alt-${USERNAME}"
      - "SOCKS5-GOST-Plain-${USERNAME}"
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

        # Shadowrocket URLs
        echo "shadowrocket://add?server=${SERVER_IP}&port=${SOCKS5_PORT}&password=${PASSWORD}&username=${USERNAME}&method=socks5&remarks=SOCKS5-Direct-${USERNAME}" > "/root/proxy_configs/client_configs/shadowrocket/${USERNAME}_direct.txt"
        echo "shadowrocket://add?server=${SERVER_IP}&port=${STUNNEL_PORT}&password=${PASSWORD}&username=${USERNAME}&method=socks5&remarks=SOCKS5-Stunnel-${USERNAME}&tls=1" > "/root/proxy_configs/client_configs/shadowrocket/${USERNAME}_stunnel.txt"
        echo "shadowrocket://add?server=${SERVER_IP}&port=${GOST_PORT}&password=${PASSWORD}&username=${USERNAME}&method=socks5&remarks=SOCKS5-GOST-PRIORITY-${USERNAME}&tls=1" > "/root/proxy_configs/client_configs/shadowrocket/${USERNAME}_gost.txt"
        
        # Universal config
        cat > "/root/proxy_configs/client_configs/universal/${USERNAME}_config.txt" << EOF
========================================
Proxy Configuration for $USERNAME
========================================
Server IP: $SERVER_IP

--- ПРИОРИТЕТНОЕ ПОДКЛЮЧЕНИЕ (рекомендуется) ---
Type: SOCKS5 over TLS (GOST)
Port: $GOST_PORT
Username: $USERNAME
Password: $PASSWORD
TLS: Yes
Skip Cert Verify: Yes
Connection: socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$GOST_PORT

--- АЛЬТЕРНАТИВНОЕ TLS ПОДКЛЮЧЕНИЕ ---
Type: SOCKS5 over TLS (Stunnel)
Port: $STUNNEL_PORT
Username: $USERNAME
Password: $PASSWORD
TLS: Yes
Skip Cert Verify: Yes
Connection: socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$STUNNEL_PORT

--- SOCKS5 Direct (Без шифрования) ---
Вариант 1 (3proxy основной):
  Port: $SOCKS5_PORT
  Connection: socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_PORT

Вариант 2 (3proxy резервный):
  Port: $SOCKS5_ALT_PORT
  Connection: socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_ALT_PORT

Вариант 3 (GOST plain):
  Port: $GOST_PLAIN_PORT
  Connection: socks5://$USERNAME:$PASSWORD@$SERVER_IP:$GOST_PLAIN_PORT

========================================
ИНФОРМАЦИЯ О ПОРТАХ:
========================================
Приоритетный TLS (GOST):  $GOST_PORT (443)
Альтернативный TLS (Stunnel): $STUNNEL_PORT (1443)
Прямые SOCKS5 порты: $SOCKS5_PORT, $SOCKS5_ALT_PORT, $GOST_PLAIN_PORT

========================================
EOF
    done
    
    echo -e "${GREEN}✅ Клиентские конфигурации созданы${NC}"
}

# Create summary
create_summary() {
    SERVER_IP=$(get_server_ip)
    
    cat > /root/proxy_configs/SUMMARY.txt << EOF
========================================
Multi-Proxy v2 - Итоговая информация
========================================
Сервер: $SERVER_IP
Дата настройки: $(date)

========================================
ДОСТУПНЫЕ ПРОКСИ
========================================

1. ★ ПРИОРИТЕТНОЕ ПОДКЛЮЧЕНИЕ ★
   Тип: SOCKS5 over TLS (GOST)
   Порт: $GOST_PORT (443)
   Формат: socks5-tls://user:pass@$SERVER_IP:$GOST_PORT

2. АЛЬТЕРНАТИВНОЕ TLS ПОДКЛЮЧЕНИЕ
   Тип: SOCKS5 over TLS (Stunnel)
   Порт: $STUNNEL_PORT (1443)
   Формат: socks5-tls://user:pass@$SERVER_IP:$STUNNEL_PORT

3. SOCKS5 Direct (без TLS) - 3proxy
   Основной порт: $SOCKS5_PORT
   Резервный порт: $SOCKS5_ALT_PORT
   Формат: socks5://user:pass@$SERVER_IP:порт

4. SOCKS5 Direct (без TLS) - GOST plain
   Порт: $GOST_PLAIN_PORT
   Формат: socks5://user:pass@$SERVER_IP:$GOST_PLAIN_PORT

========================================
ПОЛЬЗОВАТЕЛИ
========================================

EOF

    for i in "${!USERS[@]}"; do
        USERNAME="${USERNAMES[$i]}"
        PASSWORD="${PASSWORDS[$i]}"
        
        cat >> /root/proxy_configs/SUMMARY.txt << EOF
--- $USERNAME ---
Пароль: $PASSWORD

★ ПРИОРИТЕТНОЕ (GOST TLS):
  socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$GOST_PORT

Альтернативное TLS (Stunnel):
  socks5-tls://$USERNAME:$PASSWORD@$SERVER_IP:$STUNNEL_PORT

Прямые подключения:
  socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_PORT
  socks5://$USERNAME:$PASSWORD@$SERVER_IP:$SOCKS5_ALT_PORT
  socks5://$USERNAME:$PASSWORD@$SERVER_IP:$GOST_PLAIN_PORT

EOF
    done

    cat >> /root/proxy_configs/SUMMARY.txt << EOF
========================================
ФАЙЛЫ
========================================
QR коды: /root/proxy_configs/qrcodes/
  - socks5/  - SOCKS5 direct
  - stunnel/ - SOCKS5+TLS (stunnel)
  - gost/    - SOCKS5+TLS (GOST - приоритет)

Конфиги: /root/proxy_configs/client_configs/
  - clash/      - Clash конфиги
  - shadowrocket/ - Shadowrocket ссылки
  - universal/  - Универсальные конфиги

Строки подключения:
  - /root/proxy_configs/socks5/  - SOCKS5 direct
  - /root/proxy_configs/stunnel/ - SOCKS5+TLS (stunnel)
  - /root/proxy_configs/gost/    - SOCKS5+TLS (GOST - приоритет)

========================================
УПРАВЛЕНИЕ СЕРВИСАМИ
========================================

3proxy (SOCKS5 direct):
  systemctl status 3proxy
  systemctl restart 3proxy

Stunnel (SOCKS5+TLS : $STUNNEL_PORT):
  systemctl status $STUNNEL_SERVICE
  systemctl restart $STUNNEL_SERVICE

GOST (SOCKS5+TLS : $GOST_PORT - ПРИОРИТЕТ):
  systemctl status gost
  systemctl restart gost

Проверка портов:
  netstat -tlnp | grep -E "($GOST_PORT|$STUNNEL_PORT|$SOCKS5_PORT|$SOCKS5_ALT_PORT|$GOST_PLAIN_PORT)"

========================================
ЛОГИ
========================================
3proxy:  tail -f /var/log/3proxy/3proxy.log
Stunnel: tail -f /var/log/stunnel/stunnel.log
GOST:    journalctl -u gost -f

========================================
НЕОБХОДИМЫЕ ПОРТЫ ДЛЯ ОТКРЫТИЯ В ФАЕРВОЛЕ
========================================

Вручную откройте следующие порты:
  ★ $GOST_PORT (443) - ПРИОРИТЕТНЫЙ TLS
  ★ $STUNNEL_PORT (1443) - АЛЬТЕРНАТИВНЫЙ TLS
  ★ $SOCKS5_PORT - SOCKS5 прямой (3proxy)
  ★ $SOCKS5_ALT_PORT - SOCKS5 прямой резервный (3proxy)
  ★ $GOST_PLAIN_PORT - SOCKS5 прямой (GOST)

========================================
РЕКОМЕНДАЦИИ
========================================

1. Для максимальной совместимости используйте GOST TLS на порту $GOST_PORT
2. Stunnel на порту $STUNNEL_PORT оставлен как запасной вариант
3. Прямые SOCKS5 порты сгенерированы случайно для дополнительной безопасности

========================================
EOF

    echo -e "${GREEN}✅ Итоговый файл: /root/proxy_configs/SUMMARY.txt${NC}"
}

# Show final summary
show_final_summary() {
    SERVER_IP=$(get_server_ip)
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ НАСТРОЙКА ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Сервер: $SERVER_IP${NC}"
    echo ""
    echo -e "${GREEN}★ ПРИОРИТЕТНОЕ ПОДКЛЮЧЕНИЕ (рекомендуется):${NC}"
    echo -e "  ${GREEN}GOST (SOCKS5+TLS):${NC} socks5-tls://user:pass@$SERVER_IP:$GOST_PORT"
    echo ""
    echo -e "${YELLOW}Альтернативные подключения:${NC}"
    echo -e "  ${YELLOW}Stunnel (SOCKS5+TLS):${NC} socks5-tls://user:pass@$SERVER_IP:$STUNNEL_PORT"
    echo -e "  ${YELLOW}3proxy (SOCKS5 direct):${NC} socks5://user:pass@$SERVER_IP:$SOCKS5_PORT"
    echo -e "  ${YELLOW}3proxy (SOCKS5 direct alt):${NC} socks5://user:pass@$SERVER_IP:$SOCKS5_ALT_PORT"
    echo -e "  ${YELLOW}GOST plain (SOCKS5 direct):${NC} socks5://user:pass@$SERVER_IP:$GOST_PLAIN_PORT"
    echo ""
    echo -e "${YELLOW}Сгенерировано пользователей: ${#USERS[@]}${NC}"
    echo ""
    echo -e "${YELLOW}Все файлы сохранены в: /root/proxy_configs/${NC}"
    echo -e "  📁 QR коды:    /root/proxy_configs/qrcodes/"
    echo -e "  📁 Конфиги:    /root/proxy_configs/client_configs/"
    echo -e "  📁 Строки:     /root/proxy_configs/{socks5,stunnel,gost}/"
    echo -e "  📄 Итог:       /root/proxy_configs/SUMMARY.txt"
    echo ""
    echo -e "${RED}⚠️  ВНИМАНИЕ: Не забудьте открыть порты в фаерволе вручную!${NC}"
    echo -e "${YELLOW}   ★ Приоритетный TLS: $GOST_PORT (443)${NC}"
    echo -e "${YELLOW}   ★ Альтернативный TLS: $STUNNEL_PORT (1443)${NC}"
    echo -e "${YELLOW}   ★ Прямые SOCKS5: $SOCKS5_PORT, $SOCKS5_ALT_PORT, $GOST_PLAIN_PORT${NC}"
    echo ""
    echo -e "${GREEN}========================================${NC}"
}

# Main execution
main() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Пожалуйста, запустите с root правами (используйте sudo)${NC}"
        exit 1
    fi
    
    mkdir -p /root/proxy_configs/{socks5,stunnel,gost,qrcodes,client_configs}
    
    generate_users
    create_certificate
    configure_3proxy
    configure_stunnel
    configure_gost
    generate_connection_strings
    generate_qrcodes
    generate_client_configs
    create_summary
    show_final_summary
}

main