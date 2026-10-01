# NFQWS-MENU

Интерактивное меню установки и управления пакетами **nfqws-keenetic**, **nfqws2-keenetic** и **nfqws-keenetic-web** для роутеров **Keenetic / Netcraze** с **Entware**.

Репозиторий также служит хранилищем готовых **стратегий** обхода DPI, **blobs** и **lists**.

- Скрипт: [`nfqws-menu.sh`](nfqws-menu.sh) (текущая версия **0.8.0**)
- Стратегии: [`strategies/`](strategies/)
- Hosts: [`hosts`](hosts)
- Контрольные суммы: [`SHA256SUMS`](SHA256SUMS), [`strategies/blobs/SHA256SUMS`](strategies/blobs/SHA256SUMS)

### Официальные проекты

| Пакет | Репозиторий |
| --- | --- |
| nfqws-keenetic (v1) | https://github.com/nfqws/nfqws-keenetic |
| nfqws2-keenetic (v2) | https://github.com/nfqws/nfqws2-keenetic |
| Веб-интерфейс | https://github.com/nfqws/nfqws-keenetic-web |

### Источник стратегий

Стратегии в этом репозитории сделаны на базе проекта\
[**Flowseal/zapret-discord-youtube**](https://github.com/Flowseal/zapret-discord-youtube)\
и адаптированы под формат конфигов `nfqws-keenetic` / `nfqws2-keenetic`.

Подготовлены пользователем [**@Nare51**](https://github.com/Nare51) с использованием искусственного интеллекта.

---

## Быстрый старт

Подключитесь к Entware (SSH, порт 222 или 22, логин `root`):

```bash
opkg update && opkg install curl libnghttp2 && curl -sSL https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/nfqws-menu.sh -o /opt/nfqws-menu.sh && sh /opt/nfqws-menu.sh
```

или с wget:

```bash
wget -O /opt/nfqws-menu.sh https://raw.githubusercontent.com/rndnaame/nfqws-menu/main/nfqws-menu.sh && chmod +x /opt/nfqws-menu.sh && sh /opt/nfqws-menu.sh
```

После первого запуска создаётся symlink для быстрого старта:

```bash
menu
```

(`/opt/bin/menu` → `/opt/nfqws-menu.sh`)

---

## Что делает меню

При запуске скрипт:

1. Определяет архитектуру процессора (`aarch64` / `mipsel` / `mips` …) — с кэшированием.
2. Показывает **только установленные** компоненты (версии и статус):
   - пакеты NFQWS / web, usque-keenetic, **tg-ws-proxy-rs**, magitrickle;
   - dpi-detector, awg-manager (`[+SB]` при наличии sing-box), KeenKit, telemt;
   - **⚡** — сервис запущен; **⭡** — доступна более новая версия (фоновая проверка, TTL ~6 ч).
3. Предлагает меню:

```
[::]  КОМПОНЕНТЫ
      1.  Установка NFQWS / NFQWS2

[::]  СТРАТЕГИИ/СПИСКИ
      2.  Выбор стратегии
      3.  Обновить IPSet List
      4.  Загрузить rkn.list (125k+ доменов)
      5.  Обход блокировки DoT/DoH
      6.  Смена активных fake:blob
      7.  Обновление hosts
      8.  Управление DoT/DoH

[::]  УТИЛИТЫ
      10. dpi-detector
      11. awg-manager
      12. KeenKit
      13. usque-keenetic
      14. MagiTrickle
      15. telemt / telemt-panel
      16. TG WS Proxy Rust

[::]  СЕРВИС (S)
      77. Change language
      88. Удаление пакетов

      99. Обновить скрипт
      00. Выход
```

Горячие клавиши: **S** — сервисные утилиты (UPX, Dropbear fix, upgrade пакетов); **U** — `opkg update && opkg upgrade`.

Пример блока статуса:

```
Установленные компоненты:
  nfqws2-keenetic        1.3.x ⚡
  nfqws-keenetic-web     3.x ⚡
  tg-ws-proxy-rs         2.x ⚡
  dpi-detector           …
  ⭡ - доступна более новая версия
```

### 1. Установка NFQWS / NFQWS2

Подменю:

```
1) nfqws-keenetic
2) nfqws2-keenetic
3) nfqws-keenetic-web
4) Установка / обновление .ipk (обход DPI)
0) Назад
```

- **1–2** — зависимости (`ca-certificates`, `wget-ssl`), официальный opkg-репозиторий под архитектуру, установка пакета; при v2, если стоит v1 — предложение удалить старый пакет. После установки — предложение поставить веб.
- **3** — веб-интерфейс (lighttpd + PHP, порт **90**): `http://<IP-роутера>:90`, логин/пароль Entware (`root` / `keenetic` по умолчанию).
- **4** — прямая установка **.ipk** (обход DPI): версии с github.io, скачивание с GitHub Releases → ghproxy → github.io, затем `opkg install` локального файла (конфиги при необходимости извлекаются из .ipk).

> Фикс TLS reasm с **NFQWS2 ≥ 1.3.1** входит в официальный пакет.

### 2. Выбор стратегии

- Если ни одна версия NFQWS не установлена — предлагает установить.
- Показывает список `.conf` из:
  - `strategies/nfqws1/` — для v1
  - `strategies/nfqws2/` — для v2
- Список стратегий: **`SHA256SUMS`** → GitHub API → **локальный offline-кэш** (`/opt/etc/nfqws-menu/strategies/…`).
- Скачивание: основной raw GitHub → зеркала **jsDelivr / Fastly jsDelivr / ghproxy** → fallback через туннель-интерфейсы (`awg0`, `t2s0`, …); успешный файл сохраняется в offline-кэш.
- Делает **бэкап** текущего конфига и применяет стратегию.
- Перед записью **нормализует CRLF → LF** (иначе `source`/iptables: `: not found`, `invalid port/service`).
- **Пункт 99** — восстановление из backup: `.bak.*` от свежего к старому (самый свежий выделен), рядом имя стратегии из `general (…)` в файле; `fix_isp_interface`, перезапуск сервиса.
- После применения выполняет пост-настройку:

#### ISP_INTERFACE / IPV6_ENABLED

- Определяет интерфейс провайдера из default route (`ip route` / `route`), сравнивает с `ISP_INTERFACE` в конфиге и при необходимости предлагает установить правильное значение. При чтении значения снимаются `\r`, кавычки и пробелы (защита от CRLF в выводе меню).
- Проверяет наличие **глобального IPv6** (`2a00*`) на интерфейсе провайдера и выставляет `IPV6_ENABLED=0|1` в конфиге.

#### Восстановление rkn.list и POLICY_*

- Если до смены стратегии в `MODE_LIST` уже был `--hostlist=…/rkn.list`, привязка **восстанавливается** автоматически.
- **`POLICY_NAME` / `POLICY_EXCLUDE`**: стандартные значения (`nfqws` / `0`) не трогаются; **нестандартные** предлагается восстановить (**по умолчанию: Нет**).

#### Проверка blobs (наличие + SHA256)

Парсит установленный конфиг и находит используемые `.bin` (`--blob=…`, `--dpi-desync-fake-tls=…`, `--dpi-desync-fake-quic=…` и абсолютные пути).

- Сверяет локальные файлы с эталоном [`strategies/blobs/SHA256SUMS`](strategies/blobs/SHA256SUMS) (`sha256sum` или `openssl dgst -sha256`; кэш SUMS ~1 ч).
- Отсутствующие или **устаревшие/повреждённые** (хеш не совпал) предлагает скачать заново; после загрузки — повторная проверка SHA256 (при несовпадении файл удаляется).

#### Обновление lists

По запросу обновляет из `strategies/lists/`: `user.list`, `exclude.list`, `ipset.list`, `ipset_exclude.list`.  
`auto.list` **не трогается** — его заполняет демон.

После всех шагов соответствующий сервис перезапускается.

### 3. Обновление IPSet List

Скачивает актуальный IP/CIDR-список из\
[Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube)\
и записывает в `ipset.list`:

| Версия | Путь |
| --- | --- |
| nfqws-keenetic (v1) | `/opt/etc/nfqws/ipset.list` |
| nfqws2-keenetic (v2) | `/opt/etc/nfqws2/lists/ipset.list` |

Бэкап, очистка пустых строк/комментариев, перезапуск сервиса. При двух установленных версиях — можно обновить обе.

### 4. Загрузить rkn.list (125k+ доменов)

Доступно при установленном **nfqws-keenetic** (v1) и/или **nfqws2-keenetic** (v2). При обеих версиях — выбор: 1 / 2 / обе.

- Если `rkn.list` уже есть — показывает размер в **КБ** (без медленного подсчёта 125k строк) и спрашивает, обновлять ли список (**по умолчанию: Нет**). При отказе скачивание пропускается.
- Скачивает большой список доменов РКН из [IndeecFOX/zapret4rocket](https://github.com/IndeecFOX/zapret4rocket)\
  (`extra_strats/TCP/RKN/List.txt`). При недоступности GitHub — зеркало `mizulina.shit.vc` (как в zapret4rocket/z4r).
- Записывает:
  - **v1** → `/opt/etc/nfqws/rkn.list`
  - **v2** → `/opt/etc/nfqws2/lists/rkn.list`
- Добавляет `--hostlist=…/rkn.list` в `MODE_LIST` соответствующего конфига (с бэкапом), если его ещё нет. Вставка через **awk** (устойчиво к CRLF, пробелам, пустым кавычкам).
- **Перезапуск** сервиса (`S51nfqws` / `S51nfqws2`) только при реальных изменениях (обновлён список и/или изменён `MODE_LIST`). Если hostlist уже был в конфиге и список не обновляли — перезапуск не выполняется.

### 5. Обход блокировки DoT/DoH

Только при установленном **nfqws2-keenetic**.

Добавляет в `NFQWS_ARGS_CUSTOM` стратегию обхода блокировок публичных DoT/DoH DNS (Cloudflare, Google, AdGuard, NextDNS, Quad9 и др.), при необходимости добавляет порт `853` в `TCP_PORTS` / `UDP_PORTS`, перезапускает `S51nfqws2`.

### 6. Смена активных fake:blob

Позволяет заменить используемые в конфиге `fake:blob=NAME` на другой `.bin`-файл (переназначает путь в `--blob=NAME:…`).

- Быстрый разбор конфига (v1/v2) одним проходом **awk**: секции `NFQWS_*ARGS*`, map `--blob=name:path`, уникальные `fake:blob=` (hex пропускаются).
- Показывает список найденных имён по секциям.
- Кандидаты `.bin`: локальные → имена из **`strategies/blobs/SHA256SUMS`** → GitHub API → встроенный fallback.
- При выборе файла из репозитория — скачивает его, обновляет `--blob=…`, бэкап конфига.
- Перезапуск сервиса — по подтверждению (по умолчанию Да).

### 7. Обновление hosts

Запись статических DNS-привязок на стороне **Keenetic** через `ndmc` (`ip host DOMAIN IP` / `no ip host DOMAIN` + сохранение конфигурации).

- Скачивает файл `hosts` из репозитория.
- Секции задаются комментариями `# Имя секции`; внутри — строки `IP DOMAIN`.
- Можно выбрать одну или несколько секций, **все**, либо **88** — удалить домены из hosts-файла.
- Только **IPv4**; битые домены (`..`, ведущая `.`) пропускаются; **один IP на домен**.
- Предупреждение, если уникальных записей **&gt; 64** (лимит Keenetic `ip host`).
- Нужен `ndmc` (только Keenetic / Netcraze OS).

### 8. Управление DoT/DoH

Управление DNS-over-TLS / DNS-over-HTTPS на стороне **Keenetic** через `ndmc`.

Подменю:

```
1) Добавить DoT сервер(ы)
2) Добавить DoH сервер(ы)
3) Привязать домен к DNS (Пресеты)
4) Удалить сервер(ы)
0) Назад
```

Возможности:

- Просмотр текущих DoT/DoH и персональных привязок к доменам
- Счётчик слотов **N/8** — только секция **System** (Policy0/1 и `*-filters` не учитываются)
- Пресеты DoT/DoH: Яндекс, Cloudflare, Google, Quad9, CleanBrowsing, OpenDNS, DNS.SB, dns0.eu, OpenNameServer, AdGuard (Default/Family), ControlD Free, DNS4EU, Alibaba DNS, DNSPod, **NullsProxy**, Proxy-DNS, Cloudflare Gateway и др. (Tiar Japan убраны) или ручной ввод
- Быстрая привязка доменов (пресеты):

| № | Описание |
| --- | --- |
| 1 | CleanBrowsing DoT → instagram.com |
| 2 | CleanBrowsing DoH → instagram.com |
| 3 | CleanBrowsing DoT → cdninstagram.com |
| 4 | CleanBrowsing DoH → cdninstagram.com |
| 5 | sw.ext.io DoT → rutor.is & rutor.info |
| 6 | Malw Link DoH → ntc.party |
| 7 | Xbox-DNS DoT → gql.twitch.tv & usher.ttvnw.net |
| 8 | Xbox-DNS DoH → gql.twitch.tv & usher.ttvnw.net |
| 9 | NullsProxy DoT → Supercell (supercell.com, supercellid.com, brawlstarsgame.com, clashofclans.com, clashroyaleapp.com) |
| 10 | NullsProxy DoH → те же домены Supercell |
| 11 | Ввести свой домен и выбрать сервер |

- Удаление upstream-ов с сохранением конфигурации

> Нужен `ndmc` (CLI Keenetic/Netcraze).\
> При активном **Интернет-фильтре** часть DoT может помечаться как *disregarded*.

### 10. dpi-detector

Инструмент для анализа цензуры трафика в России: обнаруживает и классифицирует блокировки сайтов, хостингов и CDN (TCP16–20 блокировки), а также подмену DNS-запросов провайдером.

Актуальная версия [dpi-detector](https://github.com/Runnin4ik/dpi-detector) (ветка `rust`):

```bash
curl -fsSL https://raw.githubusercontent.com/Runnin4ik/dpi-detector/rust/install.sh | sh
```

Если бинарник уже есть (`/opt/bin/dpi-detector`) — очищает дубликаты (`/tmp`, `/opt/root`) и сразу запускает его. После установки — та же очистка дубликатов.

### 11. awg-manager

Веб-интерфейс для управления AmneziaWG VPN-туннелями на роутерах Keenetic. В тестовом режиме добавлена поддержка Sing-box (vless tcp, hysteria, trojan и др.).

Установщик [awg-compressed](https://github.com/rndnaame/awg-compressed):

```bash
curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
```

В статусе: `awg-manager` или `awg-manager [+SB]` при наличии sing-box.

### 12. KeenKit

Многофункциональный скрипт, упрощающий взаимодействие с роутером на базе KeeneticOS.

- Есть `/opt/keenkit.sh` — **сразу запускает**.
- Иначе — установщик [KeenKit](https://github.com/spatiumstas/KeenKit).

### 13. usque-keenetic

Адаптация неофициального клиента Cloudflare WARP с режимом MASQUE для роутеров Keenetic / Netcraze.

Установка / обновление [usque-keenetic](https://side-effect-tm.github.io/usque-keenetic/):

- **Не установлен** — репозиторий под архитектуру + установка:

```bash
mkdir -p /opt/etc/opkg
echo "src/gz usque-keenetic https://side-effect-tm.github.io/usque-keenetic/$ARCH" > /opt/etc/opkg/usque-keenetic.conf
opkg update
opkg install usque-keenetic
```

- **Установлен** → `opkg update && opkg upgrade usque-keenetic`
- Init: `/opt/etc/init.d/S51usque` (start | stop | restart)
- Конфиг: `/opt/etc/usque/usque.conf`

```
# Интерфейс. Определяется автоматически при установке.
# Должен быть вида opkgtun*
IFACE="opkgtun0"
```

### 14. MagiTrickle

Утилита для точечной маршрутизации сетевого трафика по заданным доменным именам.

Установка / обновление [MagiTrickle](http://bin.magitrickle.dev/):

- **Не установлен** — добавление репозитория (`add_repo.sh`) + `opkg install magitrickle` + `S99magitrickle start`
- **Установлен** → `opkg update && opkg install magitrickle` + restart сервиса
- Init: `/opt/etc/init.d/S99magitrickle` (start | stop | restart | status)
- Удаление — в п. 88 (с опциональным удалением `/opt/etc/opkg/magitrickle.conf`)

### 15. telemt / telemt-panel

Telegram MTProto-прокси на Rust (полная реализация официального алгоритма + расширения). Скрипты: [augin/telemt_script](https://github.com/augin/telemt_script) (Entware / Keenetic, рекомендуется **aarch64**).

Подменю:

```
1. Установка telemt
2. Установка telemt-panel
3. Эмуляция systemD
4. Удаление
0. Назад
```

- Установщики запускаются с привязкой к `/dev/tty` (интерактивные скрипты).
- П. 3 — эмуляция systemctl для Entware ([anch665/keendev](https://github.com/anch665/keendev) и аналоги), если нужна совместимость с unit-скриптами.
- Статус telemt / telemt-panel отображается в блоке установленных компонентов; удаление — здесь или в п. 88.

### S. Сервисные утилиты

В главном меню: клавиша **S** (или раздел «СЕРВИС»).

| Пункт | Действие |
| --- | --- |
| 1 | **Сжать bin/sbin (UPX)** — `upx --lzma --best` для `/opt/bin`, `/opt/sbin`, `/opt/usr/bin`, `/opt/libexec` (при необходимости ставит `upx`) |
| 2 | **Dropbear fix** — скрипт `sw.ext.io/ent/_addons/dropbear_fix` (с опцией сброса пароля root или без) |
| U | **Обновить все пакеты** — `opkg update && opkg upgrade` (также клавиша **U** из главного меню) |

### 16. TG WS Proxy Rust (tg-ws-proxy-rs)

[tg-ws-proxy-rs](https://github.com/valnesfjord/tg-ws-proxy-rs) — MTProto-прокси на Rust. В opkg его нет: ставит штатный `install.sh` проекта, он же пишет конфиг и Entware-инициализацию. Меню добавляет:

- **секрет и порт прежней Go-установки** (если осталась) — ссылки `tg://` не меняются, Go-сервис останавливается и снимается с автозапуска;
- **выбор сборки** — обычная или компактная (UPX), таблицей: размер на флеше и потребление памяти. По умолчанию обычная; компактная — когда флеш-памяти мало (образ распаковывается в ОЗУ и не вытесняется);
- **подбор параметров по замерам** — CF-домены и варианты лестницы проверяются штатной пробой бинаря, затем выводится список с временем каждого, и путь выбираете вы (Enter — быстрейший);
- **проверка связи до выдачи ссылки** — `resPQ` от DC Telegram, то есть вся цепочка, а не «порт открыт».

Конфиги: `/opt/etc/tg-ws-proxy-rs/config.conf` (`DC_IP`, `CF_DOMAIN`, `EXTRA_ARGS`), `secret.conf` рядом с ним.
Init: `/opt/etc/init.d/S99tg-ws-proxy-rs` (start / stop / status / restart)

Проба есть с версии **2.4.5**; у более старого бинаря меню предложит обновиться.

Секрет меню пишет само, до установки: генератор секрета в `install.sh` проекта использует `od -An`, которого BusyBox не знает, и на боксе без готового секрета установка падает. Если секрет остался от Go-версии, переносится он — тогда ссылки клиентов не меняются.

### 77. Change language

Мгновенное переключение интерфейса **ru ↔ en** (файл `/opt/etc/nfqws-menu.lang`).

### 88. Удаление пакетов

Показывает установленные компоненты и позволяет удалить выборочно:

```
Удаление:
  [N] nfqws2-keenetic / nfqws-keenetic-web / dpi-detector /
      awg-manager / tg-ws-proxy-rs / usque-keenetic /
      magitrickle / opera-proxy / KeenKit / telemt
  [a] Удалить все пакеты NFQWS
  [b] Удалить резервные копии (.bak.* / *-opkg)
  [0] Назад
```

- Пакеты NFQWS — `opkg remove --autoremove`
- **dpi-detector** — бинарник (`/opt/bin/dpi-detector` и др.)
- **awg-manager** — `opkg remove` + `rm -rf /opt/etc/awg-manager`
- **tg-ws-proxy-rs** — бинарь, init, конфиги
- **usque-keenetic** — `opkg remove --autoremove` + `/opt/etc/opkg/usque-keenetic.conf`
- **magitrickle** — `opkg remove` + запрос на удаление `/opt/etc/opkg/magitrickle.conf`
- **KeenKit** — удаление `/opt/keenkit.sh`
- **a)** — все пакеты NFQWS + dpi-detector
- **b)** — `*.bak.*`, `*.conf-opkg`, `*.list-opkg` в `/opt/etc/nfqws/`, `/opt/etc/nfqws2/`, `/opt/etc/nfqws2/lists/`

### 99. Обновить скрипт

Скачивает свежую версию из репозитория, перезаписывает `/opt/nfqws-menu.sh`, обновляет symlink `/opt/bin/menu`, сразу перезапускает меню (`exec`).

---

## Changelog

### 0.9.0 – 0.9.9

- **Блок «Установленные компоненты» переписан** — один awk-проход вместо десятков grep/sed/head на кадр меню; `is_installed` / `pkg_version` / `proc_running` — shell-циклы по кэшу без fork'ов; удалены неиспользуемые `print_pkg_info` / `print_tool_info`; на MIPS отрисовка заметно быстрее (0.9.0–0.9.1)
- **Очистка списков** — хелпер `_list_file_clean` (один awk вместо grep|sed|grep, срезает и `\r` из CRLF); переменная/файл `cleaned` убраны из ipset/hostlist-функций (0.9.5)
- **opkg без блокировок** — список пакетов читается напрямую из `/opt/lib/opkg/status` (запасной путь `/usr/lib/opkg/status`), без вызова `opkg` и без зависимости от lock; удалены `opkg_is_busy` / `opkg_cmd_timeout` и fallback на `opkg list-installed` (0.9.2–0.9.3)
- **Парсер status** — учитываются только блоки `Status: … installed`; устранён ложный ⭡ при residual-записях `not-installed` со старыми версиями (0.9.4)
- **ts-фулинг** — после применения стратегии с `--dpi-desync-fooling=ts` или `tcp_ts` выводится предупреждение про включение меток времени RFC 1323 на Windows (`netsh interface tcp set global timestamps=enabled`) (0.9.6)
- **rkn.list** — порядок источников: GitHub raw → jsDelivr/Fastly → ghproxy → зеркало mizulina (последним) (0.9.7)
- **TTL проверки обновлений** — 10 минут (600 с), по-прежнему переопределяется через `NFQWS_MENU_UPDATE_TTL` (0.9.8)
- **dpi-detector** — проверка обновлений через `upd_release_tag_any` (API `releases?per_page=1`, включает pre-release): `/releases/latest` не видит теги вида `v5.0.0-alpha.N` (0.9.9)

### 0.8.0 – 0.8.9

- **Зеркала GitHub** — порядок загрузки изменён на «оригинал → fastly → jsDelivr → ghproxy» (мёртвый ghproxy больше не первым); таймауты: connect 5 с, max 25 с (180 с только для крупных файлов); вывод «Пробуем: <url>» при скачивании install.sh (0.8.0)
- **download_sh_validated** — общий хелпер: перебирает все зеркала и туннели, проверяет размер/shebang/`sh -n` — битый источник даёт переход к следующему, а не «успех + crash» (0.7.8 → закреплено в 0.8.x)
- **Определение ARCH** — трёхступенчатое: `opkg print-architecture` → разбор `/opt/etc/opkg.conf` (arch-приоритеты, src/gz-URL: `mipselsf-k3.4` → mipsel и т.п.) → `uname -m` (для mips/mipsel не используется) (0.8.3–0.8.4)
- **Шапка меню** — `[ Архитектура: … ] [ Модель: … ]`: модель из RCI (`127.0.0.1:79/rci/show/version`, кэш на сессию), ARCH зелёный из opkg / жёлтый из conf; предупреждение установить «Модули ядра подсистемы Netfilter», если пакет `opkg-kmod-netfilter` отсутствует (0.8.5–0.8.6)
- **Без зависаний при занятом opkg** — busy определяется по реальному процессу (pidof); `print-architecture` всегда, `list-installed` с timeout 8 с (0.8.8–0.8.9)
- **Стратегии/списки** — обновлены `krushaaa.conf` (новые blob-пути и аргументы), добавлены записи BattlEye в hosts, конфиги hostlists (0.8.1–0.8.2)

### 0.7.0 – 0.8.0

- **Нумерация меню** — единый п. **1** (NFQWS / NFQWS2 / web / .ipk); стратегии/списки **2–8**; утилиты **10–16** (без TG WS Proxy Go)
- **п. 1 → 4** — установка `.ipk` напрямую (GitHub Releases / ghproxy / github.io) при блокировке opkg-репозитория
- **Проверка обновлений** — фоновый опрос (меню, tg-ws-proxy-rs, dpi-detector, awg-manager…); метка **⭡** в статусе и заголовке; TTL ~6 ч (`NFQWS_MENU_UPDATE_TTL`)
- **TG WS Proxy Go** убран из меню (остаётся миграция секрета/порта при установке Rust)

### 0.6.69

- **TG WS Proxy Rust (п. 17)** — отдельный пункт: `tg-ws-proxy-rs` ставится релизом с GitHub, секрет и порт прежней Go-установки переносятся
- **Подбор параметров** — CF-домены и варианты лестницы проверяются штатной пробой бинаря (`--check-listener`, 2.4.5+), список с временем каждого выводится на выбор
- **Сквозная проверка** — ссылка выдаётся только после `resPQ` от DC Telegram

### 0.6.59 – 0.6.67

- **Ввод** — убраны `stty` / `tty_setup` и чтение меню с `/dev/tty` (ломали Backspace → печать `^?`); обычный `read`; `drain_stdin` сохранён
- **п. 1** — убран пункт «патч десинка TLS reasm» (с NFQWS2 **≥ 1.3.1** фикс в официальном пакете)

### 0.6.50 – 0.6.58

- **п. 16** — **telemt / telemt-panel** (augin/telemt_script): install / panel / systemD-emu / remove; статус в `show_installed`
- **S** — сервисные утилиты: UPX-сжатие bin/sbin, Dropbear fix, **U** — `opkg upgrade` всех пакетов
- **п. 10–12** — без лишнего `confirm` перед запуском установщиков dpi-detector / awg-manager / KeenKit
- *(патч TLS reasm bin — временно в 0.6.50–0.6.65, снят в 0.6.66)*

### 0.6.47 – 0.6.49

- **Загрузки** — зеркала CDN для raw/API GitHub: jsDelivr, Fastly jsDelivr, ghproxy; offline-кэш стратегий в `/opt/etc/nfqws-menu/strategies/`
- **Список стратегий** — SUMS → API → offline-кэш
- **DNS (п. 9)** — пресет **NullsProxy**; привязки доменов: cdninstagram, Supercell через NullsProxy (п. 9–10), свой домен → 11

### 0.6.46

- **п. 3 apply_strategy** — `POLICY_NAME` / `POLICY_EXCLUDE`: стандартные (`nfqws` / `0`) не трогаются; нестандартные — восстановление по запросу (y/N)

### 0.6.43 – 0.6.45

- **п. 3 → 99 backup** — список `.bak.*` от свежего к старому; самый свежий выделен жёлтым; рядом со стратегией из конфига (`general (ALT11)`)

### 0.6.42

- **download_file** — сообщения fallback («Основной канал недоступен…», «Скачано через…») уходят в **stderr**, чтобы не попадали в `list=$(list_strategies …)` и не ломали нумерацию меню
- **list_strategies** — дополнительно фильтрует только строки `*.conf`

### 0.6.41

- **п. 3 Выбор стратегии** — в конце списка добавлен **99) восстановление из backup**: вывод `nfqws.conf.bak.YYYYMMDDHHMMSS` (V1) / `nfqws2.conf.bak.…` (V2), выбор файла, запись без бэкапа текущего, `fix_isp_interface`, перезапуск сервиса

### 0.6.40

- **Таймауты загрузок** — увеличены для сильного DPI: connect 10 с, max 30 с, wget 25 с (раньше 5 / 15 / 12); для крупных файлов (rkn) — до 180 с
- **п. 5 rkn.list** — при недоступности GitHub raw: jsDelivr / Fastly / ghproxy / зеркало `mizulina.shit.vc`; URL основного источника упрощён (`…/master/…` без `refs/heads`)

### 0.6.36 – 0.6.39

- **LBL_*** — подписи пунктов совпадают с номерами меню (`LBL_5`…`LBL_9`; удалён `LBL_7F`)
- **DoT/DoH пресеты** — Google, AdGuard Default/Family, ControlD Free, DNS4EU, Alibaba DNS, DNSPod; убраны нерабочие Tiar Japan
- **proc_running** — `grep -qF --` (fix при именах сервисов с ведущим `-`)

### 0.6.26 – 0.6.35

- **SHA256 blobs** — проверка локальных `.bin` по `strategies/blobs/SHA256SUMS`; перекачка при несовпадении хеша
- **Список стратегий** — из корневого `SHA256SUMS` (без GitHub API), API как fallback
- **Список blobs** (п. 7) — приоритет SUMS → API → fallback
- **Загрузки** — при блокировке основного канала `curl --interface` через туннели (`awg0`, `t2s0`, `nwg0`, `opkgtun0`, …); короткие таймауты
- **CI** — workflow `.github/workflows/sha256sums.yml` обновляет `SHA256SUMS` и `strategies/blobs/SHA256SUMS` (push / daily / manual)
- **п. 3** — авто `IPV6_ENABLED` по наличию глобального IPv6 на ISP-интерфейсе; сохранение привязки **rkn.list** в `MODE_LIST` при смене стратегии
- **DNS (п. 9)** — парсер только секция System (`proxy-tls` / `proxy-https`); Policy* и `*-filters` игнорируются

### 0.6.23 – 0.6.25

- **п. 5** — поддержка **v1 и v2** (выбор 1 / 2 / обе); размер существующего `rkn.list` в КБ вместо подсчёта строк
- **п. 5** — вставка в `MODE_LIST` через **awk** (CRLF, пустые кавычки, пробелы)
- **п. 10** — очистка дубликатов `dpi-detector` (`/tmp`, `/opt/root`) перед запуском / после установки

### 0.6.22

- **п. 8** — только IPv4; пропуск битых доменов (`..`, ведущая `.`); один IP на домен; предупреждение при &gt;64 записей (лимит Keenetic)
- **hosts** — исправлены `objects.githubusercontent.com`, `my.telegram.org`; убраны IPv6 и дубли discord

### 0.6.19 – 0.6.21

- **п. 3** — при применении стратегии: нормализация **CRLF → LF** в скачанном `.conf` (иначе `S51nfqws2` падает с `: not found` / битыми портами iptables)
- **ISP_INTERFACE** — при разборе значения из конфига удаляются `\r` и кавычки (исправлен «съехавший» вывод `[+]` → `"+]`)
- **п. 8** — **Обновление hosts**: секции из `hosts` в репозитории → `ndmc ip host` / удаление (`no ip host`) + save

### 0.6.18

- **п. 7** — ускорен разбор конфига: один проход `awk` вместо shell+grep на каждую строку

### 0.6.16 – 0.6.17

- **п. 5** — если `rkn.list` уже есть, спрашивает об обновлении (по умолчанию **Нет**)
- **п. 5** — перезапуск `S51nfqws2` только при изменениях (список и/или `MODE_LIST`)

### 0.6.15

- Базовая линейка 0.6.x (см. ниже)

### 0.6.x (основные изменения относительно 0.5.x)

- **п. 5** — загрузка **rkn.list** (125k+ доменов, zapret4rocket) + автодобавление в `MODE_LIST`
- **п. 7** — смена активных **fake:blob** (локальные + из репозитория)
- **п. 8** — **Обновление hosts** через `ndmc`
- **п. 15** — **MagiTrickle** (установка/обновление/удаление)
- **п. 15** — **telemt / telemt-panel**; **п. 16** — **TG WS Proxy Rust**
- **S / U** — UPX, Dropbear fix, opkg upgrade
- **п. 8** — Управление DoT/DoH: пресеты Xbox-DNS / NullsProxy / Supercell и др.
- **SHA256** blobs + список стратегий из SUMS; CDN/offline-кэш; fallback через VPN-туннели
- Нумерация (0.8.x): 1 = install, 2–8 = стратегии/списки, 10–16 = утилиты
- Статус: magitrickle / telemt / tg-ws-proxy-rs; метка **⭡** при новой версии
- Без принудительного `export LD_LIBRARY_PATH` (совместимость ndmc / Entware wget)
- Обычный `read` в меню (без `stty` / принудительного erase)

### 0.5.17

- **usque-keenetic** (п. 14) — установка/обновление; удаление в п. 88

### 0.5.16

- **DNS-счётчик** — только секция System; Policy0/1 и `proxy-*-filters` не учитываются

### 0.5.14 – 0.5.15

- Счётчик DoT/DoH по слотам (записи `server-tls` / `server-https`), а не по уникальным targets
- Ужесточён парсер `show dns-proxy`

### 0.5.13

- **LD_LIBRARY_PATH / ndmc_cli** — OPKG-путь по умолчанию; `ndmc` через системные библиотеки (как у spatiumstas)

### 0.5.11 – 0.5.12

- **TG WS Proxy Go** (п. 13) — установка/обновление через feedly
- Удаление `tg-ws-proxy` в п. 88 (+ опционально `feedly.conf`)

### 0.4.0 → 0.5.x

- **Управление DoT/DoH** через `ndmc`
- Утилиты: awg-manager, KeenKit; удаление — п. 88
- Быстрый запуск `menu`, статус только установленного, ⚡, кэш opkg/процессов
- Переключение языка (п. 77)

---

## Структура репозитория

```
nfqws-menu/
├── nfqws-menu.sh          # Главный скрипт меню
├── hosts                  # Секции IP DOMAIN для п. 8 (ndmc ip host)
├── SHA256SUMS             # Хеши файлов репозитория (список стратегий без API)
├── README.md
├── .github/workflows/
│   └── sha256sums.yml     # Автообновление SHA256SUMS
└── strategies/
    ├── blobs/
    │   ├── *.bin          # Бинарные шаблоны
    │   └── SHA256SUMS     # Эталоны для проверки blobs на роутере
    ├── lists/             # Готовые списки доменов / IP
    │   ├── user.list
    │   ├── exclude.list
    │   ├── ipset.list
    │   └── ipset_exclude.list
    ├── nfqws1/            # Стратегии для nfqws-keenetic (v1)
    └── nfqws2/            # Стратегии для nfqws2-keenetic (v2)
```

### Как добавить свою стратегию

1. Файл `имя.conf` в `strategies/nfqws1/` или `strategies/nfqws2/`.
2. Полный конфиг (`ISP_INTERFACE=`, `NFQWS_ARGS=` / `NFQWS_BASE_ARGS=` и т.д.).
3. При необходимости — `.bin` в `strategies/blobs/`, списки в `strategies/lists/`.
4. После push workflow обновит `SHA256SUMS` / `strategies/blobs/SHA256SUMS`; скрипт подхватит стратегию из SUMS (или через GitHub API).

---

## Требования (Keenetic / Netcraze)

1. Установлен **Entware** (внутренняя память или USB).
2. В веб-интерфейсе — **модули ядра Netfilter** (`OPKG → Kernel modules for Netfilter`).\
   На старых прошивках компонент появляется после включения IPv6.
3. Рекомендуется отключить DNS провайдера и настроить DoT/DoH.
4. Команды выполняются **в среде Entware**, не в CLI Keenetic.

---

## Полезные команды вручную

```bash
# Статус сервисов
/opt/etc/init.d/S51nfqws status          # v1
/opt/etc/init.d/S51nfqws2 status         # v2
/opt/etc/init.d/S99tg-ws-proxy status    # TG WS Proxy
/opt/etc/init.d/S51usque status          # usque
/opt/etc/init.d/S99magitrickle status    # MagiTrickle

# Порт веб-интерфейса
netstat -lnt | grep ':90'

# Перезапуск
/opt/etc/init.d/S51nfqws restart
/opt/etc/init.d/S51nfqws2 restart
/opt/etc/init.d/S99tg-ws-proxy restart
/opt/etc/init.d/S51usque restart
/opt/etc/init.d/S99magitrickle restart

# Информация о пакете
opkg info nfqws-keenetic
opkg info nfqws2-keenetic
opkg info nfqws-keenetic-web
opkg info tg-ws-proxy
opkg info usque-keenetic
opkg info magitrickle

# Конфиги
vi /opt/etc/nfqws/nfqws.conf
vi /opt/etc/nfqws2/nfqws2.conf
vi /opt/etc/tg-ws-proxy/config.conf
vi /opt/etc/tg-ws-proxy/secret.conf
vi /opt/etc/usque/usque.conf

# Интерфейс провайдера
ip route | grep ^default
# или
route | grep ^default

# DNS-proxy (DoT/DoH)
ndmc -c show dns-proxy

# Быстрый запуск меню
menu
```

---

## Лицензия / отказ от ответственности

Материалы подготовлены в ознакомительных и научно-технических целях.\
Использование на свой страх и риск. Автор не несёт ответственности за последствия.

Стратегии адаптированы на основе [Flowseal/zapret-discord-youtube](https://github.com/Flowseal/zapret-discord-youtube),\
подготовлены [@Nare51](https://github.com/Nare51) с использованием искусственного интеллекта.\
Официальные пакеты NFQWS: [nfqws](https://github.com/nfqws).