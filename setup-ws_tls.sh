#!/usr/bin/env bash
# Интерактивная, повторяемая настройка origin-ноды RemnaNode.
# Скрипт настраивает Linux-хост, генерирует конфиг inbound и Caddy, но НЕ входит
# в Remnawave Panel и НЕ изменяет Config Profile автоматически.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="3.0.0"
BACKUP_DIR=""
LOCK_FILE=/run/ws-node-setup.lock
STATE_FILE=/root/.ws-node-setup.conf
GENERATED_DIR=/root/ws-node-generated
# Переопределяется в тестах, чтобы сгенерировать конфиг, не трогая рабочий.
CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
REPORT_FILE=/root/ws-node-report.txt
LOG_FILE=/var/log/ws-node-setup.log
SKIP_LISTENER_CHECK=0
ASSUME_YES=0
STATUS_ONLY=0
USE_COLOR=auto

# ---------------------------------------------------------------- аргументы --
usage() {
  cat <<'EOF'
Использование: setup-ws_tls.sh [опции]

Интерактивная настройка Caddy + TLS для VLESS WebSocket origin.
Config Profile Remnawave скрипт не изменяет.

Опции:
  --skip-listener-check   не ждать появления listener Xray
  --assume-yes, -y        отвечать "да" на все подтверждения
  --status                только показать сохранённое состояние и прогнать
                          проверки, ничего не изменяя
  --no-color              отключить цветной вывод
  --version               показать версию
  -h, --help              эта справка
EOF
}

for arg in "${@:-}"; do
  case "$arg" in
    "") ;;
    --skip-listener-check) SKIP_LISTENER_CHECK=1 ;;
    -y|--assume-yes)       ASSUME_YES=1 ;;
    --status)              STATUS_ONLY=1 ;;
    --no-color)            USE_COLOR=never ;;
    --version)             echo "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------- палитра --
if [ "$USE_COLOR" = never ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_RESET= C_BOLD= C_DIM= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_CYAN= C_MAGENTA=
else
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
  C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m';  C_MAGENTA=$'\033[35m'
fi

STEP_TOTAL=12
STEP_CUR=0
# Очистка до конца строки нужна только в терминале; в логе это мусор.
[ -n "$C_RESET" ] && C_CLR=$'\033[K' || C_CLR=""

hr()   { printf '%b%s%b\n' "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET"; }
step() {
  STEP_CUR=$((STEP_CUR + 1))
  printf '\n%b[%d/%d]%b %b%s%b\n' \
    "$C_BOLD$C_BLUE" "$STEP_CUR" "$STEP_TOTAL" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
  hr
}
info() { printf '  %b•%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
die()  { printf '\n%bОШИБКА:%b %s\n' "$C_BOLD$C_RED" "$C_RESET" "$*" >&2; exit 1; }
# Пишем в stdout, а не stderr: иначе при перенаправлении в файл или пайп
# предупреждения всплывают не на своём месте относительно остального вывода.
warn() { printf '  %b!%b %s\n' "$C_BOLD$C_YELLOW" "$C_RESET" "$*"; }

CHECK_PASS=0; CHECK_WARN=0; CHECK_FAIL=0
ok()     { printf '  %b✔%b %s\n' "$C_GREEN"  "$C_RESET" "$*"; CHECK_PASS=$((CHECK_PASS+1)); }
soft()   { printf '  %b!%b %s\n' "$C_YELLOW" "$C_RESET" "$*"; CHECK_WARN=$((CHECK_WARN+1)); }
bad()    { printf '  %b✘%b %s\n' "$C_RED"    "$C_RESET" "$*"; CHECK_FAIL=$((CHECK_FAIL+1)); }

trap 'rc=$?; [ $rc -eq 0 ] || printf "\n%bСБОЙ%b на строке %s (код %s). Бэкап: %s\n" \
      "$C_BOLD$C_RED" "$C_RESET" "$LINENO" "$rc" "${BACKUP_DIR:-нет}" >&2' ERR

# ------------------------------------------------------------- прогресс-бары --
# Полоса прогресса для операций с известным числом шагов.
progress_bar() {
  local cur="$1" total="$2" label="${3-}" width=32 filled empty pct
  pct=$(( cur * 100 / total ))
  filled=$(( cur * width / total ))
  empty=$(( width - filled ))
  printf '\r  %b[%b%s%b%s%b]%b %3d%%  %s%s' \
    "$C_DIM" "$C_RESET$C_GREEN" \
    "$(printf '%*s' "$filled" '' | tr ' ' '=')" \
    "$C_DIM" "$(printf '%*s' "$empty" '' | tr ' ' '·')" \
    "$C_DIM" "$C_RESET" "$pct" "$label" "$C_CLR"
}
progress_done() { printf '\n'; }

# Спиннер для операций с неизвестной длительностью. Вывод команды пишется в лог.
spin_run() {
  local label="$1"; shift
  local out rc=0 pid i=0
  # Метка обязана быть однострочной: с IFS=$'\n\t' конструкции вида "${arr[*]}"
  # склеиваются переводом строки и разносят спиннер по экрану.
  label="${label//$'\n'/ }"
  out="$(mktemp)"
  ( "$@" ) >"$out" 2>&1 &
  pid=$!
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %b%s%b %s' "$C_CYAN" "${frames:$((i % 10)):1}" "$C_RESET" "$label"
    i=$((i + 1))
    sleep 0.12
  done
  wait "$pid" || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '\r  %b✔%b %s%s\n' "$C_GREEN" "$C_RESET" "$label" "$C_CLR"
  else
    printf '\r  %b✘%b %s (код %s)%s\n' "$C_RED" "$C_RESET" "$label" "$rc" "$C_CLR"
    sed 's/^/      /' "$out" || true
  fi
  cat "$out" >>"$LOG_FILE" 2>/dev/null || true
  rm -f "$out"
  return "$rc"
}

# ------------------------------------------------------------------- вводные --
command -v id >/dev/null || die "не найден id"
[ "$(id -u)" -eq 0 ] || die "запустите от root"
[ -r /etc/os-release ] || die "не найден /etc/os-release"

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
: >>"$LOG_FILE" || LOG_FILE=/dev/null
printf '\n===== %s : запуск v%s =====\n' "$(date -Is)" "$SCRIPT_VERSION" >>"$LOG_FILE"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "другая установка уже выполняется"
fi

printf '\n%b╔══════════════════════════════════════════════════════════╗%b\n' "$C_BOLD$C_MAGENTA" "$C_RESET"
printf '%b║%b  %bWS/TLS origin node setup%b  %bv%-8s%b                     %b║%b\n' \
  "$C_BOLD$C_MAGENTA" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_DIM" "$SCRIPT_VERSION" "$C_RESET" \
  "$C_BOLD$C_MAGENTA" "$C_RESET"
printf '%b╚══════════════════════════════════════════════════════════╝%b\n' "$C_BOLD$C_MAGENTA" "$C_RESET"

# --------------------------------------------------------------- ввод/состояние --
# Читаем с /dev/tty: функции вызываются через $(...), обычный stdin захвачен
# command substitution, а сам скрипт может быть запущен через пайп.
# Проверять `[ -r /dev/tty ]` нельзя: права на устройстве разрешают чтение всем,
# и тест проходит даже без управляющего терминала. Пробуем открыть его реально.
if { true >/dev/tty; } 2>/dev/null; then HAS_TTY=1; else HAS_TTY=0; fi

_tty_read() {
  local __var="$1" __value=""
  if [ "$HAS_TTY" -eq 1 ]; then IFS= read -r __value </dev/tty || true
  else IFS= read -r __value || true; fi
  printf -v "$__var" '%s' "$__value"
}
_tty_out() {
  if [ "$HAS_TTY" -eq 1 ]; then printf '%b' "$*" >/dev/tty; else printf '%b' "$*" >&2; fi
}

ask() {
  local prompt="$1" default="${2-}" value
  if [ -n "$default" ]; then
    _tty_out "  ${C_CYAN}?${C_RESET} ${prompt} ${C_DIM}[${default}]${C_RESET}: "
  else
    _tty_out "  ${C_CYAN}?${C_RESET} ${prompt}: "
  fi
  _tty_read value
  printf '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt="$1" default="${2:-N}" value hint
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  case "$default" in [Yy]*) hint="Y/n" ;; *) hint="y/N" ;; esac
  while :; do
    _tty_out "  ${C_CYAN}?${C_RESET} ${prompt} ${C_DIM}[${hint}]${C_RESET}: "
    _tty_read value
    value="${value:-$default}"
    case "${value,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
    esac
    _tty_out "    ${C_YELLOW}Введите y или n.${C_RESET}\n"
  done
}

state_get() {
  local key="$1" fallback="${2-}" value
  value="$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$STATE_FILE" 2>/dev/null || true)"
  printf '%s' "${value:-$fallback}"
}

valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
# Ограничиваем WS_PATH безопасным набором символов: он попадает в Caddyfile,
# где {, } и пробелы имеют синтаксическое значение.
valid_path()   { [[ "$1" =~ ^(/[A-Za-z0-9._~-]+)+/?$ ]]; }
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_ipv4()   { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$1" =~ (^|\.)([3-9][0-9]{2}|2[6-9][0-9]|25[6-9])(\.|$) ]]; }

# --------------------------------------------------------------- утилиты сети --
detect_public_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    for src in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      ip="$(curl -4fsS --connect-timeout 3 --max-time 5 "$src" 2>/dev/null | tr -d '[:space:]' || true)"
      valid_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
    done
  fi
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  printf '%s' "$ip"
}

resolve_a() {
  local domain="$1" resolver out
  if command -v dig >/dev/null 2>&1; then
    for resolver in 1.1.1.1 8.8.8.8; do
      out="$(dig +short +time=2 +tries=1 A "$domain" @"$resolver" 2>/dev/null || true)"
      printf '%s\n' "$out" | awk '/^[0-9]+(\.[0-9]+){3}$/'
    done | sort -u
  else
    getent ahostsv4 "$domain" 2>/dev/null | awk '/STREAM/{print $1}' | sort -u
  fi
}

resolve_aaaa() {
  command -v dig >/dev/null 2>&1 || return 0
  dig +short +time=2 +tries=1 AAAA "$1" @1.1.1.1 2>/dev/null | awk '/:/' || true
}

# Возвращает процесс, слушающий указанный порт (любой адрес), или пусто.
port_owner() {
  ss -lntpH 2>/dev/null | awk -v p="$1" '
    { n = split($4, a, ":"); if (a[n] == p) { print $NF; exit } }' || true
}
# Возвращает адрес:порт listener-а Xray на нужном порту, или пусто.
xray_listener() {
  ss -lntH 2>/dev/null | awk -v p="$1" '
    { n = split($4, a, ":"); if (a[n] == p && $4 !~ /^\[?::1?\]?:/) { print $4; exit } }' || true
}
# Код ответа на попытку WebSocket-апгрейда. Работает и для 101, и для 4xx.
ws_status() {
  curl -ksS --http1.1 --max-time 5 -o /dev/null -D - \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "$1" 2>/dev/null | awk 'NR==1{print $2; exit}' || true
}

