# SiteHub

Входной контейнер для сервера Ubuntu: [Traefik](https://traefik.io/) v3 терминирует HTTPS,
автоматически выпускает и продлевает wildcard-сертификат Let's Encrypt для всех поддоменов
вашего домена и подключает новые сайты-контейнеры **без правок конфигурации и перезапусков**.

```
                 Интернет
                    │
   Cloudflare DNS:  A *.ваш-домен → IP сервера   (одна разовая запись)
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
├── traefik/traefik.yml     # статическая конфигурация Traefik
├── .env.example            # шаблон настроек (секреты — в .env, не в git)
├── scripts/
│   ├── install.sh          # идемпотентная установка на Ubuntu
│   └── check.sh            # диагностика (read-only)
└── examples/stub-site/     # сайт-заглушка для проверки
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
git clone <url-этого-репозитория> SiteHub
cd SiteHub
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
   wildcard-сертификата `*.<ваш-домен>`.

### Разовая DNS-запись

В панели Cloudflare создайте запись (один раз на домен):

| Тип | Имя | Содержимое |
|---|---|---|
| A | `*` | публичный IP сервера |
| A | `@` | публичный IP сервера (опционально, для apex-домена) |

Proxy-статус (оранжевое облачко) — **DNS only** (серое), чтобы трафик шёл напрямую
на сервер. После этого новые поддомены DNS-действий **не требуют**.

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

Что гарантирует Traefik каждому подключённому сайту:

- валидный wildcard-сертификат Let's Encrypt (автопродление, действий не требует);
- редирект всех HTTP-запросов на HTTPS (301/308);
- заголовки `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Host`,
  `X-Forwarded-Port` — приложение должно их учитывать (например, для https-ссылок);
- 503, пока контейнер сайта не запущен, и автоматическое восстановление после запуска.

Ограничения:

- wildcard-сертификат покрывает **один уровень** поддоменов: `site1.ваш-домен` — да,
  `a.b.ваш-домен` — нет;
- значение `Host(...)` должно быть уникальным на сервере (при дубле Traefik логирует
  конфликт, и поведение зависит от порядка обнаружения);
- TLS-метки сайтам не нужны: certresolver и домены заданы по умолчанию на входе.

## Диагностика

```bash
./scripts/check.sh        # сводка OK/WARN/FAIL: traefik, порты, сеть, сертификат, DNS, редирект
docker logs traefik       # логи входного контейнера
docker logs <сайт>        # логи контейнера сайта
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
[миграционному гайду](https://doc.traefik.io/traefik/migration/).

## Troubleshooting

| Симптом | Причина и решение |
|---|---|
| `install.sh` падает: «port 80/443 is already in use» | Порт занят другим процессом (имя показано). Освободите порт и запустите снова |
| В логах traefik: `unable to solve challenge` / сертификат не выпускается | Неверный `CF_DNS_API_TOKEN` или у токена нет прав `Zone — DNS — Edit` на вашу зону. Исправьте `.env`, затем `docker compose up -d` и повторите `install.sh` |
| Ошибка rate-limit от Let's Encrypt | Упрётесь в лимиты при экспериментах. Поставьте `LE_CA_SERVER` в staging-значение (см. комментарий в `.env.example`), `docker compose up -d`, устраните причину, верните production-значение |
| `check.sh`: WARN «wildcard DNS does not resolve» | Нет записи `A: * → IP` в Cloudflare, либо она ещё не распропагировалась, либо включён оранжевый proxy-режим (нужен DNS only) |
| Сайт отдаёт 404 | Неизвестный Host: проверьте метку `Host(...)` и что контейнер подключён к сети `proxy` (`docker inspect <контейнер>`) |
| Сайт отдаёт 503 | Контейнер сайта не запущен или не отвечает на указанном в метке порту: `docker ps`, `docker logs <сайт>` |
| Два сайта конфликтуют | Дубль значения `Host(...)` в метках: найдите `docker inspect` обоих и исправьте; конфликт виден в `docker logs traefik` |
| После reboot что-то не поднялось | Не должно случаться: Docker включён на boot, traefik — `restart: unless-stopped`. Проверьте `./scripts/check.sh` и `docker ps -a` |

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
