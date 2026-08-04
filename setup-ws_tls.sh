#!/usr/bin/env bash
# Интерактивная, повторяемая настройка origin-ноды RemnaNode.
# Скрипт настраивает Linux-хост, генерирует конфиг inbound и Caddy, но НЕ входит
# в Remnawave Panel и НЕ изменяет Config Profile автоматически.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.0.0"
BACKUP_DIR=""
LOCK_FILE=/run/ws-node-setup.lock
SKIP_LISTENER_CHECK=0
STATE_FILE=/root/.ws-node-setup.conf
GENERATED_DIR=/root/ws-node-generated
WAIT_FOR_PANEL=1

usage() {
  cat <<'EOF'
Использование: setup-node-interactive.sh [--skip-listener-check]

Интерактивная настройка Caddy + TLS для VLESS WebSocket origin.
Config Profile Remnawave скрипт не изменяет.
EOF
}
for arg in "$@"; do
  case "$arg" in
    --skip-listener-check) SKIP_LISTENER_CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

die() { echo "ОШИБКА: $*" >&2; exit 1; }
note() { printf '\n== %s ==\n' "$*"; }
warn() { printf 'ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*" >&2; }
command -v id >/dev/null || die "не найден id"
[ "$(id -u)" -eq 0 ] || die "запустите от root"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "другая установка уже выполняется"
fi

ask() {
  local prompt="$1" default="${2-}" value
  # Значение функции вызывается через command substitution; печатаем prompt в
  # stderr, чтобы он не пропал внутри $(ask ...), а введённое значение ушло в stdout.
  if [ -n "$default" ]; then printf '%s [%s]: ' "$prompt" "$default" >&2; else printf '%s: ' "$prompt" >&2; fi
  IFS= read -r value || true
  printf '%s' "${value:-$default}"
}
state_get() {
  local key="$1" fallback="${2-}" value
  value="$(awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$STATE_FILE" 2>/dev/null || true)"
  printf '%s' "${value:-$fallback}"
}
ask_yes_no() {
  local prompt="$1" default="${2:-N}" value
  while :; do
    printf '%s [%s]: ' "$prompt" "$default"
    IFS= read -r value || true
    value="${value:-$default}"
    case "${value,,}" in y|yes|д|да) return 0;; n|no|н|нет) return 1;; esac
    echo "Введите y/n." >&2
  done
}
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_path() { [[ "$1" == /* && "$1" != *[[:space:]]* && "$1" != *'"'* && "$1" != *"'"* ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

note "Параметры (последние значения подставляются автоматически)"
PREV_DOMAIN="$(state_get ORIGIN_DOMAIN)"
PREV_PATH="$(state_get WS_PATH)"
PREV_TLS_PORT="$(state_get ORIGIN_TLS_PORT 8443)"
PREV_WS_PORT="$(state_get XRAY_WS_PORT 18083)"
PREV_RELAY_IP="$(state_get RELAY_IP)"
ORIGIN_DOMAIN="$(ask 'Домен origin (A-запись должна указывать на этот сервер)' "$PREV_DOMAIN")"
valid_domain "$ORIGIN_DOMAIN" || die "некорректное доменное имя: $ORIGIN_DOMAIN"
WS_PATH="$(ask 'Уникальный WS_PATH (начинается с /)' "$PREV_PATH")"
valid_path "$WS_PATH" || die "некорректный WS_PATH"
ORIGIN_TLS_PORT="$(ask 'TLS-порт origin' "$PREV_TLS_PORT")"
XRAY_WS_PORT="$(ask 'Локальный порт Xray WS' "$PREV_WS_PORT")"
valid_port "$ORIGIN_TLS_PORT" || die "некорректный TLS-порт"
valid_port "$XRAY_WS_PORT" || die "некорректный WS-порт"
RELAY_IP="$(ask 'IP общего relay (пусто = не ограничивать 8443)' "$PREV_RELAY_IP")"
[ -z "$RELAY_IP" ] || valid_ipv4 "$RELAY_IP" || die "некорректный IPv4 relay"

NODE_IP=""
if command -v curl >/dev/null 2>&1; then
  NODE_IP="$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi
DNS_IPS="$(getent ahostsv4 "$ORIGIN_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
echo "DNS: ${DNS_IPS:-не резолвится}; обнаруженный IP сервера: ${NODE_IP:-не определён}"
if [ -n "$NODE_IP" ] && [ -n "$DNS_IPS" ] && ! grep -Fqw "$NODE_IP" <<<"$DNS_IPS"; then
  warn "DNS не указывает на обнаруженный IP этого сервера. Сертификат Caddy может не выпуститься."
  ask_yes_no "Продолжить всё равно?" N || exit 1
fi

note "Диагностика и безопасные проверки"
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) die "поддерживаются Ubuntu/Debian, обнаружено: ${ID:-unknown}" ;; esac
echo "ОС: ${PRETTY_NAME:-unknown}; CPU: $(nproc 2>/dev/null || echo '?')"
echo "Память: $(free -h 2>/dev/null | awk '/^Mem:/{print $2" всего, доступно "$7}' || echo 'неизвестно')"
SWAP_TOTAL="$(free -b 2>/dev/null | awk '/^Swap:/{print $2+0}' || echo 0)"
if [ "${SWAP_TOTAL:-0}" -eq 0 ]; then
  warn "На сервере не обнаружен swap. При пике нагрузки возможен OOM-kill."
  if ask_yes_no "Создать аварийный swap-файл 2 ГБ?" Y; then
    if [ ! -e /swapfile-ws-node ]; then
      avail_kb="$(df -Pk / | awk 'NR==2{print $4}')"
      [ "${avail_kb:-0}" -ge 2500000 ] || die "недостаточно места для swap-файла"
      fallocate -l 2G /swapfile-ws-node
      chmod 600 /swapfile-ws-node
      mkswap /swapfile-ws-node >/dev/null
    fi
    swapon /swapfile-ws-node 2>/dev/null || true
    grep -q '^/swapfile-ws-node ' /etc/fstab || echo '/swapfile-ws-node none swap sw 0 0' >> /etc/fstab
    sysctl -q -w vm.swappiness=10 || true
    printf 'vm.swappiness = 10\n' >/etc/sysctl.d/99-ws-node-memory.conf
    echo "Swap: $(free -h | awk '/^Swap:/{print $2}')"
  fi
fi
echo "Docker/RemnaNode:"
if command -v docker >/dev/null 2>&1; then docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true; else warn "docker не установлен"; fi

listener_line="$(ss -lntp 2>/dev/null | awk -v p=":$XRAY_WS_PORT" '$4=="127.0.0.1"p {print; exit}')"
if [ -n "$listener_line" ]; then
  echo "На 127.0.0.1:$XRAY_WS_PORT уже есть listener: $listener_line"
  warn "Существующий inbound не изменяется. Убедитесь, что это именно новый WS-inbound."
fi
if [ "$SKIP_LISTENER_CHECK" -eq 0 ] && [ -z "$listener_line" ]; then
  echo "На предварительной проверке listener 127.0.0.1:$XRAY_WS_PORT ещё не найден."
  echo "Это нормально, если inbound будет добавлен в Remnawave после генерации файла."
fi

if ss -lntp 2>/dev/null | grep -Eq ':[[:digit:]]+ +[^ ]*:(80|443)( |$)'; then
  if systemctl is-active --quiet nginx 2>/dev/null; then die "nginx уже занимает 80/443; объедините конфигурации вручную или остановите его"; fi
  if systemctl is-active --quiet apache2 2>/dev/null; then die "apache2 уже занимает 80/443"; fi
fi
if ss -lntp 2>/dev/null | grep -Eq ":$ORIGIN_TLS_PORT( |$)" && ! systemctl is-active --quiet caddy 2>/dev/null; then
  die "порт $ORIGIN_TLS_PORT уже занят неизвестным процессом"
fi

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/ws-node-backup-$TS"
mkdir -p "$BACKUP_DIR"
if [ -d "$GENERATED_DIR" ]; then cp -a "$GENERATED_DIR" "$BACKUP_DIR/generated"; fi
cp -a /etc/caddy/Caddyfile "$BACKUP_DIR/Caddyfile" 2>/dev/null || true
cp -a /etc/caddy "$BACKUP_DIR/caddy-dir" 2>/dev/null || true
cp -a /etc/ufw "$BACKUP_DIR/ufw" 2>/dev/null || true
ss -lntp >"$BACKUP_DIR/listeners.txt" 2>/dev/null || true
cat >"$BACKUP_DIR/restore.sh" <<EOF
#!/usr/bin/env bash
set -e
if [ -f "$BACKUP_DIR/Caddyfile" ]; then cp -a "$BACKUP_DIR/Caddyfile" /etc/caddy/Caddyfile; systemctl reload caddy || true; fi
echo "Восстановлен Caddyfile из $BACKUP_DIR"
EOF
chmod 700 "$BACKUP_DIR/restore.sh"

note "Установка зависимостей"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
if ! command -v caddy >/dev/null 2>&1; then
  if ! apt-get install -y -qq caddy ca-certificates curl openssl >/dev/null 2>&1; then
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy ca-certificates curl openssl >/dev/null
  fi
fi

mkdir -p /var/www/ws-origin
if [ ! -e /var/www/ws-origin/index.html ]; then printf 'Service is available.\n' >/var/www/ws-origin/index.html; fi
chmod -R a+rX /var/www/ws-origin

if [ -s /etc/caddy/Caddyfile ] && ! grep -q 'WS-NODE-SETUP-BEGIN' /etc/caddy/Caddyfile; then
  warn "существующий /etc/caddy/Caddyfile сохранён в $BACKUP_DIR/Caddyfile"
  ask_yes_no "Заменить существующий Caddyfile новым (старый можно восстановить)?" N || die "отменено для безопасности"
fi
cat >/etc/caddy/Caddyfile <<EOF
# WS-NODE-SETUP-BEGIN
$ORIGIN_DOMAIN {
    root * /var/www/ws-origin
    file_server
}

https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT {
    @health path /healthz
    handle @health {
        respond "ok\\n" 200
    }

    @wss path $WS_PATH $WS_PATH/*
    handle @wss {
        reverse_proxy 127.0.0.1:$XRAY_WS_PORT {
            flush_interval -1
        }
    }

    handle {
        respond 404
    }
}
# WS-NODE-SETUP-END
EOF
caddy fmt --overwrite /etc/caddy/Caddyfile >/dev/null
caddy validate --config /etc/caddy/Caddyfile

# Генерируем файлы, которые владелец может загрузить в Remnawave вручную.
# UUID клиентов намеренно пустой: пользователей добавляет панель Remnawave.
mkdir -p "$GENERATED_DIR"
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
cp -f /etc/caddy/Caddyfile "$GENERATED_DIR/Caddyfile"
cat >"$GENERATED_DIR/node.env" <<EOF
# Сгенерировано setup-node-interactive.sh; секретов нет.
ORIGIN_DOMAIN=$ORIGIN_DOMAIN
WS_PATH=$WS_PATH
ORIGIN_TLS_PORT=$ORIGIN_TLS_PORT
XRAY_WS_PORT=$XRAY_WS_PORT
RELAY_IP=$RELAY_IP
EOF
chmod 600 "$GENERATED_DIR"/node.env "$GENERATED_DIR"/inbound-vless-ws.json

cat >"$GENERATED_DIR/inbound-merge-instructions.txt" <<EOF
1. Откройте Config Profile, который назначен этой RemnaNode.
2. Не удаляйте существующие inbound. Добавьте содержимое inbound-vless-ws.json
   отдельным объектом в существующий массив "inbounds".
3. Сохраните профиль, назначьте его этой ноде и примените/пересоздайте конфигурацию.
4. Убедитесь, что появился listener 127.0.0.1:$XRAY_WS_PORT.
5. Вернитесь в этот скрипт или запустите его повторно для финальной проверки.

Ожидаемый объект: tag=VLESS-WS-RELAY, network=ws, security=none,
path=$WS_PATH, port=$XRAY_WS_PORT.
EOF
chmod 600 "$GENERATED_DIR/inbound-merge-instructions.txt"

if [ "$SKIP_LISTENER_CHECK" -eq 0 ] && [ -z "$listener_line" ]; then
  cat "$GENERATED_DIR/inbound-merge-instructions.txt"
  if ask_yes_no "Вы уже применили новый Config Profile и хотите подождать listener?" Y; then
    for _ in {1..30}; do
      listener_line="$(ss -lntp 2>/dev/null | awk -v p=":$XRAY_WS_PORT" '$4=="127.0.0.1"p {print; exit}')"
      [ -n "$listener_line" ] && break
      sleep 2
    done
    if [ -z "$listener_line" ]; then
      warn "listener пока не появился. Проверьте применение профиля и перезапустите скрипт."
    else
      echo "Новый listener обнаружен: $listener_line"
    fi
  else
    WAIT_FOR_PANEL=0
  fi
fi
systemctl enable --now caddy
systemctl reload caddy

note "Firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  if [ -n "$RELAY_IP" ]; then ufw allow from "$RELAY_IP" to any port "$ORIGIN_TLS_PORT" proto tcp >/dev/null; else ufw allow "$ORIGIN_TLS_PORT/tcp" >/dev/null; fi
  ufw deny "$XRAY_WS_PORT/tcp" >/dev/null || true
  echo "UFW обновлён; правила не сбрасывались."
else
  warn "UFW не активен — правила firewall не менялись. Не открывайте $XRAY_WS_PORT наружу."
fi

note "Проверки"
health_code=000
for _ in {1..12}; do health_code="$(curl -ksS -o /tmp/ws-node-health -w '%{http_code}' --connect-timeout 3 --max-time 5 "https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT/healthz" 2>/dev/null || true)"; [ "$health_code" = 200 ] && break; sleep 2; done
ws_code="$(curl -ksS --http1.1 -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT$WS_PATH" 2>/dev/null || true)"
tls_subject="$(echo | timeout 10 openssl s_client -connect "$ORIGIN_DOMAIN:$ORIGIN_TLS_PORT" -servername "$ORIGIN_DOMAIN" 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null || true)"
listener_ok=FAIL; ss -lntp 2>/dev/null | grep -Eq "127\.0\.0\.1:$XRAY_WS_PORT\b" && listener_ok=PASS
[ "$health_code" = 200 ] && health_ok=PASS || health_ok=FAIL
[ "$ws_code" = 101 ] && ws_ok=PASS || ws_ok=FAIL
cat >"/root/ws-node-report.txt" <<EOF
WS node setup $SCRIPT_VERSION
DATE=$(date -Is)
ORIGIN_DOMAIN=$ORIGIN_DOMAIN
WS_PATH=$WS_PATH
ORIGIN_TLS_PORT=$ORIGIN_TLS_PORT
XRAY_WS_PORT=$XRAY_WS_PORT
Xray_listener=$listener_ok
HTTPS_healthz=$health_ok (HTTP $health_code)
WebSocket_upgrade=$ws_ok (HTTP $ws_code)
TLS=$tls_subject
BACKUP_DIR=$BACKUP_DIR
GENERATED_CONFIG_DIR=$GENERATED_DIR
INBOUND_MERGE_INSTRUCTIONS=$GENERATED_DIR/inbound-merge-instructions.txt
MEMORY=$(free -h 2>/dev/null | awk '/^Mem:/{print $2" total, "$7" available"}')
SWAP=$(free -h 2>/dev/null | awk '/^Swap:/{print $2" total, "$3" used"}')
EOF
# Запоминаем введённые параметры для следующего запуска (секретов здесь нет).
umask 077
cat >"$STATE_FILE" <<EOF
ORIGIN_DOMAIN=$ORIGIN_DOMAIN
WS_PATH=$WS_PATH
ORIGIN_TLS_PORT=$ORIGIN_TLS_PORT
XRAY_WS_PORT=$XRAY_WS_PORT
RELAY_IP=$RELAY_IP
EOF
cat /root/ws-node-report.txt

if [ "$health_ok" != PASS ] || [ "$ws_ok" != PASS ]; then
  warn "настройка завершена, но проверки не полностью успешны; отчёт: /root/ws-node-report.txt"
  warn "Для WS 101 должен существовать listener 127.0.0.1:$XRAY_WS_PORT, а в применённом профиле должны совпадать port и WS_PATH."
  exit 3
fi

echo "Готово. Отчёт: /root/ws-node-report.txt"
echo "Сгенерированный inbound: $GENERATED_DIR/inbound-vless-ws.json"
echo "Caddyfile: $GENERATED_DIR/Caddyfile"
echo "Параметры запомнены в: $STATE_FILE"
echo "Backup: $BACKUP_DIR"
