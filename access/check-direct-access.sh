#!/usr/bin/env bash
set -u
HOST="${1:?usage: $0 <поддомен> <IP-сервера>}"
IP="${2:?usage: $0 <поддомен> <IP-сервера>}"

echo "== 0. куда резолвится домен (должны быть адреса Cloudflare, не IP сервера) =="
command -v dig >/dev/null 2>&1 && dig +short "$HOST" | head -3 || echo "(dig не установлен — шаг можно пропустить)"

echo "== 1. прямо на IP с нужным Host: должно НЕ пустить =="
code="$(curl -ks -o /dev/null --connect-timeout 5 -m 8 -w '%{http_code}' \
  --resolve "${HOST}:443:${IP}" "https://${HOST}/" || true)"
if [ "$code" = "000" ]; then
  echo "OK: ${IP}:443 не ответил (таймаут) — прямой обход закрыт"
else
  echo "FAIL: прямой запрос ответил HTTP ${code} — защита не работает или IP не тот"
fi

echo "== 2. через Cloudflare: должно пустить до Access/сайта =="
curl -ks -o /dev/null -m 10 -w 'HTTP %{http_code} -> %{redirect_url}\n' "https://${HOST}/"