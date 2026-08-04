# setup-ws_tls.sh

Интерактивный установщик origin-ноды для схемы **VLESS → WebSocket + TLS → relay**.

## Запуск

Перед запуском создайте A-запись домена на IP сервера, затем выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/darkpn/setup-profiles/main/setup-ws_tls.sh \
  -o /tmp/setup-ws_tls.sh && sudo bash /tmp/setup-ws_tls.sh
```

## Параметры

После ввода домена скрипт показывает точную DNS-инструкцию: какую A-запись
создать, на какой IPv4 она должна указывать, и проверяет подтверждение перед
продолжением. Используйте прямую DNS-запись без CDN/прокси; если IPv6 не
настроен, удалите конфликтующую AAAA-запись.

Скрипт последовательно запросит:

| Параметр | По умолчанию | Пример |
|---|---:|---|
| Домен origin | — | `origin.example.com` |
| Уникальный WS-путь | — | `/assets/RandomPath` |
| TLS-порт | `8443` | `8443` |
| Локальный WS-порт Xray | `18083` | `18083` |
| IP relay | — | IP-адрес relay-сервера |

Значения сохраняются и автоматически подставляются при следующем запуске.

## Что выполняется

- проверка ОС, DNS, ресурсов и занятых портов;
- проверка текущего listener Xray и предупреждение о существующем inbound;
- отображение RAM и swap;
- предложение создать swap 2 ГБ;
- установка и настройка Caddy;
- выпуск TLS-сертификата;
- настройка HTTPS, `/healthz` и WebSocket reverse proxy;
- настройка UFW;
- генерация готового JSON inbound для Remnawave;
- генерация инструкции по добавлению inbound в уже существующий Config Profile;
- ожидание появления нового listener после применения профиля;
- проверка TLS, HTTP `200` и WebSocket `101`.

Если в Remnawave уже назначен другой Config Profile или на порту работает
старый inbound, скрипт его не удаляет. Новый объект добавляется отдельно в
существующий массив `inbounds`. После применения профиля скрипт проверяет, что
на `127.0.0.1:18083` появился listener. Подробная инструкция сохраняется в
`/root/ws-node-generated/inbound-merge-instructions.txt`.

## Сгенерированные файлы

```text
/root/ws-node-generated/inbound-vless-ws.json
/root/ws-node-generated/Caddyfile
/root/ws-node-generated/node.env
/root/ws-node-report.txt
/root/ws-node-backup-YYYYMMDD-HHMMSS/
/root/.ws-node-setup.conf
```

`inbound-vless-ws.json` добавляется в массив `inbounds` нужного Config Profile
Remnawave. После применения профиля повторно запустите скрипт для финальной
проверки WebSocket.

## Проверка результата

Успешный запуск завершается результатами:

```text
HTTPS_healthz=PASS (HTTP 200)
WebSocket_upgrade=PASS (HTTP 101)
Xray_listener=PASS
```

Код `3` означает, что конфигурация создана, но финальная проверка требует
внимания. Отчёт и backup сохраняются в указанных выше файлах.

## Повторный запуск и восстановление

Перед изменениями создаётся новый backup. Для восстановления предыдущего
Caddyfile:

```bash
sudo /root/ws-node-backup-YYYYMMDD-HHMMSS/restore.sh
```

## Требования

- Ubuntu или Debian;
- root-доступ;
- домен с A-записью на сервер;
- установленная RemnaNode;
- доступ к пакетным репозиториям и Let's Encrypt.