# ====================================================================== СТАТУС ==
if [ "$STATUS_ONLY" -eq 1 ]; then
  STEP_TOTAL=3
  step "Сохранённое состояние"
  if [ -f "$STATE_FILE" ]; then
    while IFS= read -r line; do info "$line"; done <"$STATE_FILE"
  else
    warn "состояние не найдено: $STATE_FILE"
  fi
  if [ -f "$REPORT_FILE" ]; then
    step "Последний отчёт"
    cat "$REPORT_FILE"
  fi
  ORIGIN_DOMAIN="$(state_get ORIGIN_DOMAIN)"
  ORIGIN_TLS_PORT="$(state_get ORIGIN_TLS_PORT 443)"
  XRAY_WS_PORT="$(state_get XRAY_WS_PORT 18083)"
  WS_PATH="$(state_get WS_PATH)"
  if [ -n "$ORIGIN_DOMAIN" ]; then
    step "Живые проверки"
    l="$(xray_listener "$XRAY_WS_PORT")"
    [ -n "$l" ] && ok "listener Xray: $l" || bad "нет listener на порту $XRAY_WS_PORT"
    [ -n "$l" ] && {
      c="$(ws_status "http://127.0.0.1:$XRAY_WS_PORT$WS_PATH")"
      [ "$c" = 101 ] && ok "Xray отвечает 101 напрямую" || bad "Xray напрямую отдал: ${c:-нет ответа}"
    }
    h="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 6 "https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT/healthz" 2>/dev/null || true)"
    [ "$h" = 200 ] && ok "healthz: 200" || bad "healthz: ${h:-нет ответа}"
    w="$(ws_status "https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT$WS_PATH")"
    [ "$w" = 101 ] && ok "WebSocket через TLS: 101" || bad "WebSocket через TLS: ${w:-нет ответа}"
  fi
  printf '\n  %bИтог:%b %b%d ok%b, %b%d предупр.%b, %b%d ошибок%b\n\n' \
    "$C_BOLD" "$C_RESET" "$C_GREEN" "$CHECK_PASS" "$C_RESET" \
    "$C_YELLOW" "$CHECK_WARN" "$C_RESET" "$C_RED" "$CHECK_FAIL" "$C_RESET"
  [ "$CHECK_FAIL" -eq 0 ] || exit 3
  exit 0
fi

# ============================================================== 1. ПАРАМЕТРЫ ==
step "Параметры"
info "Последние значения подставляются автоматически из $STATE_FILE"

PREV_DOMAIN="$(state_get ORIGIN_DOMAIN)"
PREV_PATH="$(state_get WS_PATH)"
PREV_TLS_PORT="$(state_get ORIGIN_TLS_PORT 443)"
PREV_WS_PORT="$(state_get XRAY_WS_PORT 18083)"
PREV_RELAY_IP="$(state_get RELAY_IP)"

NODE_IP="$(detect_public_ipv4)"
[ -n "$NODE_IP" ] || die "не удалось определить публичный IPv4 этого сервера"

printf '\n  %bПеред продолжением подготовьте DNS-запись:%b\n' "$C_BOLD" "$C_RESET"
printf '    %bТип:%b       A\n'        "$C_DIM" "$C_RESET"
printf '    %bИмя:%b       домен ноды (введёте ниже)\n' "$C_DIM" "$C_RESET"
printf '    %bЗначение:%b  %b%s%b\n'   "$C_DIM" "$C_RESET" "$C_BOLD$C_GREEN" "$NODE_IP" "$C_RESET"
printf '    %bTTL:%b       300 (или Auto)\n\n' "$C_DIM" "$C_RESET"
printf '  %bБез CDN/прокси.%b Если IPv6 не настроен — удалите AAAA-запись.\n\n' "$C_YELLOW" "$C_RESET"

ORIGIN_DOMAIN="$(ask 'Домен origin' "$PREV_DOMAIN")"
valid_domain "$ORIGIN_DOMAIN" || die "некорректное доменное имя: $ORIGIN_DOMAIN"

WS_PATH="$(ask 'Уникальный WS_PATH (начинается с /)' "$PREV_PATH")"
valid_path "$WS_PATH" || die "некорректный WS_PATH: допустимы буквы, цифры и . _ ~ - в сегментах пути"

ORIGIN_TLS_PORT="$(ask 'TLS-порт origin' "$PREV_TLS_PORT")"
valid_port "$ORIGIN_TLS_PORT" || die "некорректный TLS-порт"

XRAY_WS_PORT="$(ask 'Локальный порт Xray WS' "$PREV_WS_PORT")"
valid_port "$XRAY_WS_PORT" || die "некорректный WS-порт"
[ "$XRAY_WS_PORT" != "$ORIGIN_TLS_PORT" ] || die "порт Xray и TLS-порт не могут совпадать"

RELAY_IP="$(ask 'IP общего relay (пусто = не ограничивать порт)' "$PREV_RELAY_IP")"
[ -z "$RELAY_IP" ] || valid_ipv4 "$RELAY_IP" || die "некорректный IPv4 relay"

printf '\n'
info "Домен:      ${C_BOLD}${ORIGIN_DOMAIN}${C_RESET}"
info "WS-путь:    ${C_BOLD}${WS_PATH}${C_RESET}"
info "TLS-порт:   ${C_BOLD}${ORIGIN_TLS_PORT}${C_RESET}"
info "Порт Xray:  ${C_BOLD}127.0.0.1:${XRAY_WS_PORT}${C_RESET}"
info "Relay:      ${C_BOLD}${RELAY_IP:-не ограничен}${C_RESET}"

# ==================================================================== 2. DNS ==
step "DNS"
# Подписи дополнены пробелами вручную: printf '%-Ns' выравнивает по байтам,
# а кириллица в UTF-8 занимает по два байта на символ и колонки разъезжаются.
printf '  %bA-запись, которая должна существовать:%b\n' "$C_BOLD" "$C_RESET"
printf '    %s %s\n'    "Тип:      " "A"
printf '    %s %s\n'    "Имя:      " "$ORIGIN_DOMAIN"
printf '    %s %b%s%b\n' "Значение: " "$C_BOLD$C_GREEN" "$NODE_IP" "$C_RESET"
printf '    %s %s\n\n'  "TTL:      " "300 (или Auto)"

