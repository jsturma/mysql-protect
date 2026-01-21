#!/bin/bash
# ==============================
# MySQL Environment Detection
# ==============================
# Copyright (c) 2024 mysql-protect
# MIT License - see LICENSE file for details

set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_SOCKET="${MYSQL_SOCKET:-}"

# Dynamically locate mysql binary
MYSQL_BIN=$(which mysql 2>/dev/null || echo "")

if [[ -z "$MYSQL_BIN" ]]; then
  echo "❌ mysql client not found" >&2
  exit 1
fi

# ASSET_USERNAME / ASSET_PASSWORD are optional (when not set, rely on defaults or client config such as ~/.my.cnf).
if [[ -n "${ASSET_USERNAME:-}" ]]; then
  MYSQL_USER="$ASSET_USERNAME"
fi
if [[ -n "${ASSET_PASSWORD:-}" ]]; then
  MYSQL_PASSWORD="$ASSET_PASSWORD"
fi

build_mysql_opts() {
  local -a opts
  opts=(-u"$MYSQL_USER")
  [[ -n "$MYSQL_PASSWORD" ]] && opts+=(-p"$MYSQL_PASSWORD")
  [[ -n "$MYSQL_SOCKET" ]] && opts+=(--socket="$MYSQL_SOCKET")
  [[ -z "$MYSQL_SOCKET" ]] && opts+=(-h"$MYSQL_HOST" -P"$MYSQL_PORT")
  echo "${opts[@]}"
}

run_sql() {
  local sql="$1"
  local -a opts
  # shellcheck disable=SC2207
  opts=($(build_mysql_opts))
  "$MYSQL_BIN" "${opts[@]}" -N -s -e "$sql" 2>/dev/null || echo ""
}

echo "🔍 Detecting MySQL environment..."
echo "--------------------------------------"

VERSION=$(run_sql "SELECT @@version;")
COMMENT=$(run_sql "SELECT @@version_comment;")
HOSTNAME=$(run_sql "SELECT @@hostname;")
DATADIR=$(run_sql "SHOW VARIABLES LIKE 'datadir';" | awk '{print $2}')
PROCESSLIST=$(run_sql "SHOW PROCESSLIST;" 2>/dev/null || echo "")

AZURE=$(run_sql "SHOW VARIABLES LIKE 'azure_%';")
CLOUDSQL=$(run_sql "SHOW VARIABLES LIKE 'cloudsql%';")
GOOGLE=$(run_sql "SHOW VARIABLES LIKE 'google%';")
RDS=$(run_sql "SHOW VARIABLES LIKE 'rds%';")

SUPER=$(run_sql "SHOW GRANTS FOR CURRENT_USER();" | grep -qi super && echo "YES" || echo "NO")

# Detect containerized environment
CONTAINERIZED=0
CONTAINER_TYPE=""
# Check hostname pattern (container IDs are often 12-char hex strings)
if echo "$HOSTNAME" | grep -qE '^[a-f0-9]{12}$'; then
  CONTAINERIZED=1
  CONTAINER_TYPE="Container (Docker/Podman)"
# Check for common container hostname patterns
elif echo "$HOSTNAME" | grep -qiE '^(docker|podman|container|k8s|kubernetes)'; then
  CONTAINERIZED=1
  CONTAINER_TYPE="Container"
# Check if datadir suggests container (common container paths)
elif echo "$DATADIR" | grep -qE '^/var/lib/(mysql|docker|containers)'; then
  # Additional check: if hostname looks like container ID
  if [[ ${#HOSTNAME} -ge 8 && ${#HOSTNAME} -le 16 ]] && echo "$HOSTNAME" | grep -qE '^[a-f0-9]+$'; then
    CONTAINERIZED=1
    CONTAINER_TYPE="Container (Docker/Podman)"
  fi
fi

# Try to detect container runtime by checking if we can query container info
# This is a best-effort detection
if [[ $CONTAINERIZED -eq 0 ]]; then
  # Check if hostname matches typical container patterns
  if [[ ${#HOSTNAME} -ge 8 && ${#HOSTNAME} -le 16 ]] && echo "$HOSTNAME" | grep -qE '^[a-f0-9]+$'; then
    CONTAINERIZED=1
    CONTAINER_TYPE="Container (likely Docker/Podman)"
  fi
fi

echo "Version           : $VERSION"
echo "Version comment   : $COMMENT"
echo "Hostname          : $HOSTNAME"
echo "Datadir           : $DATADIR"
echo "SUPER privilege   : $SUPER"
if [[ $CONTAINERIZED -eq 1 ]]; then
  echo "Containerized     : YES ($CONTAINER_TYPE)"
fi
echo

ENV="UNKNOWN"

if echo "$COMMENT" | grep -qi "amazon rds" || [[ -n "$RDS" ]]; then
  ENV="AWS RDS"
elif [[ -n "$AZURE" ]]; then
  ENV="Azure Database for MySQL (PaaS)"
elif [[ -n "$CLOUDSQL" ]] || [[ -n "$GOOGLE" ]] || echo "$DATADIR" | grep -q "/cloudsql/"; then
  ENV="GCP Cloud SQL (PaaS)"
elif [[ $CONTAINERIZED -eq 1 ]]; then
  # Determine MySQL variant in container
  if echo "$COMMENT" | grep -qi "percona"; then
    ENV="Percona Server (Container: Docker/Podman)"
  elif echo "$COMMENT" | grep -qi "mariadb"; then
    ENV="MariaDB (Container: Docker/Podman)"
  elif echo "$COMMENT" | grep -qi "community"; then
    ENV="MySQL Community (Container: Docker/Podman)"
  else
    ENV="MySQL (Container: Docker/Podman)"
  fi
elif echo "$COMMENT" | grep -qi "percona"; then
  ENV="Percona Server (VM / on-prem)"
elif echo "$COMMENT" | grep -qi "mariadb"; then
  ENV="MariaDB (VM / on-prem)"
elif echo "$COMMENT" | grep -qi "community"; then
  ENV="MySQL Community (VM / on-prem)"
fi

echo "🧠 Detected environment: $ENV"
echo "--------------------------------------"

case "$ENV" in
  *PaaS*)
    echo "⚠️  Expected restrictions:"
    echo "   - No SUPER privilege"
    echo "   - No streaming binlog (--stop-never)"
    echo "   - No FTWRL (FLUSH TABLES WITH READ LOCK)"
    echo "   - Native PITR recommended"
    ;;
  *Container*)
    echo "📦 Containerized environment detected:"
    echo "   - Full MySQL control available"
    echo "   - Streaming binlog OK"
    echo "   - Filesystem access limited to container"
    echo "   - Binlog files may need remote access (--read-from-remote-server)"
    echo "   - Consider volume mounts for persistent data"
    ;;
  *)
    echo "✅ Environment with full control possible"
    echo "   - Streaming binlog OK"
    echo "   - Filesystem access possible"
    ;;
esac

echo
echo "✅ Detection completed"

exit 0
