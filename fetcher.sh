#!/bin/bash
# ============================================
# Fetcher & Runner для Multi-Proxy Server
# Скачивает скрипты из GitHub и запускает установку
# Версия: 2.1 (исправленная)
# ============================================

set -euo pipefail  # -e: ошибки, -u: неопределённые переменные, -o pipefail: ошибки в пайпах

# Цвета
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Глобальные переменные
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/fetcher_$(date +%Y%m%d_%H%M%S).log"
ERROR_COUNT=0

# Перехват Ctrl+C
trap 'echo -e "\n${RED}❌ Прервано пользователем${NC}"; exit 1' INT
trap 'echo -e "\n${RED}❌ Ошибка на строке $LINENO${NC}" | tee -a "$LOG_FILE"; exit 1' ERR

# ============================================
# 🛠 НАСТРОЙКИ РЕПОЗИТОРИЯ (ОБЯЗАТЕЛЬНО ЗАМЕНИТЕ!)
# ============================================
GH_USER="naum-mm"
GH_REPO="go-socks"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}"

# Список скриптов (в порядке установки)
declare -a SCRIPTS=("installer.sh" "configurator.sh" "apache.sh" "helper.sh" "cleanup.sh")
DIR_NAME="sosok"

# ============================================
# ФУНКЦИИ
# ============================================

# Функция логирования
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $message" | tee -a "$LOG_FILE" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" | tee -a "$LOG_FILE" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE"; ((ERROR_COUNT++)) ;;
        "STEP")  echo -e "\n${CYAN}▶ $message${NC}" | tee -a "$LOG_FILE" ;;
        *)       echo -e "$message" | tee -a "$LOG_FILE" ;;
    esac
}

# Проверка интернет соединения
check_internet() {
    log "INFO" "Проверка интернет соединения..."
    
    local test_hosts=("google.com" "github.com" "raw.githubusercontent.com")
    local connected=false
    
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            log "INFO" "  ✅ Соединение с $host установлено"
            connected=true
            break
        elif curl -s --max-time 3 "https://$host" &>/dev/null; then
            log "INFO" "  ✅ Соединение с $host установлено (HTTPS)"
            connected=true
            break
        fi
    done
    
    if [ "$connected" = false ]; then
        log "ERROR" "Нет интернет соединения"
        return 1
    fi
    
    return 0
}

