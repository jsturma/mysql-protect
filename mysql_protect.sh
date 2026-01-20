#!/bin/bash
set -euo pipefail
########################################
# MySQL Backup Script
# Copyright (c) 2024 mysql-protect
# MIT License - see LICENSE file for details
# 
# Sequential by default; optional forced parallel dumps available
# Size constraint: Script must stay under 20KB
########################################

########################################
# DEFAULT CONFIGURATION
########################################

# Default configuration - can be overridden by environment variables
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"  # Use 127.0.0.1 instead of localhost to force TCP/IP connection
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"            # recommended: .my.cnf
MYSQL_SOCKET="${MYSQL_SOCKET:-}"

BACKUP_DIR="${BACKUP_DIR:-}"
DATE="$(date +%F_%H-%M-%S)"

COMPRESS="${COMPRESS:-no}"

# Dynamically locate mysql, mysqldump, and mysqlbinlog binaries
MYSQL_BIN=$(which mysql 2>/dev/null || echo "")
MYSQLDUMP_BIN=$(which mysqldump 2>/dev/null || echo "")
MYSQLBINLOG_BIN=$(which mysqlbinlog 2>/dev/null || echo "")

if [[ -z "$MYSQL_BIN" ]]; then
  echo "Error: mysql binary not found in PATH" >&2
  exit 1
fi
if [[ -z "$MYSQLDUMP_BIN" ]]; then
  echo "Error: mysqldump binary not found in PATH" >&2
  exit 1
fi
if [[ -z "$MYSQLBINLOG_BIN" ]]; then
  echo "Error: mysqlbinlog binary not found in PATH" >&2
  exit 1
fi

########################################
# CLI OPTIONS
########################################

usage() {
  echo "Usage: $0 [-h host] [-P port] [-s socket] [-D database1,database2,...] [-j jobs] [-f]"
  echo "  -D: Specify one or more databases to backup (comma-separated). If not specified, all databases are backed up."
  echo "  -j: Requested parallel jobs for database dumps (requires -f to enable)."
  echo "  -f: Force parallel database dumps when -j is greater than 1."
  exit 1
}

MAX_JOBS=1
FORCE_PARALLEL=0

SPECIFIED_DBS=()
while getopts "h:P:s:D:j:f" opt; do
  case $opt in
    h) MYSQL_HOST="$OPTARG" ;;
    P) MYSQL_PORT="$OPTARG" ;;
    s) MYSQL_SOCKET="$OPTARG" ;;
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

# Log configuration
# Write logs to /var/log for easier debugging, then copy into "$BACKUP_DIR/backuplogs" on exit.
# Each run creates a new log file.
LOG_DIR="/var/log/mysql_protect"
MAX_LOGS=${MAX_LOGS:-10}

# Ensure log directory exists and is writable, fallback to user-writable location
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
  # Fallback to current directory
  LOG_DIR="./mysql_protect/logs"
  mkdir -p "$LOG_DIR" || {
    # Last resort: use TMPDIR
    LOG_DIR="${TMPDIR:-/tmp}/mysql_protect_logs"
    mkdir -p "$LOG_DIR" || die "Cannot create log directory: $LOG_DIR"
  }
fi

RUN_TS=$(date '+%Y%m%d_%H%M%S')
RUN_ID="${RUN_TS}_$$"
if [[ -n "${TRACE_ID:-}" ]]; then
  TRACE_SAFE=$(echo "$TRACE_ID" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
  [[ -n "$TRACE_SAFE" ]] && RUN_ID="${RUN_ID}_${TRACE_SAFE}"
fi
LOG_BASENAME="mysql_protect_${RUN_ID}.log"
LOG_PATH="${LOG_DIR}/${LOG_BASENAME}"

# Create a new log file for this run (do not append to an existing one)
: > "$LOG_PATH" || die "Cannot create log file: $LOG_PATH"

# Keep only the most recent MAX_LOGS run logs, delete older ones
LOG_INDEX=0
while IFS= read -r f; do
  LOG_INDEX=$((LOG_INDEX + 1))
  if [[ "$LOG_INDEX" -gt "$MAX_LOGS" ]]; then
    rm -f "$f" 2>/dev/null || true
  fi
done < <(ls -1t "$LOG_DIR"/mysql_protect_*.log 2>/dev/null || true)

# Debug tracing:
# - Enable with env DEBUG=1 (or DEBUG=yes), or create /var/log/mysql_protect/.debug
DEBUG_ENABLED=0
if [[ "${DEBUG:-}" == "1" || "${DEBUG:-}" == "yes" || -f "$LOG_DIR/.debug" ]]; then
  DEBUG_ENABLED=1
fi

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  if [[ -n "${TRACE_ID:-}" ]]; then
    echo "[$timestamp] [$level] [${TRACE_ID}] $message" | tee -a "$LOG_PATH" >/dev/null
  else
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_PATH" >/dev/null
  fi
}

