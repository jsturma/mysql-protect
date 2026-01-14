#!/bin/bash
set -euo pipefail

########################################
# MySQL Backup Script - Dell PPDM Compatible
# Copyright (c) 2024 mysql-protect
# MIT License - see LICENSE file for details
# 
# PPDM Compatible: Sequential backups only, no parallel processing
# Size constraint: Script must stay under 20KB
########################################

########################################
# DEFAULT CONFIGURATION
########################################

MYSQL_HOST="localhost"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASSWORD=""            # recommended: .my.cnf
MYSQL_SOCKET=""

BACKUP_DIR="/var/backups/mysql"
DATE="$(date +%F_%H-%M-%S)"

COMPRESS="no"
# Using associative array for O(1) lookup instead of O(n)
declare -A EXCLUDE_DBS=(
  ["information_schema"]=1
  ["performance_schema"]=1
  ["mysql"]=1
  ["sys"]=1
)

MYSQL_BIN="/usr/bin/mysql"
MYSQLDUMP_BIN="/usr/bin/mysqldump"

########################################
# CLI OPTIONS
########################################

usage() {
  echo "Usage: $0 [-h host] [-P port] [-u user] [-p password] [-s socket] [-d backup_dir] [-D database1,database2,...] [-j jobs] [-f]"
  echo "  -D: Specify one or more databases to backup (comma-separated). If not specified, all databases are backed up."
  echo "  -j: Requested parallel jobs for database dumps (requires -f to enable)."
  echo "  -f: Force parallel database dumps when -j is greater than 1."
  exit 1
}

CLI_USER_SET=0
CLI_PASS_SET=0
CLI_DIR_SET=0

MAX_JOBS=1
FORCE_PARALLEL=0

SPECIFIED_DBS=()
while getopts "h:P:u:p:s:d:D:j:f" opt; do
  case $opt in
    h) MYSQL_HOST="$OPTARG" ;;
    P) MYSQL_PORT="$OPTARG" ;;
    u) MYSQL_USER="$OPTARG"; CLI_USER_SET=1 ;;
    p) MYSQL_PASSWORD="$OPTARG"; CLI_PASS_SET=1 ;;
    s) MYSQL_SOCKET="$OPTARG" ;;
    d) BACKUP_DIR="$OPTARG"; CLI_DIR_SET=1 ;;
    D) IFS=',' read -ra DB_ARRAY <<< "$OPTARG"
       SPECIFIED_DBS+=("${DB_ARRAY[@]}")
       ;;
    j) MAX_JOBS="$OPTARG" ;;
    f) FORCE_PARALLEL=1 ;;
    *) usage ;;
  esac
done

########################################
# PREPARATION
########################################

if [[ $CLI_USER_SET -eq 0 && -n "${ASSET_USERNAME:-}" ]]; then
  MYSQL_USER="$ASSET_USERNAME"
fi
if [[ $CLI_PASS_SET -eq 0 && -n "${ASSET_PASSWORD:-}" ]]; then
  MYSQL_PASSWORD="$ASSET_PASSWORD"
fi

if [[ -n "${DD_TARGET_DIRECTORY:-}" ]]; then
  if [[ $CLI_DIR_SET -eq 1 ]]; then
    # PPDM provides a unique target directory per backup job; prefer it when present.
    BACKUP_DIR="$DD_TARGET_DIRECTORY"
  else
    BACKUP_DIR="$DD_TARGET_DIRECTORY"
  fi
fi

mkdir -p "$BACKUP_DIR"/logs

build_mysql_opts() {
  local -a opts
  opts=(-u"$MYSQL_USER")
  [[ -n "$MYSQL_PASSWORD" ]] && opts+=(-p"$MYSQL_PASSWORD")
  [[ -n "$MYSQL_SOCKET" ]] && opts+=(--socket="$MYSQL_SOCKET")
  [[ -z "$MYSQL_SOCKET" ]] && opts+=(-h"$MYSQL_HOST" -P"$MYSQL_PORT")
  echo "${opts[@]}"
}

########################################
# FUNCTIONS
########################################

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "${TRACE_ID:-}" ]]; then
    echo "[$timestamp] [$level] [${TRACE_ID}] $message"
  else
    echo "[$timestamp] [$level] $message"
  fi
}

on_error() {
  log "ERROR" "Backup failed"
  write_backup_response "ERROR" "Backup failed"
  exit 1
}

trap on_error ERR

