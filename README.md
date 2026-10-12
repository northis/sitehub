# SiteHub

Входной контейнер для сервера Ubuntu: [Traefik](https://traefik.io/) v3 терминирует HTTPS,
автоматически выпускает и продлевает wildcard-сертификат Let's Encrypt для всех поддоменов
вашего домена и подключает новые сайты-контейнеры **без правок конфигурации и перезапусков**.

```
                 Интернет
                    │
   Cloudflare DNS:  A *.ваш-домен → IP сервера   (одна разовая запись; для Access — проксируется)
                    │
           ┌────────▼─────────┐
           │ traefik (SiteHub) │  :80 → редирект :443
           │ Let's Encrypt     │  :443 TLS, сертификат *.ваш-домен
           │ автообнаружение   │  (DNS-01 через Cloudflare API)
           └───┬────┬────┬────┘
               │    │    │     docker-сеть "proxy"
            site1 site2 siteN  (контейнеры сайтов из других репозиториев)
```

## Структура репозитория

```
├── docker-compose.yml      # входной контейнер traefik
├── traefik/traefik.yml     # шаблон статической конфигурации (рендерится при старте)
├── traefik/dynamic/        # bootstrap-роутер, security-заголовки, VPN-маршруты (hot-reload)
├── access/                 # защита от обхода Cloudflare Access
│   ├── systemd/            #   ipset-диапазоны CF и правило DOCKER-USER (юниты, таймер)
│   └── verifier/           #   forwardAuth-сервис проверки Access-JWT (Node, без зависимостей)
├── softether/              # VPN-сервер SoftEther (compose, systemd-юниты, шаблон секретов)
├── .env.example            # шаблон настроек (секреты — в .env, не в git)
├── scripts/
│   ├── install.sh          # идемпотентная установка на Ubuntu
│   ├── check.sh            # диагностика (read-only)
│   ├── install-vpn.sh      # идемпотентная установка варианта «сайты за VPN»
│   ├── check-vpn.sh        # диагностика VPN-варианта (read-only)
│   ├── install-access-guard.sh   # защита от обхода Access (диапазоны CF + недельный таймер)
│   └── install-access-verify.sh  # проверка Access-JWT на входе (forwardAuth)
├── examples/stub-site/     # сайт-заглушка для проверки
└── examples/vpn-site-windows/  # эталон сайта на Windows за VPN
```

## Требования

- Сервер Ubuntu (поддерживается 24.04 LTS) с публичным IP; свободные порты **80** и **443**.
- Домен с DNS на **Cloudflare**.
- API-токен Cloudflare с минимальными правами:
  1. Откройте <https://dash.cloudflare.com/profile/api-tokens> → **Create Token**.
  2. Шаблон **Edit DNS** → Permissions: `Zone — DNS — Edit`.
  3. Zone Resources: **только ваш домен** (не All zones).
  4. Скопируйте токен — он понадобится для `.env`.
- Email для аккаунта Let's Encrypt (уведомления о проблемах с сертификатами).

## Установка

```bash
git clone https://github.com/northis/sitehub
cd sitehub
chmod +x ./scripts/install.sh
sudo ./scripts/install.sh
```

Скрипт **идемпотентен**: каждый шаг пропускается, если уже выполнен, — безопасный
повторный запуск в любой момент. Гарантии: существующие Docker-контейнеры не
перезапускаются, конфигурация Docker-демона не меняется, правила ufw только
добавляются. Если `.env` отсутствует, скрипт создаст его интерактивно
(спросит `DOMAIN`, `LE_EMAIL`, `CF_DNS_API_TOKEN`; права файла — 600).

Что делает скрипт:

1. **Preflight** (до любых изменений): порты 80/443 свободны (иначе — выход с именем
   процесса), `.env` заполнен, мягкая проверка wildcard-DNS.
2. Docker — устанавливает только если отсутствует (официальный apt-репозиторий).
3. ufw — разрешает `OpenSSH`, `80/tcp`, `443/tcp`; включает, только если ещё не активен.
4. Создаёт docker-сеть `proxy`.
5. Поднимает traefik (`docker compose up -d`), ждёт healthy-статуса и выпуска
   wildcard-сертификата `*.<ваш-домен>` (запрос сертификата запускает
   bootstrap-роутер в `traefik/dynamic/bootstrap.yml`, сайты для этого не нужны).

### Разовая DNS-запись

В панели Cloudflare создайте запись (один раз на домен):

| Тип | Имя | Содержимое |
|---|---|---|
| A | `*` | публичный IP сервера |
| A | `@` | публичный IP сервера (опционально, для apex-домена) |

Proxy-статус (оранжевое облачко) — **DNS only** (серое), чтобы трафик шёл напрямую
на сервер. После этого новые поддомены DNS-действий **не требуют**.

Если вы планируете закрывать сайты через Cloudflare Access, запись `*` должна
быть **проксируемой** (оранжевое облачко) — см. раздел «Доступ только для
своих». В этом режиме `check.sh` показывает WARN по DNS — это ожидаемо.

## Добавление сайта

Новый сайт — это контейнер из любого репозитория, подключённый по простому контракту:
внешняя сеть `proxy` + три метки. Ничего в SiteHub менять и перезапускать не нужно —
Traefik подхватит сайт за несколько секунд (hot-plug).

Минимальный `docker-compose.yml` сайта:

```yaml
services:
  site1:
    image: myrepo/site1:latest   # любой HTTP-сервис (без TLS внутри)
    restart: unless-stopped
    networks:
      - proxy
    labels:
      traefik.enable: "true"
      traefik.http.routers.site1.rule: "Host(`site1.ваш-домен`)"
      traefik.http.services.site1.loadbalancer.server.port: "8080"
    # ports: НЕ указывать — внешний трафик приходит только через Traefik

networks:
  proxy:
    external: true
```

Деплой: `docker compose up -d` — и сайт доступен на `https://site1.ваш-домен`.

Если сайт приватный и вы включили проверку Access-JWT на входе (см. «Доступ
только для своих»), добавьте четвёртую метку — без неё проверка не применится:

```yaml
      traefik.http.routers.site1.middlewares: "cf-access-verify@file"
```

Что гарантирует Traefik каждому подключённому сайту:

- валидный wildcard-сертификат Let's Encrypt (автопродление, действий не требует);
- редирект всех HTTP-запросов на HTTPS (301/308);
- HSTS (`Strict-Transport-Security`: год, включая поддомены) на всех сайтах;
- заголовки `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`,
  `X-Forwarded-Port` — приложение должно их учитывать (например, для https-ссылок);
- 503, пока контейнер сайта не запущен, и автоматическое восстановление после запуска.

Ограничения:

- wildcard-сертификат покрывает **один уровень** поддоменов: `site1.ваш-домен` — да,
  `a.b.ваш-домен` — нет;
- значение `Host(...)` должно быть уникальным на сервере (при дубле Traefik логирует
  конфликт, и поведение зависит от порядка обнаружения);
- TLS-метки сайтам не нужны: certresolver и домены заданы по умолчанию на входе.

## Доступ только для своих: Cloudflare Access (Zero Trust)

Опциональный режим: сайты можно закрыть от посторонних **беспарольной
авторизацией** [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
(Zero Trust). Проверка входа происходит на сети Cloudflare, **до сервера**:
Traefik и сайт об авторизации не знают и по-прежнему доверяют любому запросу,
который до них дошёл. Пока пользователь не вошёл, запрос до контейнера сайта
просто не доходит — менять сайты не нужно.

```
Браузер → Cloudflare (Access: вход, политика) → Traefik → сайт
                ↑ без входа не пропускает      ↑ об авторизации не знает
```

- вход **без пароля**: пользователь вводит свой email и получает одноразовый
  код письмом (One-time PIN) — пароль не создаётся и не хранится;
- доступ — только у адресов из политики: вы и те, кого вы добавите;
- wildcard-приложение покрывает все поддомены сразу — новые сайты защищены
  автоматически;
- бесплатный план Zero Trust — до 50 пользователей.

### Как это работает

Access — identity-aware proxy: Cloudflare пропускает к серверу только запросы
с действующей сессией Access, остальные получают страницу входа. Сайт
продолжает получать обычные HTTP-запросы и о защите не знает (при желании он
может прочитать email вошедшего из заголовка `Cf-Access-Jwt-Assertion`, но
это не обязательно).

Условие — **проксируемая DNS-запись** (оранжевое облачко): Access видит только
трафик, проходящий через сеть Cloudflare. При сером облачке запросы идут
напрямую на сервер, и Access их не касается.

Wildcard-сертификат это не ломает: Let's Encrypt выпускается через DNS-01 (не
HTTP-01), проксирование ему не мешает. Проверьте, что режим шифрования зоны —
**Full (strict)** (**SSL/TLS → Overview**): Cloudflare будет проверять
сертификат на сервере, а не игнорировать его.

### Включение

1. **Проксируйте запись**: в Cloudflare включите оранжевое облачко у записи
   `A *` (см. «Разовая DNS-запись»).
2. **Создайте организацию Zero Trust**: Dashboard → **Zero Trust**, задайте
   team name и план (Free).
3. **Добавьте беспарольный вход**: Zero Trust → **Integrations** →
   **Identity providers** → **Add new identity provider** → **One-time PIN**.
   Новым организациям Cloudflare по умолчанию включает вход через аккаунт
   Cloudflare — его можно оставить, но беспарольный вход даёт именно
   One-time PIN.
4. **Создайте приложение**: Zero Trust → **Access controls** →
   **Applications** → **Create new application** → **Self-hosted and private**:
   - **Public hostname**: Subdomain `*`, Domain `ваш-домен` — покроет все
     текущие и будущие поддомены. Чтобы закрыть только отдельные сайты,
     укажите конкретный поддомен (`site1`);
   - **Policy**: Action **Allow**, Include → **Emails** — ваш адрес (по адресу
     на строку);
   - **Login methods**: включите **One-time PIN**;
   - **Session duration**: например, `24 hours` — как часто придётся входить
     заново.
5. **Включите deny-by-default (рекомендуется)**: Zero Trust → **Access
   controls** → **Access settings** → **Block traffic to all domains in this
   account**. Тогда поддомен без приложения будет закрыт (Error 1050), и новый
   сайт не окажется публичным по ошибке. Настройка действует на **все домены
   аккаунта Cloudflare** — публичные сайты придётся перечислить явно (ниже).

Проверка: откройте `https://site1.ваш-домен` в приватном окне — вместо сайта
должна открыться страница входа Cloudflare, после ввода кода — сайт. `curl`
без сессии получает редирект на страницу входа:

```bash
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' https://site1.ваш-домен/
# ожидание: 302 -> https://<team-name>.cloudflareaccess.com/...
```

### Кого пускать

- **Добавить человека**: приложение → **Policies** → правило **Allow** →
  **Include → Emails** — добавьте адрес. Письмо с кодом приходит только
  адресам из политики; остальным страница всё равно говорит «код отправлен».
- **Убрать человека**: удалите адрес из политики. Действующие сессии доживут
  до конца Session duration; прервать сразу — Zero Trust → **Team &
  Resources** → **Users** → **Revoke**.
- **Не делайте** политику с Include → **Everyone** и не оставляйте в политике
  только **Login Methods → One-time PIN**: так Access пустит любого, кто
  введёт свой email.
- Для программного доступа (скрипты, мониторинг) у Cloudflare есть
  **service tokens** — вход в браузере не нужен.

### Публичные сайты-исключения

Если большинство сайтов приватные, а отдельные должны быть открыты всем:

- проще всего не использовать wildcard-приложение, а завести приложения
  только для приватных поддоменов;
- либо оставить wildcard и добавить отдельное приложение для публичного
  поддомена (`public.ваш-домен`) с политикой **Bypass** (Include → Everyone):
  по документации Cloudflare более специфичное правило имеет приоритет, но
  поведение стоит проверить именно в вашем аккаунте.

**Bypass** полностью отключает Access для поддомена и не логирует запросы —
для внутренних сайтов он не подходит.

Если включена проверка Access-JWT на входе (см. ниже), публичный поддомен
оставляйте **без** метки `cf-access-verify@file`, а глобальный режим проверки
(`--global`) с публичными сайтами несовместим: у Bypass-запросов токена нет.

### Чтобы Access не обошли напрямую

Access защищает только трафик через Cloudflare. Сервер по-прежнему слушает
443 на публичном IP: зная IP, можно обратиться к Traefik напрямую с нужным
заголовком `Host` и попасть на сайт мимо Access. Закройте это, разрешив
80/443 (опубликованные порты входного контейнера) только с диапазонов
Cloudflare. Важно: **ufw порты Docker-контейнеров
не фильтрует** — правило нужно в цепочке `DOCKER-USER`. Включайте после того,
как Access настроен, а запись `*` проксируется:

```bash
chmod +x ./scripts/install-access-guard.sh   # если файл ещё не исполняемый
sudo ./scripts/install-access-guard.sh
```

Скрипт **идемпотентен** и делает всё сам:

- создаёт наборы `cloudflare4`/`cloudflare6` (ipset) и правило `DOCKER-USER`:
  80/443 на внешнем интерфейсе доступны только с диапазонов Cloudflare (если
  у сервера есть IPv6 и Docker управляет им — то и в `ip6tables`). Правило
  матчит **исходный** порт назначения (до DNAT), поэтому другие сервисы на
  сервере не затрагиваются, даже если их внутренний порт — 80 или 443
  (например, VPN, опубликованный как `8433:443`);
- ставит systemd-юниты: `sitehub-cf-ips.service` применяет правило при
  загрузке и после `systemctl restart docker` (перезапуск Docker очищает
  цепочку), а `sitehub-cf-ips-refresh.timer` **раз в неделю** (по
  понедельникам) скачивает актуальные `ips-v4`/`ips-v6`, атомарно подменяет
  содержимое наборов и повторно применяет правило, если оно пропало. При
  ошибке загрузки или подозрительно коротком ответе старые диапазоны
  остаются в силе — трафик не обрывается;
- отказывается включаться, если запись `*` резолвится напрямую на IP сервера:
  тогда правило отрезало бы сайты от интернета. Включите оранжевое облачко и
  повторите; проверку можно пропустить флагом `--force`.

Правило действует только на пакеты с внешнего интерфейса: SSH, VPN-сайты и
трафик внутри Docker не затрагиваются.

Проверка и откат:

```bash
systemctl list-timers sitehub-cf-ips-refresh.timer   # следующий запуск
sudo systemctl start sitehub-cf-ips-refresh.service  # обновить сейчас
journalctl -u sitehub-cf-ips-refresh.service         # логи обновления
sudo ipset save cloudflare4 | head                   # текущие диапазоны
sudo iptables -L DOCKER-USER -v -n | grep DROP       # счётчики сработавших правил
sudo ./scripts/install-access-guard.sh remove        # снять защиту
```

Отключать защиту только через `remove`: юниты сами возвращают правило
(например, после перезапуска Docker), поэтому `systemctl stop` — не выключатель.

**Важно:** фильтр проверяет только источник запроса — что он пришёл из сети
Cloudflare, — но не то, что посетитель прошёл Access. Кто может отправить
запрос с CF-адреса (например, Worker в вашей же зоне), обойдёт такую защиту;
закрывает это проверка Access-JWT ниже.

### Проверка Access-JWT на входе (опционально)

Cloudflare добавляет к каждому запросу, прошедшему Access, заголовок
`Cf-Access-Jwt-Assertion`. Если проверять его на входе, запрос дойдёт до
сайта только с действующей сессией: подпись RS256, срок действия, `iss` и
`aud` сверяются с ключами и приложением вашей команды. Запрос с CF-адреса без
сессии получает 401/403 — обход через Workers перестаёт работать.

Установка (идемпотентно):

```bash
chmod +x ./scripts/install-access-verify.sh   # если файл ещё не исполняемый
sudo ./scripts/install-access-verify.sh
```

Скрипт спросит **team domain** (`https://<team-name>.cloudflareaccess.com`) и
**Application Audience (AUD)** приложения (Zero Trust → Access controls →
Applications → Configure → Additional settings), создаст
`access/verifier/.env`, соберёт и запустит контейнер `cf-access-verify`:
наружу портов нет, он доступен только Traefik из docker-сети `proxy`.

Дальше включите проверку на приватных сайтах — четвёртая метка на роутере
(Traefik подхватит её без перезапуска):

```yaml
      traefik.http.routers.site1.middlewares: "cf-access-verify@file"
```

Или сразу для всех сайтов:

```bash
sudo ./scripts/install-access-verify.sh --global   # CF_ACCESS_VERIFY_GLOBAL=true
```

Глобальный режим строже, но публичные сайты-исключения (политика **Bypass**)
начнут получать 401 — если они нужны, используйте метки.

Что проверяется: подпись RS256 по публичным ключам команды
(`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`; кэш на час,
перечитывается при ротации ключей), `iss`, `aud` (AUD приложения),
`exp`/`nbf`. Клиентские заголовки в сервис проверки не передаются, а
`Cf-Access-Authenticated-User-Email`, который сервис возвращает из
проверенного токена, Traefik **перезаписывает** — сайт может ему доверять.

Проверка и откат:

```bash
docker logs cf-access-verify    # отказы с причиной (allow/deny + email)
# локальный запрос идёт мимо Cloudflare, поэтому 401 — это ожидаемо:
curl -ks -o /dev/null -w '%{http_code}\n' -H "Host: site1.ваш-домен" https://localhost/
sudo ./scripts/install-access-verify.sh remove
```

`remove` не убирает метки с сайтов: снимите их сами, иначе сайты будут
отвечать 500 (цель middleware исчезла).

### Ограничения

- Access действует только на проксируемые (оранжевые) записи.
- **Фильтр по диапазонам Cloudflare — это фильтр источника, а не проверка
  входа.** Диапазоны общие для всех клиентов Cloudflare, и запрос из сети CF
  такой фильтр пропустит: например, отправленный Worker'ом **в вашей же
  зоне** (по умолчанию он обращается к своему домену напрямую к origin, минуя
  Access — см. флаг `global_fetch_strictly_public`). Хостинг собственного
  сайта за Cloudflare обхода не даёт: браузер посетителя подключается со
  своего адреса, подставить чужой `Host` нельзя, `resolveOverride` работает
  только внутри своей зоны. Дыру закрывает проверка Access-JWT на входе (см.
  выше), а максимально строгий вариант — **Cloudflare Tunnel** (origin вообще
  не слушает публично).
- Wildcard `*.ваш-домен` покрывает **один уровень** поддоменов, как и
  сертификат: `site1.ваш-домен` — да, `a.b.ваш-домен` — нет.
- Код One-time PIN одноразовый и живёт 10 минут; письма приходят с
  `noreply@notify.cloudflare.com` — добавьте адрес в allowlist, если почта
  фильтрует такие письма.
- При включённом Access `check.sh` показывает WARN по DNS: запись `*`
  проксируется, и wildcard отвечает адресами Cloudflare, а не IP сервера, —
  это ожидаемо.

## Диагностика

```bash
./scripts/check.sh        # сводка OK/WARN/FAIL: traefik, порты, сеть, сертификат, DNS, редирект
docker logs traefik       # логи входного контейнера
docker logs <сайт>        # логи контейнера сайта
docker logs cf-access-verify   # проверка Access-JWT (если установлена)
```

`check.sh` ничего не изменяет (read-only) и показывает остаток срока действия
сертификата (WARN, если меньше 21 дня).

## Пример: сайт-заглушка

Для сквозной проверки после установки:

```bash
cd examples/stub-site
DOMAIN=ваш-домен docker compose up -d
```

Откройте `https://stub.ваш-домен` — страница должна открыться с валидным
сертификатом; `http://` редиректит на `https://`. Удаление примера:
`docker compose down` из каталога `examples/stub-site`.

## Сайты за VPN (SoftEther)

Вариант для сайтов, которые работают на Windows-машине за NAT (например, за
MikroTik): машина подключается к SoftEther-серверу на Ubuntu исходящим
соединением, получает постоянный адрес в VPN `10.77.77.0/24`, а Traefik
маршрутизирует к её сайтам через туннель. Сайты на Ubuntu продолжают работать
как раньше — варианты не конфликтуют.

```
Windows (за NAT)                      Ubuntu (публичный IP)
┌───────────────────┐                ┌─────────────────────────────────────┐
│ SoftEther Client  │ ── TCP/8443 ─▶ │ softether: хаб REMOTE, local bridge │
│ 10.77.77.21       │ ◀── VPN (L2) ─ │ tap_vpn 10.77.77.1/24               │
│ Docker Desktop    │                │ traefik → vpn-sites.yml             │
│ site1 :8080       │ ◀───────────── │   http://10.77.77.21:8080           │
└───────────────────┘                └─────────────────────────────────────┘
```

### Установка на Ubuntu

На сервере с уже установленным SiteHub:

```bash
sudo ./scripts/install-vpn.sh
```

**Если SoftEther уже установлен своим проектом** (например, в `/opt/softether`):
у чужой установки обычно **то же имя compose-проекта** (по имени каталога) и
**то же имя контейнера** `softether`, а Docker Compose считает контейнеры по
проекту и сервису — то есть запуск варианта репозитория **заменит** этот
контейнер (данные чужого проекта останутся в его каталоге, но его
конфигурация перестанет использоваться). Скрипт проверяет это в preflight и
останавливается с ошибкой; чтобы перейти на вариант репозитория, сначала
осознанно остановите и удалите чужой контейнер. И помните: 443 занят Traefik,
поэтому чужой SoftEther при сосуществовании должен публиковаться на другом
порту (например, `8443:443`).

Скрипт **идемпотентен**: каждый шаг пропускается, если уже выполнен. Что он делает:

1. **Preflight** (до изменений): root, Docker, docker-сеть `proxy`, свободный порт
   `8443/tcp` (занят — выход с именем процесса; при работающем контейнере
   `softether` — SKIP).
2. **Секреты**: создаёт `softether/.env` (права 600, в git не попадает; шаблон —
   `softether/.env.example`) и **один раз** печатает сгенерированный пароль
   `VPN_USER_PASSWORD` — сохраните его для Windows.
3. **systemd-юниты**: `sitehub-vpn-tap.service` создаёт `tap_vpn`
   (`10.77.77.1/24`, MTU 1400) до старта Docker; `sitehub-vpn-net.service`
   добавляет правила iptables после старта Docker. Скрипты ставятся в
   `/usr/local/sbin/`, юниты — в `/etc/systemd/system/`.
4. **Firewall**: `ufw allow 8443/tcp` (только добавление).
5. **SoftEther**: хаб `REMOTE`, пользователь `site1` с адресом `10.77.77.21`,
   SecureNAT с DHCP (`10.77.77.100–200`), единственный TCP-слушатель `8443`
   (443/992/1194/5555 удалены), UDP выключен; сертификат сервера сохраняется в
   `softether/data/server.cer`.
6. **Мост**: контейнер `softether` (host net, `restart: unless-stopped`,
   `softether/compose.yaml`) и local bridge `REMOTE ↔ tap_vpn`.

Если Traefik установлен до появления file provider, один раз примените изменения
входного контейнера (ro-монтирование `traefik/dynamic`):

```bash
docker compose up -d
```

Добавление ещё одного сайта-хоста (например, второй Windows-машины): адрес —
внутри `10.77.77.0/24`, вне DHCP-пула `10.77.77.100–200`, не `.1` и не `.254`:

```bash
sudo ./scripts/install-vpn.sh add-user site2 10.77.77.22
```

Скрипт напомнит добавить маршрут в `traefik/dynamic/vpn-sites.yml`.

### Настройка Windows

1. Установите **SoftEther VPN Client** и создайте подключение (**New Connection
   Setting**):
   - **Host Name** — `IP-сервера`, **Port Number** — `8443`;
   - **Virtual Hub Name** — `REMOTE`;
   - **User Name** — `site1`, **Password** — `VPN_USER_PASSWORD` из вывода
     `install-vpn.sh` (или из `softether/.env`).
2. **Сертификат сервера (pinning)**: скопируйте `softether/data/server.cer` с
   Ubuntu на Windows; в свойствах подключения включите **Always Verify Server
   Certificate** и зарегистрируйте перенесённый сертификат через **Specify
   Individual Cert**. Сертификат самоподписанный — отключать проверку не следует,
   pinning защищает от подмены сервера.
3. **Ускорение UDP — выключить**: в **Advanced Settings** включите флаг
   **Disable UDP Acceleration** (по умолчанию флаг снят, ускорение разрешено).
4. **Автоподключение**: выберите подключение в VPN Client Manager и нажмите
   **Set as Startup Connection** в меню **Connect**; при необходимости включите
   **Reconnection Endless (Keep VPN Session Always)**.
5. Проверьте, что SoftEther-адаптер получил адрес `10.77.77.21` (DHCP по note
   пользователя); шлюз и DNS клиенту не выдаются.

**Docker Desktop.** Сайты — обычные контейнеры, но порт должен публиковаться на
**все интерфейсы**, а не на `127.0.0.1`: Traefik подключается к адресу
`10.77.77.21`, а не к localhost Windows-машины. Готовый пример —
`examples/vpn-site-windows/`:

```yaml
services:
  site1:
    image: nginx:alpine
    container_name: vpn-site1
    restart: unless-stopped
    ports:
      - "8080:80"          # на все интерфейсы; не 127.0.0.1
    volumes:
      - ./index.html:/usr/share/nginx/html/index.html:ro
```

Деплой (из каталога примера на Windows):

```bash
docker compose up -d
```

**Windows Firewall.** Разрешите входящие на порт сайта только с `10.77.77.1`
(адрес tap после MASQUERADE на Ubuntu) — в PowerShell от администратора:

```powershell
New-NetFirewallRule `
  -Name "SiteHub-VPN-Site1" `
  -DisplayName "SiteHub: site1 from VPN" `
  -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 8080 `
  -RemoteAddress 10.77.77.1 `
  -Profile Any
```

**Автозапуск.** VPN-клиент поднимает стартовое подключение при загрузке Windows;
Docker Desktop запускается только после входа пользователя, поэтому включите
автологин. Альтернатива — Docker Engine в WSL2 (запускается как служба, без
Docker Desktop).

### Маршрут в Traefik

На Ubuntu добавьте запись в `traefik/dynamic/vpn-sites.yml` — файл смонтирован в
Traefik ro, `watch: true` подхватывает изменения без перезапуска:

```yaml
http:
  routers:
    site1-vpn:
      rule: "Host(`site1.ваш-домен`)"
      service: site1-vpn
  services:
    site1-vpn:
      loadBalancer:
        servers:
          - url: "http://10.77.77.21:8080"
```

Правила:

- имя роутера и сервиса (`site1-vpn`) должно быть уникальным на сервере;
- значение `Host(...)` уникально; поддомен — один уровень (`site1.ваш-домен` —
  да, `a.b.ваш-домен` — нет);
- TLS и редирект HTTP→HTTPS наследуются с entrypoint — отдельные TLS-настройки
  не нужны;
- сайты на одном Windows-хосте используют один адрес (`10.77.77.21`) и разные
  порты.

### Проверка

С Ubuntu — доступность сайта внутри VPN:

```bash
curl -sS http://10.77.77.21:8080/ -o /dev/null -w '%{http_code}\n'    # ожидание: 200
```

Снаружи — через Traefik:

```bash
curl -sS https://site1.ваш-домен/ -o /dev/null -w '%{http_code} %{ssl_verify_result}\n'    # ожидание: 200 0
```

Общая диагностика VPN-варианта (read-only, код 1 при FAIL):

```bash
sudo ./scripts/check-vpn.sh
```

### Диагностика

`check-vpn.sh` проверяет контейнер `softether`, `tap_vpn` и адрес, local bridge,
слушатель `8443`, правила iptables, ufw, сессии/DHCP и доступность сайтов из
`traefik/dynamic/vpn-sites.yml`; каждая строка — `OK`/`WARN`/`FAIL` с подсказкой.

Логи:

```bash
docker logs softether    # сервер, мост, подключения клиентов
docker logs traefik      # маршрутизация и ошибки в vpn-sites.yml
```

Сессии и выдачи DHCP внутри контейнера (hub-команды, пароль — `VPN_HUB_PASSWORD`
из `softether/.env`):

```bash
sudo docker exec softether vpncmd localhost:8443 /SERVER /HUB:REMOTE /PASSWORD:'<пароль хаба>' /CMD:"SessionList"
sudo docker exec softether vpncmd localhost:8443 /SERVER /HUB:REMOTE /PASSWORD:'<пароль хаба>' /CMD:"DhcpTable"
```

### Обновление

```bash
docker compose -f softether/compose.yaml pull && docker compose -f softether/compose.yaml up -d
```

Повторный `sudo ./scripts/install-vpn.sh` также идемпотентен и не затрагивает
Ubuntu-сайты.

### Откат

```bash
# 1. Остановить и удалить контейнер SoftEther:
docker compose -f softether/compose.yaml down

# 2. Остановить юниты: их ExecStop снимет правила iptables и удалит tap_vpn:
sudo systemctl disable --now sitehub-vpn-tap.service sitehub-vpn-net.service

# 3. Удалить юниты и скрипты:
sudo rm /etc/systemd/system/sitehub-vpn-tap.service /etc/systemd/system/sitehub-vpn-net.service
sudo rm /usr/local/sbin/sitehub-vpn-tap /usr/local/sbin/sitehub-vpn-net
sudo systemctl daemon-reload

# 4. Закрыть порт:
sudo ufw delete allow 8443/tcp
```

Если юниты уже удалены, а правила или `tap_vpn` остались, удалите их вручную:

```bash
sudo iptables -D DOCKER-USER -i tap_vpn -j ACCEPT
sudo iptables -D DOCKER-USER -o tap_vpn -j ACCEPT
sudo iptables -t nat -D POSTROUTING -s <подсеть proxy> -d 10.77.77.0/24 -o tap_vpn -j MASQUERADE
sudo iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o tap_vpn -j TCPMSS --clamp-mss-to-pmtu
sudo iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -i tap_vpn -j TCPMSS --clamp-mss-to-pmtu
sudo ip link del tap_vpn
```

Удалите (или закомментируйте) записи VPN-сайтов в `traefik/dynamic/vpn-sites.yml`.
Ubuntu-сайты при откате не затрагиваются; файлы `softether/.env`, `softether/data/`,
`softether/logs/` можно удалить, если вариант больше не нужен.

## Дашборд Traefik (опционально)

По умолчанию дашборд выключен. Чтобы включить его **только за BasicAuth**:

1. Сгенерируйте хэш пароля:
   ```bash
   docker run --rm httpd:2.4 htpasswd -nbB admin 'ваш-пароль'
   ```
2. В `traefik/traefik.yml` замените `dashboard: false` на `dashboard: true`
   (в секции `api`).
3. В `docker-compose.yml` добавьте сервису `traefik` метки (в `$` хэша удвойте:
   `$$` — иначе compose интерпретирует их как переменные):
   ```yaml
       labels:
         traefik.enable: "true"
         traefik.http.routers.api.rule: "Host(`traefik.ваш-домен`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))"
         traefik.http.routers.api.service: "api@internal"
         traefik.http.routers.api.middlewares: "auth"
         traefik.http.middlewares.auth.basicauth.users: "admin:$$apr1$$...ваш-хэш..."
   ```
4. Примените: `docker compose up -d`. Дашборд: `https://traefik.ваш-домен/dashboard/`.

Никогда не включайте `api.insecure: true` на сервере с публичным IP.

## Обновление и откат

```bash
# Обновление в рамках линии v3.7 (образ закреплён по минорной версии):
docker compose pull && docker compose up -d

# Применить изменения traefik.yml:
docker compose up -d          # пересоздание контейнера, сертификаты сохраняются в volume

# Временный останов (сертификаты сохраняются):
docker compose down

# Полное удаление (ВНИМАНИЕ: сертификат и ключ аккаунта LE будут удалены):
docker compose down -v
docker network rm proxy
sudo ufw delete allow 80/tcp && sudo ufw delete allow 443/tcp
```

Переход на новую мажорную версию Traefik выполняйте осознанно, по
[миграционному гайду](https://doc.traefik.io/traefik\/migration/).

## Troubleshooting

| Симптом | Причина и решение |
|---|---|
| `install.sh` падает: «port 80/443 is already in use» | Порт занят другим процессом (имя показано). Освободите порт и запустите снова |
| В логах traefik: `unable to solve challenge` / сертификат не выпускается | Неверный `CF_DNS_API_TOKEN` или у токена нет прав `Zone — DNS — Edit` на вашу зону. Исправьте `.env`, затем `docker compose up -d` и повторите `install.sh` |
| `check.sh`: FAIL «acme.json is missing or empty» | Сертификат запрашивается при старте (bootstrap-роутер); проверьте `docker logs traefik` — типовая причина: неверный `CF_DNS_API_TOKEN` |
| Ошибка rate-limit от Let's Encrypt | Упрётесь в лимиты при экспериментах. Поставьте `LE_CA_SERVER` в staging-значение (см. комментарий в `.env.example`), `docker compose up -d`, устраните причину, верните production-значение |
| `check.sh`: WARN «wildcard DNS does not resolve» | Нет записи `A: * → IP` в Cloudflare, либо она ещё не распропагировалась, либо включён оранжевый proxy-режим: нужен DNS only для прямого режима, а при Cloudflare Access WARN ожидаем (см. «Доступ только для своих») |
| Сайт открывается без входа, хотя приложение Access создано | Запись не проксируется (серое облачко): трафик идёт мимо Cloudflare. Включите оранжевое облачко у записи `*` |
| Письмо с кодом One-time PIN не приходит | Адрес не добавлен в Allow-политику приложения (Cloudflare не отправляет письма «чужим» и не сообщает об этом) либо почтовый фильтр режет `noreply@notify.cloudflare.com` — добавьте его в allowlist |
| «This One-Time PIN has already been used» | Код одноразовый и живёт 10 минут; сканеры почты иногда «используют» его первыми. Нажмите **Request new code** |
| Сайт виден всем, хотя политика настроена | В политике Include → **Everyone** или только **Login Methods → One-time PIN** — Access пускает любого. Ограничьте правило списком **Emails** |
| Сайт открывается по `IP:443` напрямую, минуя Access | Закройте 80/443 диапазонами Cloudflare: `sudo ./scripts/install-access-guard.sh` (см. «Чтобы Access не обошли напрямую») |
| После установки защиты сайты недоступны снаружи | Запись `*` не проксируется через Cloudflare — трафик идёт напрямую, и правило его не пропускает. Включите оранжевое облачко; временно снять защиту: `sudo ./scripts/install-access-guard.sh remove` |
| Диапазоны Cloudflare не обновляются | `journalctl -u sitehub-cf-ips-refresh.service`: при ошибке загрузки наборы не меняются, старые диапазоны продолжают работать. Ручной запуск: `sudo systemctl start sitehub-cf-ips-refresh.service` |
| Правило пропало после `systemctl restart docker` | Возвращается автоматически (юнит привязан к `docker.service`); если нет — `sudo systemctl restart sitehub-cf-ips.service` |
| После включения защиты отвалился другой сервис (VPN и т.п.) | Правило ограничивает только опубликованные 80/443 входного контейнера. Проверьте счётчики сработавших правил: `sudo iptables -L DOCKER-USER -v -n`, и что публикует спорный порт: `sudo iptables -t nat -S DOCKER \| grep <порт>`. Если защита ставилась старой версией — просто повторите `sudo ./scripts/install-access-guard.sh`: устаревшее правило удаляется автоматически |
| Сайт отдаёт 401 «missing Cf-Access-Jwt-Assertion header» | Запрос дошёл до Traefik минуя Cloudflare Access. Локальная проверка с `https://localhost/` так и должна отвечать — токена в этом пути нет, это ожидаемо. Если это в браузере через домен: проверьте, что запись проксируется (`dig +short stub.ваш-домен` возвращает адреса Cloudflare, а не IP сервера) и что приложение Access покрывает этот поддомен (Bypass-политика токена не добавляет); публичному сайту метка `cf-access-verify@file` не нужна |
| Сайт открывается сразу, без страницы входа, хотя включена глобальная проверка | Скорее всего жива сессия Access (cookie `CF_Authorization`, срок — Session duration приложения). Откройте сайт в приватном окне — должна появиться страница входа; прервать сессии сразу: Zero Trust → **Team & Resources** → **Users** → **Revoke**. Признак, что защита работает: при заходе в `docker logs cf-access-verify` появляется `allow ... <email>` |
| Сайт отдаёт 403 «invalid Access JWT: ...» | Причина в тексте ответа и в `docker logs cf-access-verify`: `unexpected audience` — в `access/verifier/.env` AUD другого приложения; `unknown signing key` — не тот team domain; `token expired` — сессия истекла, обновите страницу |
| Все сайты отдают 500 после включения проверки Access-JWT | Контейнер `cf-access-verify` не запущен (проверка fail-closed): `docker ps -a`, `docker logs cf-access-verify`; перезапуск: `docker compose -f access/verifier/compose.yaml up -d` |
| `install-access-verify.sh` падает: «could not load the signing keys» | Неверный `TEAM_DOMAIN` в `access/verifier/.env` или сервер не может достучаться до `*.cloudflareaccess.com`; исправьте и повторите |
| Сайт отдаёт 404 | Неизвестный Host: проверьте метку `Host(...)` и что контейнер подключён к сети `proxy` (`docker inspect <контейнер>`) |
| Сайт отдаёт 503 | Контейнер сайта не запущен или не отвечает на указанном в метке порту: `docker ps`, `docker logs <сайт>` |
| Два сайта конфликтуют | Дубль значения `Host(...)` в метках: найдите `docker inspect` обоих и исправьте; конфликт виден в `docker logs traefik` |
| После reboot что-то не поднялось | Не должно случаться: Docker включён на boot, traefik — `restart: unless-stopped`. Проверьте `./scripts/check.sh` и `docker ps -a` |
| Windows-машина offline или VPN отвалился | 503 только на её сайтах — это штатно, Ubuntu-сайты работают. Проверьте питание/сон Windows-машины и автоподключение VPN |
| Сайт на Windows недоступен из VPN | Порт опубликован на `127.0.0.1` — в compose сайта укажите `ports: "8080:80"` (все интерфейсы) |
| Сайт на Windows недоступен из VPN (порт опубликован) | Windows Firewall блокирует входящие: добавьте правило для порта с `-RemoteAddress 10.77.77.1` (см. раздел «Сайты за VPN (SoftEther)») |
| DHCP не выдал адрес VPN-адаптеру | Задайте статический адрес на SoftEther-адаптере: `10.77.77.21`, маска `255.255.255.0`, шлюз и DNS не указывать |
| Крупные файлы через VPN-сайт загружаются медленно или обрываются | MTU/фрагментация в туннеле: `tap_vpn` — 1400, MSS clamp включён; при проблемах уменьшите MTU адаптера на Windows |
| После `systemctl restart docker` VPN-сайты отдают 503 | Правила iptables потеряны: `sudo systemctl restart sitehub-vpn-net.service`; проверка — `sudo ./scripts/check-vpn.sh` |
| `install-vpn.sh` заменил уже работавший SoftEther (свой проект) | Вариант репозитория не совместим с чужой установкой: у неё то же имя compose-проекта и контейнера, поэтому `docker compose up` заменяет контейнер (данные чужого проекта остаются в его каталоге). Уберите вариант репозитория (см. «Откат») и поднимите свой проект: `docker compose up -d` в его каталоге, публикуя SoftEther на свободном порту (`8443:443`, 443 занят Traefik), затем обновите порт в клиентах. Скрипт проверяет пересечение в preflight и останавливается |

## Приёмочный чек-лист

Проверьте после установки (соответствует критериям успеха проекта):

- [ ] Установка на сервере: `sudo ./scripts/install.sh` — traefik healthy, сертификат
      `*.<домен>` выпущен, `curl https://<домен>` отвечает по валидному TLS (404 допустим),
      HTTP редиректит на HTTPS.
- [ ] Идемпотентность: повторный `sudo ./scripts/install.sh` завершается кодом 0 без изменений.
- [ ] Сосуществование: уже работавшие на сервере контейнеры не затронуты; при занятом порте 80
      скрипт падает **до** внесения изменений.
- [ ] Сайт-заглушка: `https://stub.<домен>` открывается с валидным сертификатом ≤ ~1 минуты
      после деплоя, `http://` редиректит.
- [ ] Отказ бэкенда: `docker compose stop` у заглушки → 503; `start` → снова работает.
- [ ] Диагностика: `./scripts/check.sh` — все пункты OK, включая остаток срока сертификата.
- [ ] Перезагрузка: после `sudo reboot` HTTPS и маршрутизация восстанавливаются сами.
