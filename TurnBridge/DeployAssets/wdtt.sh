#!/bin/bash
# ==============================================================================
#  WDTT VPN Server — Универсальный установщик для VPS
#  Source: https://github.com/amurcanov/proxy-turn-vk-android
#  Imported commit: c01fadd7d810cfb9d53598005f900674449a928e
#  Поддержка: Debian 11+, Ubuntu 20.04+, CentOS/RHEL/Fedora/AlmaLinux/Rocky
#  Версия: 3.2  |  Дата: 2026-05-13
#  NAT:  MASQUERADE через iptables
#  WG:   порт 56001 (не конфликтует с существующим WG на 51820)
#  DTLS: порт 56000
# ==============================================================================
set -uo pipefail

readonly SCRIPT_VERSION="3.2"
readonly LOG_FILE="/var/log/wdtt-install.log"
readonly WG_PORT="${WDTT_WG_PORT:-56001}"
readonly DTLS_PORT="${WDTT_DTLS_PORT:-56000}"
readonly SSH_PORT="${WDTT_SSH_PORT:-22}"
readonly WDTT_ARGS="${WDTT_ARGS:-}"
readonly WDTT_IFACE="wdtt0"
readonly WDTT_CONFIG_DIR="/etc/wdtt"
readonly WDTT_ACCESS_DB="passwords.json"
readonly IPT_COMMENT="WDTT_MANAGED"
readonly IPT_MIRROR_COMMENT="WDTT_MIRRORED"

validate_port() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) die "$name должен быть числом от 1 до 65535, получено: $value" ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        die "$name должен быть в диапазоне 1..65535, получено: $value"
    fi
}

C_GREEN=''; C_YELLOW=''; C_RED=''
C_CYAN='';  C_BOLD='';      C_NC=''

log_info()  { echo -e "${C_GREEN}[✓]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${C_YELLOW}[!]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${C_RED}[✗]${C_NC} $*" | tee -a "$LOG_FILE"; }
log_step()  { echo -e "${C_CYAN}[►]${C_NC} ${C_BOLD}$*${C_NC}" | tee -a "$LOG_FILE"; }

die() { log_error "$*"; exit 1; }

prog() { echo "WDTT_PROGRESS|$1|$2"; }

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "Скрипт должен быть запущен от root. Если sudo отсутствует, зайдите под root и запустите: bash $0 $*"
    fi
}

OS_ID="" ; PKG_MGR=""

detect_os() {
    log_step "Определение операционной системы..."
    if [ ! -f /etc/os-release ]; then
        die "Файл /etc/os-release не найден."
    fi
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop)     PKG_MGR="apt" ;;
        centos|rhel|rocky|almalinux|oracle) PKG_MGR="yum"
            command -v dnf &>/dev/null && PKG_MGR="dnf" ;;
        fedora)                          PKG_MGR="dnf" ;;
        arch|manjaro|endeavouros)        PKG_MGR="pacman" ;;
        *) die "Неподдерживаемый дистрибутив: $OS_ID" ;;
    esac
    log_info "ОС: ${PRETTY_NAME:-$OS_ID} | PM: $PKG_MGR"
}

pkg_update_done=0

pkg_update() {
    [ "$pkg_update_done" = "1" ] && return 0
    log_step "Обновление индексов пакетов..."
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >>"$LOG_FILE" 2>&1 || log_warn "apt update завершился с ошибкой, пробую продолжить"
            ;;
        dnf)    dnf makecache -y >>"$LOG_FILE" 2>&1 || true ;;
        yum)    yum makecache -y >>"$LOG_FILE" 2>&1 || true ;;
        pacman) pacman -Sy --noconfirm >>"$LOG_FILE" 2>&1 || true ;;
    esac
    pkg_update_done=1
}

pkg_install() {
    [ "$#" -eq 0 ] && return 0
    case "$PKG_MGR" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y -qq "$@" >>"$LOG_FILE" 2>&1
            ;;
        dnf)    dnf install -y "$@" >>"$LOG_FILE" 2>&1 ;;
        yum)    yum install -y "$@" >>"$LOG_FILE" 2>&1 ;;
        pacman) pacman -S --noconfirm --needed "$@" >>"$LOG_FILE" 2>&1 ;;
    esac
}