DNS_IPS=""; DNS_READY=0; DNS_ATTEMPTS=60
info "Ожидаю распространения DNS (до 5 минут)…"
for attempt in $(seq 1 "$DNS_ATTEMPTS"); do
  DNS_IPS="$(resolve_a "$ORIGIN_DOMAIN")"
  if printf '%s\n' "$DNS_IPS" | grep -Fqx "$NODE_IP"; then
    DNS_READY=1
    progress_bar "$DNS_ATTEMPTS" "$DNS_ATTEMPTS" "$ORIGIN_DOMAIN → $NODE_IP"
    progress_done
    ok "DNS указывает на эту ноду"
    break
  fi
  progress_bar "$attempt" "$DNS_ATTEMPTS" "получено: ${DNS_IPS//$'\n'/, } (ожидается $NODE_IP)"
  sleep 5
done
if [ "$DNS_READY" -ne 1 ]; then
  progress_done
  die "DNS не указывает на $NODE_IP после 5 минут. Добавьте A-запись и запустите скрипт снова."
fi

AAAA="$(resolve_aaaa "$ORIGIN_DOMAIN")"
if [ -n "$AAAA" ]; then
  if ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
    ok "AAAA-запись есть, IPv6 на сервере работает"
  else
    soft "есть AAAA-запись (${AAAA//$'\n'/, }), но IPv6 на сервере не настроен — удалите её, иначе часть клиентов и ACME пойдут в никуда"
  fi
fi

# ============================================================ 3. ДИАГНОСТИКА ==
step "Диагностика системы"
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "ОС: ${PRETTY_NAME:-unknown}" ;;
  *) die "поддерживаются Ubuntu/Debian, обнаружено: ${ID:-unknown}" ;;
esac
info "Ядро: $(uname -r), архитектура: $(uname -m)"
# systemd-detect-virt выходит с кодом 1, когда виртуализации нет, поэтому
# `|| echo` здесь сработал бы поверх уже напечатанного "none".
VIRT="$(systemd-detect-virt 2>/dev/null || true)"
info "Виртуализация: ${VIRT:-неизвестно}"
info "CPU: $(nproc 2>/dev/null || echo '?') ядер, RAM: $(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"

# Время: рассинхронизация ломает валидацию TLS-сертификата и ACME.
if command -v timedatectl >/dev/null 2>&1; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    ok "время синхронизировано по NTP"
  else
    soft "время НЕ синхронизировано по NTP — возможны ошибки TLS/ACME (systemctl enable --now systemd-timesyncd)"
  fi
fi

DISK_FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
if [ "${DISK_FREE_KB:-0}" -lt 1048576 ]; then
  soft "на / меньше 1 ГБ свободно ($((DISK_FREE_KB/1024)) МБ)"
else
  ok "свободно на /: $((DISK_FREE_KB/1024/1024)) ГБ"
fi

SWAP_TOTAL="$(free -b 2>/dev/null | awk '/^Swap:/{print $2+0}' || echo 0)"
if [ "${SWAP_TOTAL:-0}" -eq 0 ]; then
  soft "swap отсутствует — при пике нагрузки возможен OOM-kill"
  if ask_yes_no "Создать swap-файл 2 ГБ?" Y; then
    if [ ! -e /swapfile-ws-node ]; then
      [ "${DISK_FREE_KB:-0}" -ge 2500000 ] || die "недостаточно места для swap-файла"
      spin_run "Создаю swap-файл 2 ГБ" bash -c '
        fallocate -l 2G /swapfile-ws-node || dd if=/dev/zero of=/swapfile-ws-node bs=1M count=2048
        chmod 600 /swapfile-ws-node
        mkswap /swapfile-ws-node'
    fi
    swapon /swapfile-ws-node 2>/dev/null || true
    grep -q '^/swapfile-ws-node ' /etc/fstab || echo '/swapfile-ws-node none swap sw 0 0' >>/etc/fstab
    ok "swap: $(free -h | awk '/^Swap:/{print $2}')"
  fi
else
  ok "swap: $(free -h | awk '/^Swap:/{print $2}')"
fi

if command -v docker >/dev/null 2>&1; then
  RN_STATUS="$(docker ps --filter 'name=remnanode' --format '{{.Status}}' 2>/dev/null | head -1)"
  if [ -n "$RN_STATUS" ]; then ok "контейнер remnanode: $RN_STATUS"
  else soft "контейнер remnanode не запущен — inbound появится только после его старта"; fi
else
  soft "docker не установлен"
fi

# ============================================== 4. ЯДРО: BBR и сетевой тюнинг ==
step "Ядро: BBR и сетевые буферы"
CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
info "Текущий алгоритм: $CURRENT_CC"

if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  info "Модуль tcp_bbr не загружен, загружаю…"
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr >/etc/modules-load.d/ws-node-bbr.conf
fi

if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  # fq рекомендован вместе с BBR; rmem/wmem подняты под HTTP/3 (QUIC) в Caddy,
  # иначе Caddy пишет "failed to sufficiently increase receive buffer size".
  cat >/etc/sysctl.d/99-ws-node-net.conf <<'EOF'
# Сгенерировано setup-ws_tls.sh
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1048576
vm.swappiness = 10
EOF
  sysctl -q --system >/dev/null 2>&1 || sysctl -q -p /etc/sysctl.d/99-ws-node-net.conf >/dev/null 2>&1 || true
  NEW_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  NEW_QD="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  if [ "$NEW_CC" = bbr ]; then ok "BBR включён (qdisc: $NEW_QD), настройки закреплены в /etc/sysctl.d/99-ws-node-net.conf"
  else bad "не удалось переключить congestion control на BBR (сейчас: $NEW_CC)"; fi
  RMEM="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
  [ "${RMEM:-0}" -ge 7500000 ] && ok "UDP-буферы подняты для HTTP/3 (rmem_max=$RMEM)" \
    || soft "rmem_max=$RMEM — Caddy может ругаться на размер UDP-буфера"
else
  soft "ядро $(uname -r) не предоставляет bbr (доступно: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)) — нужен свежее ядро"
fi