# Проверка и установка необходимых утилит
check_required_tools() {
    log "INFO" "Проверка необходимых утилит..."
    
    local missing_tools=()
    
    for tool in curl wget; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "WARN" "Отсутствуют утилиты: ${missing_tools[*]}"
        log "INFO" "Устанавливаем недостающие утилиты..."
        
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y -qq "${missing_tools[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y -q "${missing_tools[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y -q "${missing_tools[@]}"
        else
            log "ERROR" "Не удалось установить утилиты. Установите вручную: ${missing_tools[*]}"
            return 1
        fi
    fi
    
    log "INFO" "✅ Все необходимые утилиты установлены"
    return 0
}

# Проверка прав root (с автоматическим перезапуском)
ensure_root() {
    if [ "$EUID" -ne 0 ]; then
        log "WARN" "Требуются права root. Перезапуск с sudo..."
        
        # Проверяем, можем ли мы использовать sudo
        if command -v sudo &> /dev/null; then
            exec sudo bash "$0" "$@"
        else
            log "ERROR" "Не удалось получить права root. Установите sudo или запустите от root."
            exit 1
        fi
    fi
}

# Проверка доступности репозитория
check_repository() {
    log "STEP" "Проверка доступности репозитория..."
    
    local test_url="${BASE_URL}/installer.sh"
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        log "INFO" "  Попытка $attempt/$max_attempts..."
        
        if command -v curl &> /dev/null; then
            if curl --connect-timeout 10 --max-time 30 -sSf "$test_url" -o /dev/null 2>/dev/null; then
                log "INFO" "  ✅ Репозиторий доступен"
                return 0
            fi
        elif command -v wget &> /dev/null; then
            if wget --timeout=30 --tries=1 -q "$test_url" -O /dev/null 2>/dev/null; then
                log "INFO" "  ✅ Репозиторий доступен"
                return 0
            fi
        fi
        
        log "WARN" "  Попытка $attempt не удалась"
        attempt=$((attempt + 1))
        
        if [ $attempt -le $max_attempts ]; then
            log "INFO" "  Повтор через 5 секунд..."
            sleep 5
        fi
    done
    
    log "ERROR" "Репозиторий недоступен!"
    log "INFO" "Проверьте:"
    log "INFO" "  1. Правильность USERNAME/REPO в скрипте"
    log "INFO" "  2. GH_USER=\"$GH_USER\", GH_REPO=\"$GH_REPO\""
    log "INFO" "  3. Ветка '$GH_BRANCH' существует"
    log "INFO" "  4. Репозиторий публичный"
    log "INFO" "  5. Доступность интернета"
    
    return 1
}

# Функция скачивания файла с retry
download_script() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    local attempt=1
    local backoff=2
    
    while [ $attempt -le $max_attempts ]; do
        log "INFO" "    📄 $output (попытка $attempt/$max_attempts)"
        
        # Пробуем curl
        if command -v curl &> /dev/null; then
            if curl --connect-timeout 10 --max-time 60 -sSf "$url" -o "$output" 2>/dev/null; then
                if [ -s "$output" ]; then
                    # Проверка, что это bash скрипт (начинается с #!)
                    if head -1 "$output" | grep -qE '^#!.*bash'; then
                        log "INFO" "      ✅ Скачан (bash скрипт)"
                        return 0
                    elif [ "$output" = "index.html" ]; then
                        # Для index.html не проверяем shebang
                        return 0
                    else
                        log "WARN" "      ⚠️ Файл не является bash скриптом"
                        rm -f "$output"
                    fi
                else
                    log "WARN" "      ⚠️ Пустой файл"
                fi
            else
                log "WARN" "      ⚠️ Ошибка curl"
            fi
        fi
        
        # Пробуем wget
        if command -v wget &> /dev/null; then
            if wget --timeout=30 --tries=1 -q "$url" -O "$output" 2>/dev/null; then
                if [ -s "$output" ]; then
                    if head -1 "$output" | grep -qE '^#!.*bash'; then
                        log "INFO" "      ✅ Скачан (bash скрипт)"
                        return 0
                    elif [ "$output" = "index.html" ]; then
                        return 0
                    else
                        log "WARN" "      ⚠️ Файл не является bash скриптом"
                        rm -f "$output"
                    fi
                else
                    log "WARN" "      ⚠️ Пустой файл"
                fi
            else
                log "WARN" "      ⚠️ Ошибка wget"
            fi
        fi
        
        attempt=$((attempt + 1))
        if [ $attempt -le $max_attempts ]; then
            log "INFO" "      Повтор через ${backoff} секунд..."
            sleep $backoff
            backoff=$((backoff * 2))  # Экспоненциальная задержка
        fi
    done
    
    log "ERROR" "    ❌ Не удалось скачать $output после $max_attempts попыток"
    return 1
}

# Создание рабочей директории
setup_workspace() {
    log "STEP" "Подготовка рабочей директории..."
    
    local full_path="$(pwd)/$DIR_NAME"
    
    if [ -d "$DIR_NAME" ]; then
        log "WARN" "Директория $DIR_NAME уже существует"
        read -p "  Очистить директорию? (y/n): " CLEAN_CHOICE
        if [[ $CLEAN_CHOICE =~ ^[Yy]$ ]]; then
            rm -rf "$DIR_NAME"
            log "INFO" "  ✅ Директория очищена"
        else
            log "WARN" "  Использую существующую директорию"
        fi
    fi
    
    mkdir -p "$DIR_NAME"
    log "INFO" "  ✅ Рабочая директория: $full_path"
    
    return 0
}

# Скачивание всех скриптов
download_all_scripts() {
    log "STEP" "Скачивание компонентов..."
    
    local failed=0
    
    for script in "${SCRIPTS[@]}"; do
        if ! download_script "${BASE_URL}/${script}" "$script"; then
            failed=1
            break
        fi
        chmod +x "$script"
    done
    
    if [ $failed -ne 0 ]; then
        log "ERROR" "Не удалось скачать все компоненты"
        return 1
    fi
    
    # Проверка, что все скрипты скачались
    local missing_scripts=()
    for script in "${SCRIPTS[@]}"; do
        if [ ! -f "$script" ] || [ ! -s "$script" ]; then
            missing_scripts+=("$script")
        fi
    done
    
    if [ ${#missing_scripts[@]} -ne 0 ]; then
        log "ERROR" "Отсутствуют скрипты: ${missing_scripts[*]}"
        return 1
    fi
    
    log "INFO" "✅ Все скрипты успешно скачаны (${#SCRIPTS[@]} файлов)"
    return 0
}

# Запуск скрипта с обработкой ошибок
run_script() {
    local script="$1"
    local script_name="$2"
    
    log "STEP" "$script_name"
    
    if [ ! -f "$script" ]; then
        log "ERROR" "Скрипт $script не найден"
        return 1
    fi
    
    # Запускаем скрипт в subshell, чтобы не прерывать основной скрипт при ошибке
    set +e
    bash "./$script"
    local exit_code=$?
    set -e
    
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "Ошибка в $script (код: $exit_code)"
        return 1
    fi
    
    log "INFO" "✅ $script_name завершен успешно"
    return 0
}

# Запуск Apache скрипта (опционально)
run_apache_setup() {
    echo -e "\n${BLUE}3️⃣  apache.sh (веб-интерфейс для раздачи конфигов)${NC}"
    echo -e "${YELLOW}   Apache предоставит веб-доступ к конфигурациям и QR кодам${NC}"
    read -p "   Установить и настроить Apache веб-сервер? (y/n): " APACHE_CHOICE
    
    if [[ $APACHE_CHOICE =~ ^[Yy]$ ]]; then
        if run_script "apache.sh" "Настройка Apache"; then
            log "INFO" "✅ Apache успешно установлен и настроен"
            return 0
        else
            log "WARN" "⚠️ Apache установлен с ошибками, но прокси сервер работает"
            return 0  # Не прерываем установку из-за Apache
        fi
    else
        log "INFO" "⏭️ Apache пропущен. Вы можете запустить позже: sudo bash ./apache.sh"
        return 0
    fi
}

# Создание alias для быстрого доступа
create_alias() {
    local helper_path="$(realpath "$DIR_NAME")/helper.sh"
    
    if [ -f ~/.bashrc ] && ! grep -q "alias multiproxy=" ~/.bashrc 2>/dev/null; then
        echo -e "\n${BLUE}💡 Хотите добавить alias для быстрого доступа?${NC}"
        echo -e "   Alias 'multiproxy' позволит быстро запускать менеджер пользователей"
        read -p "   Добавить 'multiproxy' в ~/.bashrc? (y/n): " ALIAS_CHOICE
        
        if [[ $ALIAS_CHOICE =~ ^[Yy]$ ]]; then
            echo "alias multiproxy='sudo bash $helper_path'" >> ~/.bashrc
            log "INFO" "✅ Alias добавлен! Перезайдите или выполните: source ~/.bashrc"
        fi
    fi
}

# Показать итоговую информацию
show_summary() {
    local workspace_path="$(realpath "$DIR_NAME")"
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    if [ $ERROR_COUNT -gt 0 ]; then
        echo -e "${YELLOW}⚠️ Установка завершена с ${ERROR_COUNT} предупреждениями${NC}"
        echo ""
    fi
    
    echo -e "${YELLOW}📂 Расположение файлов:${NC}"
    echo -e "   Все скрипты: ${GREEN}$workspace_path${NC}"
    echo ""
    
    echo -e "${YELLOW}🔧 Управление:${NC}"
    echo -e "   👤 Управление пользователями: ${GREEN}sudo bash $workspace_path/helper.sh${NC}"
    echo -e "   🧹 Полная очистка системы:    ${GREEN}sudo bash $workspace_path/cleanup.sh${NC}"
    echo -e "   🌐 Переустановка Apache:      ${GREEN}sudo bash $workspace_path/apache.sh${NC}"
    echo ""
    
    if [ -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}📋 Полный лог установки: $LOG_FILE${NC}"
    fi
    
    echo -e "\n${GREEN}🔥 Сервер настроен и готов к работе!${NC}"
    echo -e "${YELLOW}💡 Рекомендации:${NC}"
    echo -e "   1. Проверьте статус сервисов: systemctl status 3proxy gost stunnel"
    echo -e "   2. Откройте необходимые порты в фаерволе"
    echo -e "   3. Просмотрите SUMMARY.txt: cat /root/proxy_configs/SUMMARY.txt"
    echo ""
}

# Очистка при ошибке
cleanup_on_error() {
    log "ERROR" "Установка прервана"
    
    if [ -d "$DIR_NAME" ]; then
        echo -e "\n${YELLOW}Оставить файлы для отладки?${NC}"
        read -p "  Оставить директорию $DIR_NAME? (y/n): " KEEP_FILES
        if [[ ! $KEEP_FILES =~ ^[Yy]$ ]]; then
            rm -rf "$DIR_NAME"
            log "INFO" "  ✅ Временные файлы удалены"
        else
            log "INFO" "  📁 Файлы сохранены в: $(realpath "$DIR_NAME")"
        fi
    fi
    
    if [ -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}📋 Лог ошибок: $LOG_FILE${NC}"
    fi
}

# ============================================
# ОСНОВНАЯ ЛОГИКА
# ============================================

main() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  📦 Multi-Proxy Server - Fetcher v2.1${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    
    # Проверка, что пользователь заменил настройки
    if [[ "$GH_USER" == "YOUR_USERNAME" ]] || [[ "$GH_REPO" == "YOUR_REPO_NAME" ]]; then
        echo -e "${RED}❌ ОШИБКА: Вы не заменили настройки репозитория!${NC}"
        echo -e "${YELLOW}📝 Отредактируйте скрипт и укажите:${NC}"
        echo "   GH_USER=\"ваш_username\""
        echo "   GH_REPO=\"ваш_repo\""
        echo ""
        echo -e "${YELLOW}Пример:${NC}"
        echo "   GH_USER=\"john_doe\""
        echo "   GH_REPO=\"proxy-scripts\""
        exit 1
    fi
    
    log "INFO" "📝 Лог установки: $LOG_FILE"
    log "INFO" "Репозиторий: $GH_USER/$GH_REPO (ветка: $GH_BRANCH)"
    
    # Базовые проверки
    ensure_root "$@"
    
    if ! check_internet; then
        exit 1
    fi
    
    if ! check_required_tools; then
        exit 1
    fi
    
    if ! check_repository; then
        exit 1
    fi
    
    # Создаем рабочую директорию и переходим в нее
    if ! setup_workspace; then
        exit 1
    fi
    
    # Переходим в директорию и выполняем все в subshell
    (
        cd "$DIR_NAME" || exit 1
        
        # Скачиваем скрипты
        if ! download_all_scripts; then
            exit 1
        fi
        
        # Запускаем установку в правильном порядке
        log "STEP" "Запуск установки в правильном порядке"
        
        # 1. installer.sh - установка пакетов
        if ! run_script "installer.sh" "Установка пакетов и сервисов"; then
            exit 1
        fi
        
        # 2. configurator.sh - настройка прокси
        if ! run_script "configurator.sh" "Настройка прокси и генерация пользователей"; then
            exit 1
        fi
        
        # 3. apache.sh - опционально
        if ! run_apache_setup; then
            # Не выходим с ошибкой, Apache опционален
            log "WARN" "Apache не настроен, но прокси сервер работает"
        fi
        
        exit 0
    )
    
    # Проверка результата subshell
    SUBSHELL_EXIT=$?
    if [ $SUBSHELL_EXIT -ne 0 ]; then
        cleanup_on_error
        exit $SUBSHELL_EXIT
    fi
    
    # Создаем alias и показываем итоги
    create_alias
    show_summary
    
    exit 0
}

# Запуск main функции
main "$@"
