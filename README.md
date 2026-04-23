# naive-setup

Одна команда для развёртывания [NaiveProxy](https://github.com/klzgrad/naiveproxy) сервера на базе Caddy с плагином [forwardproxy](https://github.com/klzgrad/forwardproxy).

Скрипт:
- проверяет, свободны ли порты 80 и 443 (и показывает, кто их занимает)
- запрашивает домен, e-mail для Let's Encrypt, логин и пароль прокси
- скачивает Caddy (naive forwardproxy build)
- создаёт системного пользователя `caddy-naive` и устанавливает права на конфиг
- устанавливает systemd-юнит `caddy-naive.service` и запускает Caddy
- показывает ссылку для импорта в клиент и QR-код

## Быстрый старт

> Требуется root. Проверено на Ubuntu 22.04/24.04, Debian 12, Alpine 3.19+.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/kartazon/naive-setup/main/naive-setup.sh)
```

Или скачать и запустить вручную:

```bash
mkdir -p ~/naive-server && cd ~/naive-server
wget -O start_server.sh "https://raw.githubusercontent.com/ZonD80/naivetools/main/server/start_server.sh"
chmod +x start_server.sh
sudo ./start_server.sh
```

## Управление сервисом

```bash
# статус
systemctl status caddy-naive

# перезагрузить конфиг без downtime
systemctl reload caddy-naive

# остановить / запустить
systemctl stop caddy-naive
systemctl start caddy-naive

# логи
journalctl -u caddy-naive -f
```

## Конфигурация

Конфиг хранится в `/etc/caddy/Caddyfile` (права `root:caddy-naive 0640`).
После ручного редактирования перезагрузите конфиг:

```bash
systemctl reload caddy-naive
```

## Ручная настройка

Если вы предпочитаете настраивать сервер вручную, воспользуйтесь гайдом:

**[Ручная настройка NaiveProxy + Caddy](https://gist.github.com/swrneko/09e60de4d3d8f9a551a1a2c1ab9283c5)**

## Требования

| Что | Зачем |
|-----|-------|
| Домен с A-записью на сервер | TLS через Let's Encrypt |
| Открытые порты 80 и 443 | ACME HTTP challenge + HTTPS |
| `curl` или `wget` | Загрузка Caddy |
| `xz` | Распаковка архива |
| `setcap` (`libcap2-bin` / `libcap`) | Бинарник слушает порт 443 без root |

## Безопасность

- Caddy работает от непривилегированного пользователя `caddy-naive`
- Caddyfile недоступен другим пользователям (`chmod 0640`)
- Используется `cap_net_bind_service` вместо запуска от root
- `probe_resistance` и `hide_ip` включены по умолчанию

## Лицензия

MIT