die() {
  local msg="$*"
  log "ERROR" "$msg"
  echo "$msg" >&2
  exit 1
}

# ASSET_USERNAME / ASSET_PASSWORD are optional (when not set, rely on defaults or client config such as ~/.my.cnf).
if [[ -n "${ASSET_USERNAME:-}" ]]; then
  MYSQL_USER="$ASSET_USERNAME"
fi
if [[ -n "${ASSET_PASSWORD:-}" ]]; then
  MYSQL_PASSWORD="$ASSET_PASSWORD"
fi

LOCAL_DIR="${LOCAL_DIRECTORY:-}"
DD_DIR="${DD_TARGET_DIRECTORY:-}"
WARN_BOTH_DIRS=0

if [[ -n "$DD_DIR" && -n "$LOCAL_DIR" ]]; then
  WARN_BOTH_DIRS=1
  TARGET_DIR="$DD_DIR"
elif [[ -n "$DD_DIR" ]]; then
  TARGET_DIR="$DD_DIR"
elif [[ -n "$LOCAL_DIR" ]]; then
  TARGET_DIR="$LOCAL_DIR"
else
  # DD_TARGET_DIRECTORY is expected to be exported by the job runner. If missing, fail fast.
  die "DD_TARGET_DIRECTORY is not set (LOCAL_DIRECTORY is also not set)"
fi

# The job runner provides a unique target directory per backup job; always use it.
BACKUP_DIR="$TARGET_DIR"

mkdir -p "$BACKUP_DIR"/mysqllogs

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

# Run MySQL commands without leaking credentials when debug tracing is enabled.
run_mysql() {
  local -a opts
  # shellcheck disable=SC2207
  opts=($(build_mysql_opts))
  local had_xtrace=0
  case $- in *x*) had_xtrace=1 ;; esac
  [[ $had_xtrace -eq 1 ]] && set +x
  "$MYSQL_BIN" "${opts[@]}" "$@"
  local rc=$?
  [[ $had_xtrace -eq 1 ]] && set -x
  return $rc
}

run_mysqldump() {
  local -a opts
  # shellcheck disable=SC2207
  opts=($(build_mysql_opts))
  local had_xtrace=0
  case $- in *x*) had_xtrace=1 ;; esac
  [[ $had_xtrace -eq 1 ]] && set +x
  "$MYSQLDUMP_BIN" "${opts[@]}" "$@"
  local rc=$?
  [[ $had_xtrace -eq 1 ]] && set -x
  return $rc
}

run_mysqlbinlog() {
  local -a opts
  # shellcheck disable=SC2207
  opts=($(build_mysql_opts))
  local had_xtrace=0
  case $- in *x*) had_xtrace=1 ;; esac
  [[ $had_xtrace -eq 1 ]] && set +x
  "$MYSQLBINLOG_BIN" "${opts[@]}" "$@"
  local rc=$?
  [[ $had_xtrace -eq 1 ]] && set -x
  return $rc
}

STAGE="init"

on_error() {
  local rc="${1:-1}"
  local line="${2:-0}"
  local cmd="${3:-unknown}"
  local func="${4:-main}"
  log "ERROR" "Failure rc=$rc stage=$STAGE func=$func line=$line"
  log "ERROR" "Last command: $cmd"
  exit 1
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[0]:-main}"' ERR

copy_logs_to_backup_dir() {
  local dest="$BACKUP_DIR/backuplogs"
  mkdir -p "$dest" 2>/dev/null || true
  if [[ -f "$LOG_PATH" ]]; then
    cp -p "$LOG_PATH" "$dest/" 2>/dev/null || true
  fi
}