write_backup_response() {
  # If BACKUP_RESPONSE_FILEPATH is provided by PPDM, write JSON response.
  # ddBackupPath must contain folder paths (not file paths).
  local status="$1" # OK or ERROR
  local msg="${2:-}"
  local out="${BACKUP_RESPONSE_FILEPATH:-}"
  [[ -z "$out" ]] && return 0

  # Build JSON array from DD_BACKUP_PATHS.
  local json_paths=""
  local p
  for p in "${DD_BACKUP_PATHS[@]:-}"; do
    # Minimal escaping for quotes/backslashes.
    p=${p//\\/\\\\}
    p=${p//\"/\\\"}
    if [[ -n "$json_paths" ]]; then
      json_paths+=", "
    fi
    json_paths+="\"$p\""
  done

  if [[ "$status" == "OK" ]]; then
    printf '{\n  "ddBackupPath": [%s]\n}\n' "$json_paths" > "$out" 2>/dev/null || true
  else
    msg=${msg//\\/\\\\}
    msg=${msg//\"/\\\"}
    printf '{\n  "ddBackupPath": [%s],\n  "error": {\n    "errorMessage": "%s"\n  }\n}\n' "$json_paths" "$msg" > "$out" 2>/dev/null || true
  fi
}

is_excluded() {
  [[ -n "${EXCLUDE_DBS[$1]:-}" ]]
}

backup_database() {
  local db="$1"
  local db_dir="$BACKUP_DIR/dumps/$db"
  mkdir -p "$db_dir"
  local out="$db_dir/${db}_${DATE}.sql"
  local -a opts
  # shellcheck disable=SC2207
  opts=($(build_mysql_opts))
  
  if "$MYSQLDUMP_BIN" \
    "${opts[@]}" \
    --single-transaction \
    --routines \
    --events \
    --triggers \
    --databases "$db" > "$out" 2>/dev/null; then
    if [[ "$COMPRESS" == "yes" ]]; then
      gzip "$out"
      log "OK" "$db backed up and compressed"
    else
      log "OK" "$db backed up"
    fi
    return 0
  else
    log "ERROR" "Error backing up $db"
    [[ -f "$out" ]] && rm -f "$out"
    return 1
  fi
}

########################################
# DATABASE LIST
########################################

# If specific databases are specified, use them; otherwise discover all databases
if [[ ${#SPECIFIED_DBS[@]} -gt 0 ]]; then
  log "INFO" "Using specified databases: ${SPECIFIED_DBS[*]}"
  # Validate that specified databases exist
  log "INFO" "Validating specified databases"
  ALL_DBS=()
  # shellcheck disable=SC2207
  ALL_OPTS=($(build_mysql_opts))
  while IFS= read -r db; do
    [[ -n "$db" ]] && ALL_DBS+=("$db")
  done < <("$MYSQL_BIN" "${ALL_OPTS[@]}" -N -e "SHOW DATABASES;" 2>/dev/null || { log "ERROR" "Unable to connect to MySQL" >&2; exit 1; })
  
  # Check if specified databases exist
  declare -A DB_MAP
  for db in "${ALL_DBS[@]}"; do
    DB_MAP["$db"]=1
  done
  
  VALID_DBS=()
  for db in "${SPECIFIED_DBS[@]}"; do
    if [[ -n "${DB_MAP[$db]:-}" ]]; then
      VALID_DBS+=("$db")
    else
      log "ERROR" "Database '$db' does not exist, skipping"
    fi
  done
  
  if [[ ${#VALID_DBS[@]} -eq 0 ]]; then
    log "ERROR" "No valid databases to backup"
    exit 1
  fi
else
  log "INFO" "Discovering MySQL databases"
  DATABASES=()
  # shellcheck disable=SC2207
  DISC_OPTS=($(build_mysql_opts))
  while IFS= read -r db; do
    [[ -n "$db" ]] && DATABASES+=("$db")
  done < <("$MYSQL_BIN" "${DISC_OPTS[@]}" -N -e "SHOW DATABASES;" 2>/dev/null || { log "ERROR" "Unable to connect to MySQL" >&2; exit 1; })
  
  # Filter excluded databases
  VALID_DBS=()
  for db in "${DATABASES[@]}"; do
    if is_excluded "$db"; then
      log "SKIP" "Excluding database $db"
    else
      VALID_DBS+=("$db")
    fi
  done
fi

# PPDM guideline: handle unsupported backup levels gracefully with a clear message.
if [[ -n "${BACKUP_LEVEL:-}" ]]; then
  LEVEL_UPPER=$(echo "$BACKUP_LEVEL" | tr '[:lower:]' '[:upper:]')
  if [[ "$LEVEL_UPPER" != "FULL" ]]; then
    log "ERROR" "Backup level must be full. Exiting"
    DD_BACKUP_PATHS=()
    write_backup_response "ERROR" "Backup level must be full"
    exit 1
  fi
fi

# Track backup directories for PPDM response output (folder paths only).
DD_BACKUP_PATHS=()
for db in "${VALID_DBS[@]}"; do
  DD_BACKUP_PATHS+=("$BACKUP_DIR/dumps/$db")
done

# Optional parallelism (disabled unless forced).
PARALLEL_ENABLED=0
if [[ "$MAX_JOBS" -gt 1 && "$FORCE_PARALLEL" -eq 1 ]] && command -v xargs >/dev/null 2>&1; then
  PARALLEL_ENABLED=1
  if [[ -n "${DD_TARGET_DIRECTORY:-}" ]]; then
    log "INFO" "Force parallel enabled for dumps in DD_TARGET_DIRECTORY"
  else
    log "INFO" "Force parallel enabled for dumps"
  fi
elif [[ "$MAX_JOBS" -gt 1 && "$FORCE_PARALLEL" -eq 0 ]]; then
  log "INFO" "Parallel requested but not enabled (use -f to force)"
fi

# Sequential backup (PPDM compatible - no parallel processing)
FAILED=0
if [[ "$PARALLEL_ENABLED" -eq 1 ]]; then
  log "INFO" "Backing up ${#VALID_DBS[@]} databases with xargs (${MAX_JOBS} jobs)"
  export -f backup_database log build_mysql_opts
  export MYSQLDUMP_BIN BACKUP_DIR DATE COMPRESS MYSQL_USER MYSQL_PASSWORD MYSQL_SOCKET MYSQL_HOST MYSQL_PORT
  if ! printf '%s\0' "${VALID_DBS[@]}" | xargs -0 -n1 -P"$MAX_JOBS" bash -c 'backup_database "$1"' _; then
    FAILED=1
  fi
else
  log "INFO" "Backing up ${#VALID_DBS[@]} databases sequentially"
  for db in "${VALID_DBS[@]}"; do
    if ! backup_database "$db"; then
      FAILED=1
    fi
  done
fi
if [[ $FAILED -ne 0 ]]; then
  write_backup_response "ERROR" "Backup failed"
  exit 1
fi
write_backup_response "OK"

########################################
# BINLOG AND MYSQL LOGS BACKUP
########################################

log "INFO" "Retrieving MySQL variables"
# Combine all SHOW VARIABLES queries into one
MYSQL_VARS=$("$MYSQL_BIN" "${MYSQL_OPTS[@]}" -N -e "
  SELECT CONCAT(VARIABLE_NAME, '=', VARIABLE_VALUE)
  FROM information_schema.GLOBAL_VARIABLES
  WHERE VARIABLE_NAME IN ('log_bin_basename', 'log_error', 'slow_query_log_file', 'general_log_file')
  AND VARIABLE_VALUE IS NOT NULL AND VARIABLE_VALUE != '';
" 2>/dev/null || "$MYSQL_BIN" "${MYSQL_OPTS[@]}" -N -e "
  SHOW VARIABLES WHERE Variable_name IN ('log_bin_basename', 'log_error', 'slow_query_log_file', 'general_log_file');
" 2>/dev/null | awk '{print $1"="substr($0, index($0,$2))}')

# Parse variables
declare -A VAR_MAP
while IFS='=' read -r key value; do
  [[ -n "$key" && -n "$value" ]] && VAR_MAP["$key"]="$value"
done <<< "$MYSQL_VARS"

# Backup binlogs
log "INFO" "Backing up binlogs"
if [[ -n "${VAR_MAP[log_bin_basename]:-}" ]]; then
  BINLOG_PATH=$(dirname "${VAR_MAP[log_bin_basename]}")
  if [[ -d "$BINLOG_PATH" ]]; then
    cp -a "$BINLOG_PATH" "$BACKUP_DIR/logs/binlogs_${DATE}" 2>/dev/null && \
      log "OK" "Binlogs backed up" || \
      log "ERROR" "Unable to copy binlogs"
  fi
else
  log "SKIP" "Binlogs disabled"
fi

# Backup MySQL logs
log "INFO" "Backing up MySQL logs"
LOG_VARS=("log_error" "slow_query_log_file" "general_log_file")
BACKED_UP=0
for var in "${LOG_VARS[@]}"; do
  LOG_FILE="${VAR_MAP[$var]:-}"
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    if cp "$LOG_FILE" "$BACKUP_DIR/logs/$(basename "$LOG_FILE")_${DATE}" 2>/dev/null; then
      ((BACKED_UP++))
    fi
  fi
done
[[ $BACKED_UP -gt 0 ]] && log "OK" "$BACKED_UP log(s) backed up"

########################################
# END
########################################

log "OK" "MySQL backup completed: $BACKUP_DIR"

exit 0