install_prerequisites() {
    prog 0.08 "Пакеты..."
    pkg_update
    log_step "Установка базовых зависимостей..."

    case "$PKG_MGR" in
        apt)
            pkg_install ca-certificates iproute2 iptables nftables procps psmisc jq || \
                log_warn "Часть apt-пакетов не установилась, продолжаю с доступными утилитами"
            ;;
        dnf|yum)
            pkg_install ca-certificates iproute iptables nftables procps-ng psmisc jq || \
                log_warn "Часть rpm-пакетов не установилась, продолжаю с доступными утилитами"
            ;;
        pacman)
            pkg_install ca-certificates iproute2 iptables nftables procps-ng psmisc jq || \
                log_warn "Часть pacman-пакетов не установилась, продолжаю с доступными утилитами"
            ;;
    esac
}

require_runtime_tools() {
    command -v ip >/dev/null 2>&1 || die "Команда ip не найдена. Установите iproute2/iproute."
    command -v systemctl >/dev/null 2>&1 || die "systemctl не найден. Нужен VPS с systemd."
}

detect_wan_interface() {
    local iface=""
    iface=$(ip route show default 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [ -z "$iface" ] && iface=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1)
    [ -z "$iface" ] && iface=$(ls /sys/class/net/ | grep -v lo | head -1)
    echo "$iface"
}

FW_BACKEND=""

iptables_add_input() {
    local proto="$1" port="$2" comment="$3"
    [ "$FW_BACKEND" = "iptables" ] || return 0
    case "$proto:$port" in
        tcp:[0-9]*|udp:[0-9]*) ;;
        *) return 0 ;;
    esac
    [ "$port" -ge 1 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null || return 0
    iptables -C INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT 2>/dev/null || true
}

mirror_port_to_iptables() {
    local proto="$1" port="$2" source="$3"
    iptables_add_input "$proto" "$port" "$IPT_MIRROR_COMMENT"
    log_info "iptables: сохранён доступ $port/$proto из $source"
}

mirror_existing_firewall_ports_to_iptables() {
    [ "$FW_BACKEND" = "iptables" ] || return 0
    local tmp
    tmp="$(mktemp)"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
        log_info "UFW активен: переношу разрешённые tcp/udp порты в iptables"
        ufw status 2>/dev/null | sed -nE 's#^([0-9]{1,5})/(tcp|udp)[[:space:]].*ALLOW IN.*#\2 \1 ufw#p' >> "$tmp" || true
    fi

    if command -v nft >/dev/null 2>&1; then
        local nft_ports
        nft_ports="$(nft -a list ruleset 2>/dev/null | sed -nE 's/.*(tcp|udp) dport ([0-9]{1,5}).*accept.*/\1 \2 nft/p' | sort -u || true)"
        if [ -n "$nft_ports" ]; then
            log_info "nftables найден: переношу простые accept dport правила в iptables"
            printf '%s\n' "$nft_ports" >> "$tmp"
        fi
    fi

    if [ -s "$tmp" ]; then
        sort -u "$tmp" | while read -r proto port source; do
            mirror_port_to_iptables "$proto" "$port" "$source"
        done
    else
        log_info "UFW/nftables разрешённых tcp/udp портов для переноса не найдено"
    fi
    rm -f "$tmp"
}

detect_firewall() {
    if ! command -v iptables &>/dev/null; then
        log_warn "iptables не найден. Пытаюсь установить firewall-пакеты..."
        pkg_update
        pkg_install iptables nftables || true
    fi
    if command -v iptables &>/dev/null; then
        FW_BACKEND="iptables"
        log_info "Firewall backend: iptables (принудительно)"
        mirror_existing_firewall_ports_to_iptables
    else
        FW_BACKEND="none"
        log_warn "iptables не найден. Установка продолжится, но NAT/firewall нужно настроить вручную."
    fi
}

fw_add_input_udp() {
    local port="$1"
    [ "$FW_BACKEND" = "iptables" ] || return 0
    iptables -C INPUT -p udp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
}

fw_add_input_tcp() {
    local port="$1"
    [ "$FW_BACKEND" = "iptables" ] || return 0
    iptables -C INPUT -p tcp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
}

