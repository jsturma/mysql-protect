# MySQL Backup Script

A robust, feature-rich bash script for backing up MySQL/MariaDB databases with support for parallel processing, compression, and comprehensive log management.

## Features

- **Complete Database Backup**: Backs up all user databases with routines, events, and triggers
- **Selective Backup**: Option to backup specific databases using `-D` option, or backup all databases by default
- **Automatic Exclusion**: Excludes system databases (information_schema, performance_schema, mysql, sys) by default
- **Compression**: Optional gzip compression for space efficiency
- **Parallel Processing**: Optional parallel backup execution for faster processing
- **Binlog Backup**: Automatically backs up binary logs if enabled
- **Log Backup**: Backs up MySQL error logs, slow query logs, and general logs
- **Timestamped Logging**: All operations are logged with timestamps
- **Transaction Safety**: Uses `--single-transaction` for consistent backups
- **Error Handling**: Comprehensive error handling with cleanup on failures

## Requirements

- **Bash**: Version 3.2 or higher (compatible with macOS default bash)
- **MySQL Client Tools**: `mysql` and `mysqldump` binaries
- **Standard Unix Tools**: `gzip`, `xargs` (optional, for parallel processing)
- **MySQL Access**: Appropriate privileges to read databases and access log files

## Installation

1. Clone or download the script:
```bash
git clone <repository-url>
cd mysql-protect
```

2. Make the script executable:
```bash
chmod +x mysql_parallel_protect.sh
```

3. (Optional) Move to a system path:
```bash
sudo mv mysql_parallel_protect.sh /usr/local/bin/mysql-protect
```

## Usage

### Basic Usage

```bash
./mysql_parallel_protect.sh
```

This will use default settings:
- Connect to `localhost:3306` as `root`
- Backup to `/var/backups/mysql`
- No compression (backups stored as plain SQL files)
- Backup all databases (excluding system databases: information_schema, performance_schema, mysql, sys)
- Use `-D` option to backup specific databases only

### Dell PPDM Generic Application Agent usage

This repo includes a PPDM-focused variant:

- **`mysql_ppdm_protect.sh`**: optimized for Dell PowerProtect Data Manager Generic Application Agent scripting (sequential backups, no parallelization).

Key behavior (when PPDM provides these exported variables):
- **`DD_TARGET_DIRECTORY`**: if set, backups are written under this directory (PPDM target path for the job).
- **`ASSET_USERNAME` / `ASSET_PASSWORD`**: used as defaults when `-u` / `-p` are not provided.
- **`BACKUP_LEVEL`**: only `FULL` is supported; other values are rejected with a clear error.
- **`BACKUP_RESPONSE_FILEPATH`**: if set, the script writes a JSON response containing `ddBackupPath` (folder paths only) and an error message on failure.
- **`TRACE_ID`**: included in log output when present.

Run it manually (typical local test):

```bash
./mysql_ppdm_protect.sh -h localhost -u root -d /tmp/mysql-backups -D mydb
```

Emulate a PPDM-style run (example):

```bash
export DD_TARGET_DIRECTORY=/tmp/ppdm-target
export ASSET_USERNAME=root
export ASSET_PASSWORD=''
export BACKUP_LEVEL=FULL
export BACKUP_RESPONSE_FILEPATH=/tmp/ppdm-backup-response.json
export TRACE_ID=example-trace-id
./mysql_ppdm_protect.sh -D mydb
cat /tmp/ppdm-backup-response.json
```

### Command-Line Options

```
Usage: ./mysql_parallel_protect.sh [-h host] [-P port] [-u user] [-p password] [-s socket] [-d backup_dir] [-j jobs] [-D database1,database2,...]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-h` | MySQL host | `localhost` |
| `-P` | MySQL port | `3306` |
| `-u` | MySQL user | `root` |
| `-p` | MySQL password | (empty, use `.my.cnf` recommended) |
| `-s` | MySQL socket path | (empty, uses host/port) |
| `-d` | Backup directory | `/var/backups/mysql` |
| `-j` | Number of parallel jobs | `1` (sequential) |
| `-D` | Specific databases to backup (comma-separated) | All databases (excluding system DBs) |

`mysql_ppdm_protect.sh` supports the same options **except** `-j`.

### Examples

**Backup with custom host and user:**
```bash
./mysql_parallel_protect.sh -h db.example.com -u backup_user -p mypassword
```

**Backup to custom directory:**
```bash
./mysql_parallel_protect.sh -d /backups/mysql -u root
```

**Parallel backup (4 concurrent jobs):**
```bash
./mysql_parallel_protect.sh -j 4 -u root
```

**Using MySQL socket:**
```bash
./mysql_parallel_protect.sh -s /var/run/mysqld/mysqld.sock -u root
```

