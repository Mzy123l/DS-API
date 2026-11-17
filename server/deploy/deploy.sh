#!/usr/bin/env bash
# 在服务器上构建并（重新）启动中转服务容器。
# 用法：bash ~/ds-relay/deploy/deploy.sh
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/ds-relay}"
IMAGE="${IMAGE:-ds-relay:latest}"
CONTAINER="${CONTAINER:-ds-relay}"
# 对外端口：默认 51888 走 HTTPS
PORT_PRIMARY="${PORT_PRIMARY:-51888}"
UPSTREAM_BASE="${UPSTREAM_BASE:-https://api.deepseek.com}"
# 自签名证书里的 IP（SAN）与证书目录；部署时用 PUBLIC_IP=<你的公网IP> 指定
PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"
TLS_DIR="${TLS_DIR:-$APP_DIR/tls}"
# 访问口令：首次部署随机生成；服务器只保存哈希，明文只打印一次给客户端用
TOKEN_HASH_FILE="${TOKEN_HASH_FILE:-$APP_DIR/.relay_token_hash}"

cd "$APP_DIR"
mkdir -p "$APP_DIR/data"
if [ ! -s "$TOKEN_HASH_FILE" ]; then
  RELAY_TOKEN_PLAIN="$(head -c 24 /dev/urandom | base64 | tr -d '\n=+/')"
  printf '%s' "$RELAY_TOKEN_PLAIN" | sha256sum | cut -d' ' -f1 > "$TOKEN_HASH_FILE"
  chmod 600 "$TOKEN_HASH_FILE"
  echo "服务端已保存口令哈希：$TOKEN_HASH_FILE"
  echo "口令（只显示这一次，请填到 App 的服务器口令里）：$RELAY_TOKEN_PLAIN"
fi
RELAY_TOKEN_HASH="$(tr -d '[:space:]' < "$TOKEN_HASH_FILE")"
# 口令是硬性要求：哈希文件为空/损坏就停在这里，不要起一个无口令的容器
if [ "${#RELAY_TOKEN_HASH}" -ne 64 ]; then
  echo "口令哈希无效（$TOKEN_HASH_FILE 应为 64 位十六进制）：$RELAY_TOKEN_HASH" >&2
  echo "删除该文件后重跑本脚本可生成新口令，或按 README 自行写入哈希。" >&2
  exit 1
fi

# 自签名证书：首次部署生成（客户端按指纹校验，无需域名）
mkdir -p "$TLS_DIR"
if [ ! -s "$TLS_DIR/relay.crt" ] || [ ! -s "$TLS_DIR/relay.key" ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$TLS_DIR/relay.key" -out "$TLS_DIR/relay.crt" \
    -days 3650 -nodes -subj "/CN=ds-relay" \
    -addext "subjectAltName=IP:${PUBLIC_IP},IP:127.0.0.1,DNS:localhost" \
    >/dev/null 2>&1
  chmod 600 "$TLS_DIR/relay.key"
  echo "已生成自签名证书：$TLS_DIR/relay.crt"
fi
CERT_FP="$(openssl x509 -in "$TLS_DIR/relay.crt" -noout -fingerprint -sha256 \
  | sed 's/.*=//' | tr -d ':' | tr 'A-F' 'a-f')"
echo "证书 SHA-256 指纹（填到 App 的服务器证书指纹）：$CERT_FP"

docker build -t "$IMAGE" .
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  -p "${PORT_PRIMARY}:51888" \
  -v "${APP_DIR}/data:/srv/data" \
  -v "${TLS_DIR}:/srv/tls:ro" \
  -e "UPSTREAM_BASE=${UPSTREAM_BASE}" \
  -e "RELAY_TOKEN_HASH=${RELAY_TOKEN_HASH}" \
  -e RELAY_PORT=51888 \
  -e RELAY_DB=/srv/data/relay.db \
  -e TLS_CERT=/srv/tls/relay.crt \
  -e TLS_KEY=/srv/tls/relay.key \
  "$IMAGE"

sleep 1
docker ps --filter "name=${CONTAINER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo -n "healthz: "
curl -sS --cacert "$TLS_DIR/relay.crt" \
  "https://localhost:${PORT_PRIMARY}/healthz" || true
echo