trap copy_logs_to_backup_dir EXIT

log "INFO" "Script started"
log "INFO" "Backup target: $BACKUP_DIR"
if [[ "${WARN_BOTH_DIRS:-0}" -eq 1 ]]; then
  log "WARN" "Both DD_TARGET_DIRECTORY and Local_Directory are set; using DD_TARGET_DIRECTORY"
fi
if [[ $DEBUG_ENABLED -eq 1 ]]; then
  log "INFO" "Debug tracing enabled"
  set -x
fi

is_excluded() {
  case "$1" in
    information_schema|performance_schema|mysql|sys) return 0 ;;
    *) return 1 ;;
  esac
}

backup_database() {
  local db="$1"
  local db_dir="$BACKUP_DIR/dumps/$db"
  mkdir -p "$db_dir"
  local out="$db_dir/${db}_${DATE}.sql"
  
  if run_mysqldump \
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

STAGE="database_list"

# If specific databases are specified, use them; otherwise discover all databases
if [[ ${#SPECIFIED_DBS[@]} -gt 0 ]]; then
  log "INFO" "Using specified databases: ${SPECIFIED_DBS[*]}"
  # Validate that specified databases exist
  log "INFO" "Validating specified databases"
  ALL_DBS=()
  MYSQL_ERR_FILE=$(mktemp)
  trap - ERR
  set +e
  DB_OUTPUT=$(run_mysql -N -e "SHOW DATABASES;" 2>"$MYSQL_ERR_FILE")
  mysql_rc=$?
  set -e
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[0]:-main}"' ERR
  MYSQL_ERROR=$(cat "$MYSQL_ERR_FILE" 2>/dev/null || echo "")
  rm -f "$MYSQL_ERR_FILE"
  # Filter out debug trace lines (starting with +) and extract only MySQL error messages
  MYSQL_ERROR=$(echo "$MYSQL_ERROR" | grep -E "^ERROR" | head -1 || echo "$MYSQL_ERROR" | grep -v "^++\|^+" | grep -i error | head -1 || echo "$MYSQL_ERROR" | grep -v "^++\|^+" | head -1 || echo "$MYSQL_ERROR")
  if [[ $mysql_rc -ne 0 ]] || [[ -z "$DB_OUTPUT" ]]; then
    log "ERROR" "Unable to connect to MySQL"
    log "ERROR" "Connection details: host=${MYSQL_HOST}, port=${MYSQL_PORT}, user=${MYSQL_USER}, socket=${MYSQL_SOCKET:-not set}"
    [[ -n "$MYSQL_ERROR" ]] && log "ERROR" "MySQL error: $MYSQL_ERROR"
    echo "Unable to connect to MySQL. Check connection parameters and MySQL server status." >&2
    echo "Detailed error logged to: $LOG_PATH" >&2
    exit 1
  fi
  while IFS= read -r db; do
    [[ -n "$db" ]] && ALL_DBS+=("$db")
  done <<< "$DB_OUTPUT"
  
  # Check if specified databases exist (bash 3.2 compatible)
  db_exists() {
    local search_db="$1"
    for db in "${ALL_DBS[@]}"; do
      [[ "$db" == "$search_db" ]] && return 0
    done
    return 1
  }
  
  VALID_DBS=()
  for db in "${SPECIFIED_DBS[@]}"; do
    if db_exists "$db"; then
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
  MYSQL_ERR_FILE=$(mktemp)
  trap - ERR
  set +e
  DB_OUTPUT=$(run_mysql -N -e "SHOW DATABASES;" 2>"$MYSQL_ERR_FILE")
  mysql_rc=$?
  set -e
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[0]:-main}"' ERR
  MYSQL_ERROR=$(cat "$MYSQL_ERR_FILE" 2>/dev/null || echo "")
  rm -f "$MYSQL_ERR_FILE"
  # Filter out debug trace lines (starting with +) and extract only MySQL error messages
  MYSQL_ERROR=$(echo "$MYSQL_ERROR" | grep -E "^ERROR" | head -1 || echo "$MYSQL_ERROR" | grep -v "^++\|^+" | grep -i error | head -1 || echo "$MYSQL_ERROR" | grep -v "^++\|^+" | head -1 || echo "$MYSQL_ERROR")
  if [[ $mysql_rc -ne 0 ]] || [[ -z "$DB_OUTPUT" ]]; then
    log "ERROR" "Unable to connect to MySQL"
    log "ERROR" "Connection details: host=${MYSQL_HOST}, port=${MYSQL_PORT}, user=${MYSQL_USER}, socket=${MYSQL_SOCKET:-not set}"
    [[ -n "$MYSQL_ERROR" ]] && log "ERROR" "MySQL error: $MYSQL_ERROR"
    echo "Unable to connect to MySQL. Check connection parameters and MySQL server status." >&2
    echo "Detailed error logged to: $LOG_PATH" >&2
    exit 1
  fi
  while IFS= read -r db; do
    [[ -n "$db" ]] && DATABASES+=("$db")
  done <<< "$DB_OUTPUT"
  
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

# BACKUP_LEVEL: only FULL is supported. Ignore other values and force FULL with a clear warning.
LEVEL_RAW="${BACKUP_LEVEL:-}"
LEVEL_UPPER=$(echo "$LEVEL_RAW" | tr '[:lower:]' '[:upper:]')
if [[ -z "$LEVEL_UPPER" ]]; then
  log "WARN" "BACKUP_LEVEL is not set; forcing FULL backup"
  LEVEL_UPPER="FULL"
elif [[ "$LEVEL_UPPER" != "FULL" ]]; then
  log "WARN" "BACKUP_LEVEL=$LEVEL_RAW is not supported; forcing FULL backup"
  LEVEL_UPPER="FULL"
fi

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

# Database backup
STAGE="database_backup"
FAILED=0
if [[ "$PARALLEL_ENABLED" -eq 1 ]]; then
  log "INFO" "Backing up ${#VALID_DBS[@]} databases with xargs (${MAX_JOBS} jobs)"
  export -f backup_database log build_mysql_opts run_mysqldump run_mysql
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
  exit 1
fi

########################################
# BINLOG AND MYSQL LOGS BACKUP
########################################
STAGE="mysql_logs"
log "INFO" "Starting BINLOG AND MYSQL LOGS BACKUP"
log "INFO" "Retrieving MySQL variables"
# Combine all SHOW VARIABLES queries into one
MYSQL_VARS=$(run_mysql -N -e "
  SELECT CONCAT(VARIABLE_NAME, '=', VARIABLE_VALUE)
  FROM information_schema.GLOBAL_VARIABLES
  WHERE VARIABLE_NAME IN ('log_bin', 'log_bin_basename', 'log_error', 'slow_query_log_file', 'general_log_file')
  AND VARIABLE_VALUE IS NOT NULL AND VARIABLE_VALUE != '';
" 2>/dev/null || run_mysql -N -e "
  SHOW VARIABLES WHERE Variable_name IN ('log_bin', 'log_bin_basename', 'log_error', 'slow_query_log_file', 'general_log_file');
" 2>/dev/null | awk '{print $1"="substr($0, index($0,$2))}')
log "INFO" "Retrieving MySQL variables, done"
log "INFO" "Parsing MySQL variables"
# Helper function to get MySQL variable value (bash 3.2 compatible)
get_mysql_var() {
  local var_name="$1"
  echo "$MYSQL_VARS" | grep "^${var_name}=" | cut -d'=' -f2- | head -1
}
log "INFO" "Parsing MySQL variables, done"
# Backup binlogs using mysqlbinlog
log "INFO" "Backing up binlogs"
LOG_BIN=$(get_mysql_var "log_bin")
BINLOG_BASENAME=$(get_mysql_var "log_bin_basename")
if [[ "$LOG_BIN" == "ON" || "$LOG_BIN" == "1" ]] && [[ -n "$BINLOG_BASENAME" ]]; then
  BINLOG_DIR=$(dirname "$BINLOG_BASENAME")
  BINLOG_PREFIX=$(basename "$BINLOG_BASENAME")
  log "INFO" "Binlog basename: $BINLOG_BASENAME, directory: $BINLOG_DIR"
  # Get list of binlog files from MySQL
  BINLOG_LIST=$(run_mysql -N -e "SHOW BINARY LOGS;" 2>/dev/null | awk '{print $1}' || echo "")
  if [[ -n "$BINLOG_LIST" ]]; then
    BINLOG_COUNT_TOTAL=0
    while IFS= read -r binlog_file; do
      [[ -z "$binlog_file" ]] && continue
      ((BINLOG_COUNT_TOTAL++))
    done <<< "$BINLOG_LIST"
    log "INFO" "Found $BINLOG_COUNT_TOTAL binlog file(s) from MySQL"
    BINLOG_OUT_DIR="$BACKUP_DIR/binlogs/binlogs_${DATE}"
    mkdir -p "$BINLOG_OUT_DIR"
    BINLOG_COUNT=0
    # mysqlbinlog --raw writes to files in the current directory, so we need to run it in the target directory
    while IFS= read -r binlog_file; do
      [[ -z "$binlog_file" ]] && continue
      log "INFO" "Processing binlog: $binlog_file"
      BINLOG_ERR=$(mktemp)
      # Read binary log from remote MySQL server using mysqlbinlog --raw
      # --raw writes to a file in the current directory, so we cd to the output directory
      (cd "$BINLOG_OUT_DIR" && run_mysqlbinlog --read-from-remote-server --raw "$binlog_file" >/dev/null 2>"$BINLOG_ERR")
      BINLOG_RC=$?
      ERR_OUTPUT=$(cat "$BINLOG_ERR" 2>/dev/null | grep -v "^++\|^+" || echo "")
      rm -f "$BINLOG_ERR" 2>/dev/null || true
      
      binlog_out="$BINLOG_OUT_DIR/$binlog_file"
      if [[ $BINLOG_RC -eq 0 ]]; then
        if [[ -f "$binlog_out" && -s "$binlog_out" ]]; then
          FILE_SIZE=$(stat -f%z "$binlog_out" 2>/dev/null || stat -c%s "$binlog_out" 2>/dev/null || echo "0")
          ((BINLOG_COUNT++))
          log "INFO" "Backed up binlog: $binlog_file (from remote server, raw binary, ${FILE_SIZE} bytes)"
        else
          if [[ -n "$ERR_OUTPUT" ]]; then
            ERR_FIRST=$(echo "$ERR_OUTPUT" | head -1)
            log "WARN" "Binlog $binlog_file from remote server produced empty output: $ERR_FIRST"
          else
            log "WARN" "Binlog $binlog_file from remote server produced empty output (no errors reported)"
          fi
          rm -f "$binlog_out" 2>/dev/null || true
        fi
      else
        if [[ -n "$ERR_OUTPUT" ]]; then
          ERR_FIRST=$(echo "$ERR_OUTPUT" | head -1)
          log "WARN" "Failed to backup binlog $binlog_file from remote server (exit code $BINLOG_RC): $ERR_FIRST"
        else
          log "WARN" "Failed to backup binlog $binlog_file from remote server (exit code $BINLOG_RC, no error message)"
        fi
        rm -f "$binlog_out" 2>/dev/null || true
      fi
    done <<< "$BINLOG_LIST"
    if [[ $BINLOG_COUNT -gt 0 ]]; then
      log "OK" "$BINLOG_COUNT binlog(s) backed up (out of $BINLOG_COUNT_TOTAL found)"
    else
      log "WARN" "No binlogs were backed up (found $BINLOG_COUNT_TOTAL binlog(s) in MySQL but none were accessible)"
    fi
  else
    log "WARN" "Unable to retrieve binlog list from MySQL (SHOW BINARY LOGS returned empty)"
  fi
elif [[ "$LOG_BIN" != "ON" && "$LOG_BIN" != "1" ]]; then
  log "SKIP" "Binlogs disabled (log_bin is OFF)"
else
  log "SKIP" "Binlogs disabled (log_bin_basename is not set)"
fi

# Backup MySQL logs
log "INFO" "Backing up MySQL logs"
LOG_VARS=("log_error" "slow_query_log_file" "general_log_file")
BACKED_UP=0
for var in "${LOG_VARS[@]}"; do
  LOG_FILE=$(get_mysql_var "$var")
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    if cp "$LOG_FILE" "$BACKUP_DIR/mysqllogs/$(basename "$LOG_FILE")_${DATE}" 2>/dev/null; then
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
