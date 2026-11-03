# opncdjob

VPN **только для `opencode`**. Поднимает локальный прокси `mihomo` (Clash Meta)
внутри текущего окружения — WSL2 или обычной Ubuntu — и переключает на него
исходящие запросы background-сервиса OpenCode. Сеть хоста, браузер, apt/git/npm и
остальной трафик остаются как были.

Рассчитано на подписку Rocket VPN (`vless://`, REALITY): сервер отдаёт готовый
Clash-конфиг, поэтому ничего конвертировать не нужно.

## Требования

- Ubuntu 20.04+ (проверено на 22.04/24.04), WSL2 — тоже.
- `curl`, `python3`, `gzip`, `coreutils` (есть в стандартной поставке).
- `systemd --user` — желательно (автозапуск и таймер обновления).
  В WSL2 включается в `/etc/wsl.conf`:

  ```ini
  [boot]
  systemd=true
  ```

  и после `wsl --shutdown` проверяется командой `systemctl --user show-environment`.
- `opencode` в `PATH` (v2 с поддержкой `opencode service set env`).
- Root не нужен: прокси слушает локальный порт `7890`.

## Быстрый старт

```sh
cd ~/dev/opncdjob
./install.sh
```

Установщик спросит ссылку подписки (ввод не отображается), скачает `mihomo`,
подготовит конфиг, запустит прокси, проверит внешний IP и включит прокси для
opencode.

Дальше просто запускай:

```sh
./opncdjob
```

Появится статус и меню:

```
  1) Включить: прокси + opencode
  2) Выключить opencode (прямое подключение, прокси оставить)
  3) Выключить всё (остановить прокси)
  4) Обновить конфиг подписки
  5) Сменить ссылку подписки
  6) Показать лог
  7) Переустановить / починить
  8) Удалить установку
  0) Выход
```

## Команды

| Команда | Действие |
|---|---|
| `./opncdjob` | интерактивное меню (без TTY — просто статус) |
| `./opncdjob status` | статус: mihomo, прокси, opencode, подписка |
| `./opncdjob enable` | запустить прокси и включить его для opencode |
| `./opncdjob disable` | вернуть opencode напрямую, прокси оставить |
| `./opncdjob start` / `stop` | только процесс прокси |
| `./opncdjob update` | перекачать подписку и применить без перезапуска |
| `./opncdjob logs [N]` | хвост лога mihomo + статус юнита |
| `./opncdjob env` | `export`-строки: `eval "$(./opncdjob env)"` |
| `./opncdjob run <cmd…>` | выполнить одну команду через прокси |
| `./opncdjob uninstall` | удалить установку |
| `./opncdjob uninstall --purge` | удалить и каталог репозитория |

## Что где лежит

| Путь | Назначение |
|---|---|
| `~/.config/opncdjob/config.yaml` | сгенерированный Clash-конфиг (600) |
| `~/.config/opncdjob/subscription.url` | ссылка подписки (600) |
| `~/.config/opncdjob/subscription.headers` | метаданные подписки (600) |
| `~/.local/lib/opncdjob/mihomo` | бинарник mihomo |
| `~/.local/state/opncdjob/mihomo.log` | лог прокси |
| `~/.local/state/opncdjob/state` | состояние установки |
| `~/.config/systemd/user/opncdjob-proxy.service` | юнит прокси |
| `~/.config/systemd/user/opncdjob-update.{service,timer}` | ежечасное обновление |

Переопределяется переменными: `OPNCDJOB_CONFIG_DIR`, `OPNCDJOB_STATE_DIR`,
`OPNCDJOB_LIB_DIR`, `OPNCDJOB_SYSTEMD_DIR`, `OPNCDJOB_PORT`,
`OPNCDJOB_SOCKS_PORT`, `OPNCDJOB_CONTROLLER_PORT`, `OPNCDJOB_NO_SYSTEMD=1`,
`OPNCDJOB_UPDATE_INTERVAL`, `OPNCDJOB_MIHOMO_VERSION`, `OPNCDJOB_VENDOR`,
`OPNCDJOB_SUB_URL`, `OPNCDJOB_YES=1`, `NO_COLOR=1`.

## Как это работает

1. `curl -A 'clash.meta'` по ссылке подписки → готовый Clash-YAML.
2. Python-хелпер правит верхний уровень конфига: `mixed-port: 7890`,
   `allow-lan: false`, `bind-address: 127.0.0.1`, `mode: global`,
   `external-controller: 127.0.0.1:9090`, случайный `secret`, убирает
   `redir-port`/`tproxy-port`.
3. `mihomo -t` проверяет конфиг, затем сервис запускается (`systemd --user`, а без
   systemd — через `nohup`).
4. `opencode service set env HTTP_PROXY/HTTPS_PROXY/NO_PROXY` + `service start`.
   Значения перезаписываются, предыдущие сохраняются в бэкап и восстанавливаются
   при выключении/удалении.
5. Проверка: `curl -x http://127.0.0.1:7890 https://api.ipify.org` и сравнение с
   прямым IP.

## Переносимость

Каталог самодостаточен: скопируй его на другую Ubuntu/WSL2-машину и запусти
`./install.sh`. Для машин без доступа к GitHub положи бинарник рядом:

```sh
mkdir -p vendor
cp /path/to/mihomo-linux-amd64 vendor/mihomo-linux-amd64
chmod +x vendor/mihomo-linux-amd64
```

Установщик возьмёт его вместо скачивания. Архитектура определяется автоматически
(`amd64`/`arm64`), при необходимости задай `OPNCDJOB_MIHOMO_VERSION`.

Автоматическая установка без вопросов:

```sh
OPNCDJOB_SUB_URL='https://…' OPNCDJOB_YES=1 ./install.sh
```

Если сеть блокирует и саму подписку, скачай Clash-конфиг на другой машине
(или браузером с `User-Agent: clash.meta`) и укажи локальный путь — установщик
примет `/path/to/config.yaml` (рядом можно положить `config.yaml.headers` с
метаданными подписки):

```sh
OPNCDJOB_SUB_URL=/home/user/clash.yaml ./install.sh
```

## Диагностика

| Симптом | Что проверить |
|---|---|
| `mihomo: остановлен` | `./opncdjob logs`; порт занят: `ss -ltnp \| grep 7890` |
| прокси работает, opencode без сети | `opencode service get env` — должны быть `HTTPS_PROXY`/`NO_PROXY` |
| всё ещё блокируется | `curl -x http://127.0.0.1:7890 -v https://…`; провайдер мог блокировать и `x.llill.tech` |
| `IP совпадает с прямым` | узел не работает: `./opncdjob update` (обновить узлы) или смени узел в ЛК |
| нет systemd | `./opncdjob start` вручную после входа, либо включить `systemd=true` в WSL |
| подписка истекла | `./opncdjob status` (дата) → продлить в ЛК и `./opncdjob update` |
| WSL: прокси виден из Windows | нормально при `allow-lan: false` его не будет; проверь `ss -ltn` |

## Безопасность

- Ссылка подписки = ключ доступа: файлы `600`, каталог `700`, в логах не
  печатается (маскируется).
- Прокси слушает только `127.0.0.1`, `allow-lan: false`.
- `external-controller` защищён случайным `secret`.
- Удаление возвращает opencode к прежним настройкам прокси (если они были).