# Лимит открытых файлов для Caddy: дефолтные 1024 малы для WS-нагрузки.
mkdir -p /etc/systemd/system/caddy.service.d
cat >/etc/systemd/system/caddy.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
ok "LimitNOFILE=1048576 для caddy.service"

# ======================================================= 5. ПРОВЕРКА ПОРТОВ ==
step "Проверка занятости портов"
check_port_conflict() {
  local port="$1" label="$2" owner
  owner="$(port_owner "$port")"
  if [ -z "$owner" ]; then
    ok "порт $port свободен ($label)"
    return 0
  fi
  case "$owner" in
    *caddy*) ok "порт $port уже занят caddy ($label) — это ожидаемо" ;;
    *nginx*) die "порт $port занят nginx. Остановите его (systemctl stop nginx) или объедините конфигурации вручную." ;;
    *apache*) die "порт $port занят apache2. Остановите его или объедините конфигурации вручную." ;;
    *) die "порт $port ($label) занят посторонним процессом: $owner" ;;
  esac
}
check_port_conflict 80 "ACME HTTP-01 + редирект"
check_port_conflict 443 "маскировочный сайт"
[ "$ORIGIN_TLS_PORT" = 443 ] || check_port_conflict "$ORIGIN_TLS_PORT" "TLS origin"

LISTENER="$(xray_listener "$XRAY_WS_PORT")"
if [ -n "$LISTENER" ]; then
  ok "listener Xray найден: $LISTENER"
  warn "существующий inbound не изменяется — убедитесь, что это именно нужный WS-inbound"
else
  info "listener 127.0.0.1:$XRAY_WS_PORT пока отсутствует — это нормально до применения Config Profile"
fi

# Публично доступные порты, о которых стоит знать (например, API RemnaNode).
# Список держим построчно: с IFS=$'\n\t' пробел не разделяет слова, и
# `for p in $PUBLIC_PORTS` по строке "22 80 443" дал бы одну итерацию.
SSH_PORT="$(ss -lntpH 2>/dev/null | awk '/sshd/{n=split($4,a,":"); print a[n]; exit}')"
SSH_PORT="${SSH_PORT:-22}"
PUBLIC_PORTS="$(ss -lntH 2>/dev/null | awk '{print $4}' \
  | grep -Ev '^(127\.|\[?::1\]?:)' | awk -F: '{print $NF}' | sort -un || true)"
info "Слушают на всех интерфейсах: ${PUBLIC_PORTS//$'\n'/, }"
for p in $PUBLIC_PORTS; do
  case "$p" in
    "$SSH_PORT"|80|443|"$ORIGIN_TLS_PORT") ;;
    *) soft "порт $p открыт наружу ($(port_owner "$p")) — закройте firewall-ом, если он не нужен публично" ;;
  esac
done

# ================================================================ 6. БЭКАП ==
step "Резервная копия"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/ws-node-backup-$TS"
mkdir -p "$BACKUP_DIR"
[ -d "$GENERATED_DIR" ] && cp -a "$GENERATED_DIR" "$BACKUP_DIR/generated" || true
cp -a /etc/caddy "$BACKUP_DIR/caddy-dir" 2>/dev/null || true
cp -a /etc/caddy/Caddyfile "$BACKUP_DIR/Caddyfile" 2>/dev/null || true
cp -a /etc/ufw "$BACKUP_DIR/ufw" 2>/dev/null || true
ss -lntp >"$BACKUP_DIR/listeners.txt" 2>/dev/null || true
sysctl -a >"$BACKUP_DIR/sysctl.txt" 2>/dev/null || true
cat >"$BACKUP_DIR/restore.sh" <<EOF
#!/usr/bin/env bash
set -e
if [ -f "$BACKUP_DIR/Caddyfile" ]; then
  cp -a "$BACKUP_DIR/Caddyfile" /etc/caddy/Caddyfile
  systemctl reload caddy || true
  echo "Восстановлен Caddyfile из $BACKUP_DIR"
else
  echo "В бэкапе не было Caddyfile"
fi
EOF
chmod 700 "$BACKUP_DIR/restore.sh"
ok "бэкап: $BACKUP_DIR"

# =========================================================== 7. ЗАВИСИМОСТИ ==
step "Зависимости"
export DEBIAN_FRONTEND=noninteractive
spin_run "apt-get update" apt-get update -qq

MISSING=()
for pkg_cmd in "curl:curl" "openssl:openssl" "dig:dnsutils" "ss:iproute2" "jq:jq"; do
  cmd="${pkg_cmd%%:*}"; pkg="${pkg_cmd##*:}"
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$pkg")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  # "${arr[*]}" склеивается первым символом IFS, а он здесь \n — задаём пробел явно.
  MISSING_STR="$(IFS=' '; printf '%s' "${MISSING[*]}")"
  spin_run "Устанавливаю: $MISSING_STR" apt-get install -y -qq ca-certificates "${MISSING[@]}"
  ok "установлено: $MISSING_STR"
else
  ok "все вспомогательные утилиты на месте"
fi

if command -v caddy >/dev/null 2>&1; then
  ok "Caddy уже установлен: $(caddy version | head -1)"
else
  install_caddy_repo() {
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      >/etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy
  }
  if ! spin_run "Устанавливаю Caddy из официального репозитория" install_caddy_repo; then
    spin_run "Пробую Caddy из репозитория дистрибутива" apt-get install -y -qq caddy \
      || die "не удалось установить Caddy"
  fi
  ok "Caddy установлен: $(caddy version | head -1)"
fi
systemctl daemon-reload

# ===================================================== 8. КОНФИГУРАЦИЯ CADDY ==
step "Конфигурация Caddy"
mkdir -p /var/www/ws-origin
if [ ! -e /var/www/ws-origin/index.html ]; then
  cat >/var/www/ws-origin/index.html <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Service</title>
<h1>Service is available.</h1>
EOF
fi
chmod -R a+rX /var/www/ws-origin

