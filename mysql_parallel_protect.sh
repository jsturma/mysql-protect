#!/bin/bash
set -euo pipefail

########################################
# MySQL Backup Script
# Copyright (c) 2024 mysql-protect
# MIT License - see LICENSE file for details
# 
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
  echo "Usage: $0 [-h host] [-P port] [-u user] [-p password] [-s socket] [-d backup_dir] [-j jobs] [-D database1,database2,...]"
  echo "  -D: Specify one or more databases to backup (comma-separated). If not specified, all databases are backed up."
  exit 1
}

MAX_JOBS=1
SPECIFIED_DBS=()
while getopts "h:P:u:p:s:d:j:D:" opt; do
  case $opt in
    h) MYSQL_HOST="$OPTARG" ;;
    P) MYSQL_PORT="$OPTARG" ;;
    u) MYSQL_USER="$OPTARG" ;;
    p) MYSQL_PASSWORD="$OPTARG" ;;
    s) MYSQL_SOCKET="$OPTARG" ;;
    d) BACKUP_DIR="$OPTARG" ;;
    j) MAX_JOBS="$OPTARG" ;;
    D) IFS=',' read -ra DB_ARRAY <<< "$OPTARG"
       SPECIFIED_DBS+=("${DB_ARRAY[@]}")
       ;;
    *) usage ;;
  esac
done

########################################
# PREPARATION
########################################

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
  echo "[$timestamp] [$level] $message"
}

on_error() {
  log "ERROR" "Backup failed"
  exit 1
}

trap on_error ERR

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

# Backup with optional parallelization
if [[ "$MAX_JOBS" -gt 1 ]] && command -v xargs &>/dev/null; then
  log "INFO" "Backing up ${#VALID_DBS[@]} databases (parallelization: $MAX_JOBS jobs)"
  export -f backup_database log
  export MYSQLDUMP_BIN BACKUP_DIR DATE COMPRESS MYSQL_USER MYSQL_PASSWORD MYSQL_SOCKET MYSQL_HOST MYSQL_PORT
  if ! printf '%s\0' "${VALID_DBS[@]}" | xargs -0 -n1 -P"$MAX_JOBS" bash -c 'backup_database "$1"' _; then
    log "ERROR" "One or more database backups failed"
    exit 1
  fi
else
  log "INFO" "Backing up ${#VALID_DBS[@]} databases"
  for db in "${VALID_DBS[@]}"; do
    backup_database "$db"
  done
fi

########################################
# BINLOG AND MYSQL LOGS BACKUP
########################################

log "INFO" "Retrieving MySQL variables"
# Combine all SHOW VARIABLES queries into one
VARS_OPTS=($(build_mysql_opts))
MYSQL_VARS=$("$MYSQL_BIN" "${VARS_OPTS[@]}" -N -e "
  SELECT CONCAT(VARIABLE_NAME, '=', VARIABLE_VALUE)
  FROM information_schema.GLOBAL_VARIABLES
  WHERE VARIABLE_NAME IN ('log_bin_basename', 'log_error', 'slow_query_log_file', 'general_log_file')
  AND VARIABLE_VALUE IS NOT NULL AND VARIABLE_VALUE != '';
" 2>/dev/null || "$MYSQL_BIN" "${VARS_OPTS[@]}" -N -e "
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