fw_add_forward() {
    [ "$FW_BACKEND" = "iptables" ] || return 0
    iptables -C FORWARD -i "$WDTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i "$WDTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -o "$WDTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -o "$WDTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
}

fw_add_nat() {
    [ "$FW_BACKEND" = "iptables" ] || return 0
    local ext_if="$1"
    [ -n "$ext_if" ] || return 0
    iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o "$ext_if" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -I POSTROUTING 1 -s 10.66.66.0/24 -o "$ext_if" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || true
}

fw_cleanup() {
    if [ "$FW_BACKEND" = "iptables" ]; then
        iptables -D INPUT -p udp --dport "$DTLS_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$WG_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p tcp --dport "$SSH_PORT" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$WDTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -o "$WDTT_IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || true
        local ext_if
        ext_if="$(detect_wan_interface || true)"
        [ -n "$ext_if" ] && iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o "$ext_if" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || true
    fi
}

install_server() {
    prog 0.15 "Зависимости..."
    install_prerequisites
    require_runtime_tools
    detect_firewall

    prog 0.30 "Остановка старой службы..."
    systemctl stop wdtt 2>/dev/null || true
    pkill -f '/usr/local/bin/wdtt-server' 2>/dev/null || true
    ip link show "$WDTT_IFACE" >/dev/null 2>&1 && ip link del "$WDTT_IFACE" 2>/dev/null || true

    prog 0.45 "Установка бинарника..."
    install -m 0755 /tmp/wdtt-server /usr/local/bin/wdtt-server
    mkdir -p "$WDTT_CONFIG_DIR"
    chmod 700 "$WDTT_CONFIG_DIR"

    prog 0.60 "Настройка firewall..."
    fw_add_input_udp "$DTLS_PORT"
    fw_add_input_udp "$WG_PORT"
    fw_add_input_tcp "$SSH_PORT"
    fw_add_forward
    fw_add_nat "$(detect_wan_interface || true)"

    prog 0.75 "Создание systemd unit..."
    cat > /etc/systemd/system/wdtt.service <<EOF
[Unit]
Description=WDTT Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/env bash -c "ip link show ${WDTT_IFACE} >/dev/null 2>&1 && ip link del ${WDTT_IFACE} 2>/dev/null || true"
ExecStart=/usr/local/bin/wdtt-server -listen 0.0.0.0:${DTLS_PORT} -wg-port ${WG_PORT} -config-dir ${WDTT_CONFIG_DIR} ${WDTT_ARGS}
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    prog 0.90 "Запуск..."
    systemctl daemon-reload
    systemctl enable wdtt >/dev/null 2>&1 || true
    systemctl restart wdtt
    sleep 2
    systemctl is-active --quiet wdtt || die "Служба wdtt не запустилась"

    prog 1.00 "Готово"
    log_info "WDTT установлен и запущен."
}

uninstall_server() {
    log_step "Удаление WDTT..."
    systemctl stop wdtt 2>/dev/null || true
    systemctl disable wdtt 2>/dev/null || true
    rm -f /etc/systemd/system/wdtt.service
    systemctl daemon-reload 2>/dev/null || true
    pkill -f '/usr/local/bin/wdtt-server' 2>/dev/null || true
    ip link show "$WDTT_IFACE" >/dev/null 2>&1 && ip link del "$WDTT_IFACE" 2>/dev/null || true
    fw_cleanup
    rm -f /usr/local/bin/wdtt-server
    log_info "WDTT удалён."
}

status_server() {
    echo "Статус WDTT:"
    systemctl status wdtt --no-pager -n 20 2>&1 || true
    echo
    echo "Слушающие порты:"
    ss -lunp 2>/dev/null | grep -E "(:${DTLS_PORT}|:${WG_PORT})" || true
    echo
    echo "Интерфейс:"
    ip addr show "$WDTT_IFACE" 2>&1 || true
}

main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || true
    validate_port "WDTT_DTLS_PORT" "$DTLS_PORT"
    validate_port "WDTT_WG_PORT" "$WG_PORT"
    validate_port "WDTT_SSH_PORT" "$SSH_PORT"
    check_root "$@"

    action="${1:-install}"
    case "$action" in
        install) install_server ;;
        uninstall) uninstall_server ;;
        status) status_server ;;
        *) die "Неизвестное действие: $action" ;;
    esac
}

main "$@"