if [ -s "$CADDYFILE" ] && ! grep -q 'WS-NODE-SETUP-BEGIN' "$CADDYFILE"; then
  warn "существующий $CADDYFILE сохранён в $BACKUP_DIR/Caddyfile"
  ask_yes_no "Заменить существующий Caddyfile новым (старый можно восстановить)?" N \
    || die "отменено для безопасности"
fi

# КЛЮЧЕВОЙ МОМЕНТ. Если TLS-порт равен 443, маскировочный сайт и WS-сайт
# попадают на один и тот же host:port. Caddy сливает такие блоки в один route,
# причём file_server без path-матчера оказывается первым и перехватывает ВСЁ —
# /healthz и WS-путь начинают отдавать 404. Поэтому при 443 генерируем ОДИН
# блок, где статика стоит последним fallback-ом после явных матчеров.
write_caddyfile() {
  {
    echo "# WS-NODE-SETUP-BEGIN"
    echo "# Сгенерировано setup-ws_tls.sh v$SCRIPT_VERSION, $(date -Is). Правки будут перезаписаны."
    echo
    cat <<EOF
(ws_origin) {
	@health path /healthz
	handle @health {
		respond "ok" 200
	}

	@wss path $WS_PATH $WS_PATH/*
	handle @wss {
		reverse_proxy 127.0.0.1:$XRAY_WS_PORT {
			flush_interval -1
		}
	}

	# Всё остальное — обычный сайт. Отдаём статику, а не голый 404:
	# так нода неотличима от рядового веб-сервера при активном сканировании.
	handle {
		root * /var/www/ws-origin
		file_server
	}
}

EOF
    if [ "$ORIGIN_TLS_PORT" = 443 ]; then
      cat <<EOF
https://$ORIGIN_DOMAIN {
	import ws_origin
}
EOF
    else
      cat <<EOF
$ORIGIN_DOMAIN {
	root * /var/www/ws-origin
	file_server
}

https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT {
	import ws_origin
}
EOF
    fi
    echo "# WS-NODE-SETUP-END"
  } >"$CADDYFILE"
}
write_caddyfile

caddy fmt --overwrite "$CADDYFILE" >/dev/null
if caddy validate --config "$CADDYFILE" >>"$LOG_FILE" 2>&1; then
  ok "Caddyfile валиден"
else
  caddy validate --config "$CADDYFILE" || true
  die "Caddyfile не проходит валидацию"
fi

# Проверяем не текст конфига, а фактически собранный роутинг: маршрут WS-пути
# обязан существовать и вести на локальный порт Xray.
if command -v jq >/dev/null 2>&1; then
  if caddy adapt --config "$CADDYFILE" 2>/dev/null \
      | jq -e --arg up "127.0.0.1:$XRAY_WS_PORT" \
        '[.. | objects | select(.handler? == "reverse_proxy") | .upstreams[].dial] | index($up)' \
      >/dev/null 2>&1; then
    ok "в собранном роутинге есть reverse_proxy → 127.0.0.1:$XRAY_WS_PORT"
  else
    bad "в собранном роутинге нет upstream 127.0.0.1:$XRAY_WS_PORT"
  fi
fi

if [ "$ORIGIN_TLS_PORT" = 443 ]; then
  info "TLS-порт 443: маскировочный сайт и WS обслуживаются одним блоком (fallback-статика)"
else
  info "TLS-порт $ORIGIN_TLS_PORT: маскировочный сайт на 80/443, WS на $ORIGIN_TLS_PORT"
fi

spin_run "Запускаю Caddy" systemctl enable --now caddy
spin_run "Перечитываю конфигурацию Caddy" systemctl reload caddy
systemctl is-active --quiet caddy && ok "caddy активен" || die "caddy не запустился (journalctl -u caddy -n 50)"

# ======================================================= 9. АРТЕФАКТЫ ЛОКАЛЬНО ==
step "Локальные файлы конфигурации"
mkdir -p "$GENERATED_DIR"
umask 077

cat >"$GENERATED_DIR/inbound-vless-ws.json" <<EOF
{
  "tag": "VLESS-WS-RELAY",
  "listen": "127.0.0.1",
  "port": $XRAY_WS_PORT,
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "path": "$WS_PATH"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
EOF
command -v jq >/dev/null 2>&1 && jq -e . "$GENERATED_DIR/inbound-vless-ws.json" >/dev/null \
  && ok "inbound-vless-ws.json — валидный JSON"

cp -f "$CADDYFILE" "$GENERATED_DIR/Caddyfile"

cat >"$GENERATED_DIR/node.env" <<EOF
# Сгенерировано setup-ws_tls.sh v$SCRIPT_VERSION; секретов нет.
ORIGIN_DOMAIN=$ORIGIN_DOMAIN
WS_PATH=$WS_PATH
ORIGIN_TLS_PORT=$ORIGIN_TLS_PORT
XRAY_WS_PORT=$XRAY_WS_PORT
RELAY_IP=$RELAY_IP
NODE_IP=$NODE_IP
EOF

cat >"$GENERATED_DIR/inbound-merge-instructions.txt" <<EOF
1. Откройте Config Profile, назначенный этой RemnaNode.
2. Не удаляйте существующие inbound. Добавьте содержимое inbound-vless-ws.json
   отдельным объектом в существующий массив "inbounds".
3. Сохраните профиль, назначьте его этой ноде и примените конфигурацию.
4. Убедитесь, что появился listener 127.0.0.1:$XRAY_WS_PORT.
5. Запустите: setup-ws_tls.sh --status  — для финальной проверки.

Ожидаемый объект: tag=VLESS-WS-RELAY, network=ws, security=none,
path=$WS_PATH, port=$XRAY_WS_PORT.

Параметры клиентского подключения (на стороне relay/панели):
  address = $ORIGIN_DOMAIN
  port    = $ORIGIN_TLS_PORT
  network = ws, path = $WS_PATH, host = $ORIGIN_DOMAIN
  security= tls, sni = $ORIGIN_DOMAIN
EOF

chmod 600 "$GENERATED_DIR"/node.env "$GENERATED_DIR"/inbound-vless-ws.json \
          "$GENERATED_DIR"/inbound-merge-instructions.txt "$GENERATED_DIR"/Caddyfile
ok "сохранено в $GENERATED_DIR"

# Состояние сохраняем сразу, до долгих ожиданий: даже если проверки упадут,
# повторный запуск подставит уже введённые значения.
cat >"$STATE_FILE" <<EOF
ORIGIN_DOMAIN=$ORIGIN_DOMAIN
WS_PATH=$WS_PATH
ORIGIN_TLS_PORT=$ORIGIN_TLS_PORT
XRAY_WS_PORT=$XRAY_WS_PORT
RELAY_IP=$RELAY_IP
NODE_IP=$NODE_IP
LAST_RUN=$(date -Is)
SCRIPT_VERSION=$SCRIPT_VERSION
EOF
chmod 600 "$STATE_FILE"
ok "параметры запомнены: $STATE_FILE"
umask 022

# ============================================================== 10. FIREWALL ==
step "Firewall"
info "SSH определён на порту $SSH_PORT — он будет разрешён первым правилом"

configure_ufw() {
  # Порядок важен: SSH разрешаем ПЕРВЫМ, иначе включение ufw обрывает сессию.
  ufw allow "$SSH_PORT/tcp" >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  if [ "$ORIGIN_TLS_PORT" != 443 ]; then
    if [ -n "$RELAY_IP" ]; then
      ufw allow from "$RELAY_IP" to any port "$ORIGIN_TLS_PORT" proto tcp >/dev/null
    else
      ufw allow "$ORIGIN_TLS_PORT/tcp" >/dev/null
    fi
  fi
  ufw deny "$XRAY_WS_PORT/tcp" >/dev/null || true
}

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  configure_ufw
  ok "UFW обновлён (SSH $SSH_PORT, 80, 443${ORIGIN_TLS_PORT:+, $ORIGIN_TLS_PORT}); существующие правила не сбрасывались"
else
  soft "UFW не активен — порты сервера открыты полностью"
  info "Правила, которые будут добавлены: allow $SSH_PORT/tcp, 80/tcp, 443/tcp; deny $XRAY_WS_PORT/tcp"
  if ask_yes_no "Установить и включить UFW с этими правилами?" N; then
    command -v ufw >/dev/null 2>&1 || spin_run "Устанавливаю ufw" apt-get install -y -qq ufw
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    configure_ufw
    ufw --force enable >/dev/null
    ok "UFW включён"
    ufw status numbered | sed 's/^/    /'
  else
    warn "firewall не настроен — публично открытые порты остаются доступными"
  fi
fi

if [ "$ORIGIN_TLS_PORT" = 443 ] && [ -n "$RELAY_IP" ]; then
  soft "TLS-порт = 443 используется и маскировочным сайтом, поэтому ограничить его только по IP relay ($RELAY_IP) нельзя"
fi

# ============================================= 11. ОЖИДАНИЕ INBOUND И ПРОВЕРКИ ==
step "Проверка inbound и связности"

LISTENER="$(xray_listener "$XRAY_WS_PORT")"
if [ "$SKIP_LISTENER_CHECK" -eq 0 ] && [ -z "$LISTENER" ]; then
  printf '\n'
  cat "$GENERATED_DIR/inbound-merge-instructions.txt" | sed 's/^/    /'
  printf '\n'
  if ask_yes_no "Config Profile применён — подождать появления listener?" Y; then
    WAIT_N=45
    for i in $(seq 1 "$WAIT_N"); do
      LISTENER="$(xray_listener "$XRAY_WS_PORT")"
      if [ -n "$LISTENER" ]; then
        progress_bar "$WAIT_N" "$WAIT_N" "listener найден"
        progress_done
        break
      fi
      progress_bar "$i" "$WAIT_N" "жду listener на 127.0.0.1:$XRAY_WS_PORT"
      sleep 2
    done
    [ -n "$LISTENER" ] || progress_done
  fi
fi

if [ -n "$LISTENER" ]; then
  ok "listener Xray: $LISTENER"
  # Прямая проверка Xray в обход Caddy: сразу разделяет "сломан Caddy" и
  # "сломан inbound" — самый полезный сигнал при отладке.
  DIRECT_WS="$(ws_status "http://127.0.0.1:$XRAY_WS_PORT$WS_PATH")"
  if [ "$DIRECT_WS" = 101 ]; then
    ok "Xray напрямую отвечает 101 на $WS_PATH"
  else
    bad "Xray напрямую отдал ${DIRECT_WS:-нет ответа} — путь в inbound не совпадает с $WS_PATH"
  fi
else
  bad "listener 127.0.0.1:$XRAY_WS_PORT не найден — inbound не применён в Config Profile"
fi

HEALTH_N=15; HEALTH_CODE=000
for i in $(seq 1 "$HEALTH_N"); do
  HEALTH_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 \
    "https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT/healthz" 2>/dev/null || true)"
  [ "$HEALTH_CODE" = 200 ] && { progress_bar "$HEALTH_N" "$HEALTH_N" "healthz 200"; progress_done; break; }
  progress_bar "$i" "$HEALTH_N" "жду HTTPS (получено: ${HEALTH_CODE:-нет ответа})"
  sleep 2
done
[ "$HEALTH_CODE" = 200 ] || progress_done
[ "$HEALTH_CODE" = 200 ] && ok "HTTPS /healthz → 200" || bad "HTTPS /healthz → ${HEALTH_CODE:-нет ответа}"

WS_CODE="$(ws_status "https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT$WS_PATH")"
[ "$WS_CODE" = 101 ] && ok "WebSocket через TLS → 101" || bad "WebSocket через TLS → ${WS_CODE:-нет ответа}"

# Маскировка: посторонний путь должен выглядеть как обычный сайт.
DECOY_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 6 \
  "https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT/" 2>/dev/null || true)"
[ "$DECOY_CODE" = 200 ] && ok "маскировочная страница отдаётся (/ → 200)" \
  || soft "корень сайта отдал ${DECOY_CODE:-нет ответа} вместо 200"

TLS_INFO="$(echo | timeout 10 openssl s_client -connect "$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT" \
  -servername "$ORIGIN_DOMAIN" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true)"
if [ -n "$TLS_INFO" ]; then
  NOT_AFTER="$(printf '%s\n' "$TLS_INFO" | awk -F= '/notAfter/{print $2}')"
  if [ -n "$NOT_AFTER" ]; then
    EXP_TS="$(date -d "$NOT_AFTER" +%s 2>/dev/null || echo 0)"
    NOW_TS="$(date +%s)"
    DAYS_LEFT=$(( (EXP_TS - NOW_TS) / 86400 ))
    if [ "$EXP_TS" -gt 0 ] && [ "$DAYS_LEFT" -gt 14 ]; then
      ok "TLS-сертификат действителен ещё $DAYS_LEFT дн."
    else
      soft "TLS-сертификат истекает через $DAYS_LEFT дн."
    fi
  fi
  printf '%s\n' "$TLS_INFO" | sed 's/^/      /'
else
  bad "не удалось получить TLS-сертификат с $ORIGIN_DOMAIN:$ORIGIN_TLS_PORT"
fi

# ================================================================== ОТЧЁТ ==
LISTENER_OK=FAIL; [ -n "$LISTENER" ] && LISTENER_OK=PASS
HEALTH_OK=FAIL;   [ "$HEALTH_CODE" = 200 ] && HEALTH_OK=PASS
WS_OK=FAIL;       [ "$WS_CODE" = 101 ] && WS_OK=PASS
BBR_OK="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

cat >"$REPORT_FILE" <<EOF
WS node setup $SCRIPT_VERSION
DATE=$(date -Is)
NODE_IP=$NODE_IP
ORIGIN_DOMAIN=$ORIGIN_DOMAIN
WS_PATH=$WS_PATH
ORIGIN_TLS_PORT=$ORIGIN_TLS_PORT
XRAY_WS_PORT=$XRAY_WS_PORT
RELAY_IP=$RELAY_IP
Xray_listener=$LISTENER_OK
Xray_direct_ws=${DIRECT_WS:-n/a}
HTTPS_healthz=$HEALTH_OK (HTTP $HEALTH_CODE)
WebSocket_upgrade=$WS_OK (HTTP ${WS_CODE:-n/a})
Decoy_root=HTTP ${DECOY_CODE:-n/a}
TCP_congestion_control=$BBR_OK
TLS=$TLS_INFO
BACKUP_DIR=$BACKUP_DIR
GENERATED_CONFIG_DIR=$GENERATED_DIR
LOG=$LOG_FILE
MEMORY=$(free -h 2>/dev/null | awk '/^Mem:/{print $2" total, "$7" available"}')
SWAP=$(free -h 2>/dev/null | awk '/^Swap:/{print $2" total, "$3" used"}')
EOF

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg version "$SCRIPT_VERSION" --arg date "$(date -Is)" \
    --arg domain "$ORIGIN_DOMAIN" --arg path "$WS_PATH" --arg node_ip "$NODE_IP" \
    --argjson tls_port "$ORIGIN_TLS_PORT" --argjson ws_port "$XRAY_WS_PORT" \
    --arg listener "$LISTENER_OK" --arg health "$HEALTH_OK" --arg ws "$WS_OK" \
    --arg cc "$BBR_OK" \
    '{version:$version,date:$date,domain:$domain,ws_path:$path,node_ip:$node_ip,
      tls_port:$tls_port,xray_ws_port:$ws_port,
      checks:{xray_listener:$listener,https_healthz:$health,websocket:$ws},
      tcp_congestion_control:$cc}' \
    >"$GENERATED_DIR/report.json" 2>/dev/null || true
  chmod 600 "$GENERATED_DIR/report.json" 2>/dev/null || true
fi

step "Итог"
printf '  %bПроверки:%b %b%d успешно%b · %b%d предупреждений%b · %b%d ошибок%b\n\n' \
  "$C_BOLD" "$C_RESET" \
  "$C_GREEN" "$CHECK_PASS" "$C_RESET" \
  "$C_YELLOW" "$CHECK_WARN" "$C_RESET" \
  "$C_RED" "$CHECK_FAIL" "$C_RESET"
# Подписи выровнены вручную — см. комментарий про printf и кириллицу выше.
printf '  %s %s\n' "Отчёт:            " "$REPORT_FILE"
printf '  %s %s\n' "Inbound JSON:     " "$GENERATED_DIR/inbound-vless-ws.json"
printf '  %s %s\n' "Caddyfile:        " "$GENERATED_DIR/Caddyfile"
printf '  %s %s\n' "Параметры:        " "$STATE_FILE"
printf '  %s %s\n' "Бэкап:            " "$BACKUP_DIR"
printf '  %s %s\n' "Лог:              " "$LOG_FILE"
printf '  %s %s\n' "Быстрая проверка: " "$0 --status"

if [ "$HEALTH_OK" != PASS ] || [ "$WS_OK" != PASS ]; then
  printf '\n'
  warn "настройка завершена, но не все проверки прошли"
  if [ "$LISTENER_OK" != PASS ]; then
    warn "нет listener 127.0.0.1:$XRAY_WS_PORT — добавьте inbound в Config Profile и примените его"
  elif [ "${DIRECT_WS:-}" != 101 ]; then
    warn "Xray отвечает, но не на $WS_PATH — сверьте path в inbound"
  else
    warn "Xray исправен, проблема на стороне Caddy — смотрите journalctl -u caddy -n 50"
  fi
  exit 3
fi

printf '\n  %b✔ Готово. Origin-нода настроена и проверена.%b\n\n' "$C_BOLD$C_GREEN" "$C_RESET"
