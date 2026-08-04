# setup-ws_tls.sh

Интерактивный установщик origin-ноды для схемы **VLESS → WebSocket + TLS → relay**.

Скрипт предназначен для запуска непосредственно на сервере клиента от имени
`root`. Он настраивает операционную систему и Caddy, но **не подключается к
Remnawave Panel и не изменяет Config Profile автоматически**.

## Быстрый запуск

> Перед запуском проверьте, что домен уже указывает A-записью на этот сервер.

```bash
curl -fsSL https://raw.githubusercontent.com/darkpn/setup-profiles/main/setup-ws_tls.sh \
  -o /tmp/setup-ws_tls.sh
chmod 700 /tmp/setup-ws_tls.sh
sudo /tmp/setup-ws_tls.sh
```

Для просмотра справки:

```bash
sudo /tmp/setup-ws_tls.sh --help
```

Если inbound ещё не применён в Remnawave и нужно сначала подготовить Caddy:

```bash
sudo /tmp/setup-ws_tls.sh --skip-listener-check
```

## Какие данные запрашиваются

Во время запуска скрипт запросит:

| Параметр | Значение по умолчанию | Назначение |
|---|---:|---|
| Домен origin | — | Домен ноды; его A-запись должна указывать на IP сервера |
| Уникальный WS-путь | — | Путь, выданный администратором relay |
| TLS-порт origin | `8443` | Внешний HTTPS/WSS-порт Caddy |
| Локальный порт Xray WS | `18083` | Loopback-порт нового inbound |
| IP relay | — | Позволяет ограничить доступ к TLS-порту только relay |

Введённые значения сохраняются локально и предлагаются как значения по умолчанию
при следующем запуске. Секреты скрипт не запрашивает и не сохраняет.

## Что делает скрипт

1. Проверяет права root, ОС Ubuntu/Debian, DNS, свободные порты и наличие
   локального listener `127.0.0.1:18083`.
2. Показывает CPU, оперативную память и swap. Если swap отсутствует, предлагает
   создать аварийный swap-файл размером 2 ГБ.
3. Создаёт резервную копию Caddy, UFW, списка listener и ранее сгенерированных
   файлов.
4. Устанавливает Caddy, если он ещё не установлен.
5. Создаёт сайт-заглушку и конфигурацию Caddy для HTTPS, `/healthz` и WebSocket.
6. Получает сертификат Caddy автоматически (если DNS и исходящий доступ работают).
7. Настраивает UFW без очистки существующих правил. Порт Xray остаётся закрытым
   для внешнего доступа.
8. Генерирует готовый JSON inbound для ручной вставки в Config Profile.
9. Выполняет проверки TLS, HTTP `200` на `/healthz` и WebSocket `101`.

## Конфигурация Remnawave

Скрипт намеренно не редактирует панель. После запуска добавьте файл
`/root/ws-node-generated/inbound-vless-ws.json` в существующий массив `inbounds`
нужного Config Profile и примените профиль к ноде.

В inbound используются:

```text
listen: 127.0.0.1
network: ws
security: none
port: XRAY_WS_PORT
wsSettings.path: WS_PATH
```

`security: none` здесь корректен: TLS завершается в Caddy, а Caddy передаёт
трафик Xray только через loopback.

## Создаваемые файлы

```text
/root/ws-node-generated/inbound-vless-ws.json  # inbound для панели
/root/ws-node-generated/Caddyfile               # применённая конфигурация Caddy
/root/ws-node-generated/node.env                # параметры без секретов
/root/ws-node-report.txt                        # итоговый отчёт
/root/ws-node-backup-YYYYMMDD-HHMMSS/          # резервная копия
/root/.ws-node-setup.conf                       # память последнего запуска
```

## Отказоустойчивость и безопасность

- блокировка параллельного запуска;
- строгая проверка домена, path, портов и IPv4;
- проверка DNS до выпуска сертификата;
- backup перед изменениями;
- `caddy validate` перед reload;
- существующий Caddyfile заменяется только после подтверждения;
- повторный запуск безопасен и использует сохранённые параметры;
- UFW не сбрасывается;
- `18083` не открывается наружу;
- при ошибке финальной проверки скрипт возвращает код `3`, но оставляет отчёт и
  backup для диагностики.

## Результаты проверки

Успешная настройка должна показать:

```text
HTTPS_healthz=PASS (HTTP 200)
WebSocket_upgrade=PASS (HTTP 101)
Xray_listener=PASS
```

Если WebSocket возвращает `400`, `502` или `000`, проверьте, что inbound
применён в Remnawave, listener слушает `127.0.0.1:18083`, а WS-путь совпадает
символ в символ.

## Восстановление

Путь к backup выводится в конце запуска и записывается в отчёт. Для восстановления
предыдущего Caddyfile используйте:

```bash
sudo /root/ws-node-backup-YYYYMMDD-HHMMSS/restore.sh
```

## Требования

- Ubuntu или Debian;
- root-доступ;
- домен с корректной A-записью;
- установленная RemnaNode/совместимый локальный Xray inbound;
- исходящий HTTPS-доступ для установки пакетов и выпуска сертификата.