**Backup specific databases:**
```bash
# Backup single database
./mysql_parallel_protect.sh -D myapp -u root

# Backup multiple databases (comma-separated)
./mysql_parallel_protect.sh -D myapp,mydb,testdb -u root

# Backup specific databases with parallel processing
./mysql_parallel_protect.sh -D myapp,mydb -j 4 -u root
```

**Full example with all options:**
```bash
./mysql_parallel_protect.sh \
  -h db.example.com \
  -P 3307 \
  -u backup_user \
  -p secure_password \
  -d /mnt/backups/mysql \
  -j 4
```

## Configuration

### Default Settings

You can modify the default configuration by editing the variables at the top of the script:

```bash
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASSWORD=""            # recommended: .my.cnf
MYSQL_SOCKET=""
BACKUP_DIR="/var/backups/mysql"
COMPRESS="no"
```

### Excluded Databases

By default, the following system databases are excluded:
- `information_schema`
- `performance_schema`
- `mysql`
- `sys`

To modify the exclusion list, edit the `EXCLUDE_DBS` associative array in the script.

### Password Security

**Recommended**: Use a `.my.cnf` file instead of passing passwords on the command line:

```ini
[client]
user=backup_user
password=your_password
host=localhost
port=3306
```

Place this file at `~/.my.cnf` with appropriate permissions:
```bash
chmod 600 ~/.my.cnf
```

## Output Structure

The script creates the following directory structure:

```
BACKUP_DIR/
├── dumps/
│   ├── database1/
│   │   ├── database1_2024-01-15_14-30-45.sql
│   │   └── database1_2024-01-16_14-30-45.sql
│   ├── database2/
│   │   ├── database2_2024-01-15_14-30-45.sql
│   │   └── database2_2024-01-16_14-30-45.sql
│   └── ...
└── logs/
    ├── binlogs_2024-01-15_14-30-45/
    ├── error.log_2024-01-15_14-30-45
    ├── slow-query.log_2024-01-15_14-30-45
    └── general.log_2024-01-15_14-30-45
```

Each database has its own directory under `dumps/`, making it easy to organize and manage backups per database. Server-wide logs (binlogs, error logs, etc.) are stored in the common `logs/` directory.

## Logging

All operations are logged with timestamps. Example output:

```
[2024-01-15 14:30:45] [INFO] Discovering MySQL databases
[2024-01-15 14:30:46] [SKIP] Excluding database information_schema
[2024-01-15 14:30:47] [INFO] Backing up 3 databases
[2024-01-15 14:30:48] [OK] myapp backed up and compressed
[2024-01-15 14:30:49] [OK] mydb backed up and compressed
[2024-01-15 14:30:50] [INFO] Backing up binlogs
[2024-01-15 14:30:51] [OK] Binlogs backed up
[2024-01-15 14:30:52] [OK] MySQL backup completed: /var/backups/mysql
```

Log levels:
- `INFO`: Informational messages
- `OK`: Successful operations
- `ERROR`: Error conditions
- `SKIP`: Skipped/excluded items

## Parallel Processing

When using the `-j` option with a value greater than 1, the script will process multiple databases concurrently. This can significantly reduce backup time for multiple databases.

**Note**: Parallel processing requires `xargs` to be available. If not available, the script falls back to sequential processing.

Example:
```bash
./mysql_parallel_protect.sh -j 4  # Process 4 databases simultaneously
```

## Backup Features

### Database Dumps

- Uses `--single-transaction` for consistent backups without locking tables
- Includes stored routines (`--routines`)
- Includes events (`--events`)
- Includes triggers (`--triggers`)
- Optional gzip compression

### Binary Logs

- Automatically detects if binary logging is enabled
- Backs up the entire binlog directory if available
- Preserves directory structure

### MySQL Logs

- Error log (`log_error`)
- Slow query log (`slow_query_log_file`)
- General log (`general_log_file`)

Only logs that exist and are configured are backed up.

## Error Handling

- The script uses `set -euo pipefail` for strict error handling
- Failed database backups are logged and cleaned up (partial files removed)
- Connection errors are reported and the script exits
- Individual backup failures don't stop the entire process

## Cron Integration

Example cron job to run daily at 2 AM:

```bash
0 2 * * * /path/to/mysql_parallel_protect.sh -u backup_user -d /backups/mysql >> /var/log/mysql-backup.log 2>&1
```

## Troubleshooting

### Connection Issues

If you encounter connection errors:
1. Verify MySQL is running
2. Check host, port, and credentials
3. Ensure the user has appropriate privileges
4. Check firewall rules if connecting remotely

### Permission Issues

Ensure the backup directory is writable:
```bash
sudo mkdir -p /var/backups/mysql
sudo chown $USER:$USER /var/backups/mysql
```

### Missing Binaries

If `mysql` or `mysqldump` are not found, update the paths in the script:
```bash
MYSQL_BIN="/usr/bin/mysql"
MYSQLDUMP_BIN="/usr/bin/mysqldump"
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions, bug reports, and feature requests are welcome!
