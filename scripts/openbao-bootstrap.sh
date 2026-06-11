#!/usr/bin/env bash
# Idempotent OpenBao provisioning for the openbao-secrets-guide examples.
# Sets up: KV v2 engine, static secrets, a read-only ACL policy, AppRole auth,
# and (optionally) the database secrets engine for dynamic credentials.
# Re-runnable: every step tolerates "already exists" but fails loudly on real errors.
#
# Usage (against a local dev-mode OpenBao on :8200):
#   JWT_SECRET=$(openssl rand -hex 32) ./scripts/openbao-bootstrap.sh
#
# Optional dynamic-DB setup (needs a reachable MySQL/Postgres):
#   ENABLE_DB=1 DB_HOST=127.0.0.1 DB_PORT=3306 DB_NAME=myapp \
#   MGMT_USER=root MGMT_PASS=secret JWT_SECRET=$(openssl rand -hex 32) \
#   ./scripts/openbao-bootstrap.sh
set -euo pipefail

export BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
export BAO_TOKEN="${BAO_TOKEN:-dev-root-token}"

# If the OpenBao CLI ("bao") isn't on your PATH, run it inside the container.
# Override the container name with OPENBAO_CONTAINER, or set USE_DOCKER=0 if bao is local.
USE_DOCKER="${USE_DOCKER:-1}"
OPENBAO_CONTAINER="${OPENBAO_CONTAINER:-openbao}"

if [ "$USE_DOCKER" = "1" ]; then
  bao() { docker exec -i -e BAO_ADDR="http://127.0.0.1:8200" -e BAO_TOKEN="$BAO_TOKEN" "$OPENBAO_CONTAINER" bao "$@"; }
fi

# Enable an engine/auth method idempotently: ok if newly enabled OR already enabled,
# but exit on any OTHER failure (command-not-found, connection refused, etc.).
enable_if_needed() {
  local out
  if out=$(bao "$@" 2>&1); then
    echo "   enabled"
  elif echo "$out" | grep -qiE "already in use|already enabled|path is already"; then
    echo "   (already enabled)"
  else
    echo "   FAILED: $out" >&2
    exit 1
  fi
}

echo "==> Waiting for OpenBao to respond at $BAO_ADDR ..."
for i in $(seq 1 15); do
  if bao status >/dev/null 2>&1; then echo "   ready"; break; fi
  [ "$i" -eq 15 ] && { echo "   FAILED: OpenBao not reachable." >&2; exit 1; }
  sleep 1
done

echo "==> KV v2 engine at myapp/"
enable_if_needed secrets enable -path=myapp -version=2 kv

echo "==> Seed static secrets"
bao kv put myapp/jwt  "jwt_secret=${JWT_SECRET:?set JWT_SECRET (e.g. \$(openssl rand -hex 32))}"
bao kv put myapp/smtp "smtp_user=${SMTP_USER:-mailer}" "smtp_pass=${SMTP_PASS:-change-me}"

echo "==> ACL policy (least-privilege, read-only)"
bao policy write myapp-app - <<'EOF'
path "myapp/data/jwt"             { capabilities = ["read"] }
path "myapp/data/smtp"            { capabilities = ["read"] }
path "database/creds/myapp-role"  { capabilities = ["read"] }
path "sys/leases/renew"           { capabilities = ["update"] }
path "auth/token/renew-self"      { capabilities = ["update"] }
EOF

echo "==> AppRole auth"
enable_if_needed auth enable approle
bao write auth/approle/role/myapp \
  token_policies="myapp-app" \
  token_ttl=1h token_max_ttl=4h \
  secret_id_ttl=0

# --- Optional: dynamic database credentials ---
if [ "${ENABLE_DB:-0}" = "1" ]; then
  DB_HOST="${DB_HOST:-127.0.0.1}"; DB_PORT="${DB_PORT:-3306}"; DB_NAME="${DB_NAME:-myapp}"
  MGMT_USER="${MGMT_USER:?set MGMT_USER}"; MGMT_PASS="${MGMT_PASS:?set MGMT_PASS}"

  echo "==> Database secrets engine"
  enable_if_needed secrets enable database

  echo "==> DB connection (OpenBao's own privileged management account)"
  bao write database/config/myapp \
    plugin_name=mysql-database-plugin \
    connection_url="{{username}}:{{password}}@tcp(${DB_HOST}:${DB_PORT})/" \
    allowed_roles="myapp-role" \
    username="$MGMT_USER" password="$MGMT_PASS"

  echo "==> Dynamic role (short-lived, DML only)"
  bao write database/roles/myapp-role \
    db_name=myapp \
    creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT,INSERT,UPDATE,DELETE ON \`${DB_NAME}\`.* TO '{{name}}'@'%';" \
    revocation_statements="DROP USER '{{name}}'@'%';" \
    default_ttl="1h" max_ttl="24h"
fi

echo "==> role-id / secret-id (secret zero — feed these to your app):"
bao read   auth/approle/role/myapp/role-id
bao write -f auth/approle/role/myapp/secret-id

echo "Bootstrap complete."
