# MySQL Backup Script

Simple bash script for backing up MySQL/MariaDB databases with support for parallel processing, compression, and comprehensive log management.

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
- **`ASSET_USERNAME` / `ASSET_PASSWORD`**: optional; when set, used for MySQL authentication. When not set, rely on defaults or client config (for example, `~/.my.cnf`).
- **`BACKUP_LEVEL`**: only `FULL` is supported; other values are ignored and the script forces a FULL backup with a warning.
- **`TRACE_ID`**: included in log output when present.

Run it manually (typical local test):

```bash
./mysql_ppdm_protect.sh -h localhost -u root -d /tmp/mysql-backups -D mydb
```

Force parallel database dumps (use with care):

```bash
./mysql_ppdm_protect.sh -D mydb1,mydb2 -j 4 -f
```

Run with debug enabled (example):

```bash
export DEBUG=1
export DD_TARGET_DIRECTORY=/tmp/ppdm-mysql-backup
export BACKUP_LEVEL=FULL
./mysql_ppdm_protect.sh -D mydb
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

PPDM variant:

```
Usage: ./mysql_ppdm_protect.sh [-h host] [-P port] [-s socket] [-D database1,database2,...] [-j jobs] [-f]
```

- `-j` requests parallel jobs, but **parallel is only enabled when `-f` is also provided** (otherwise it runs sequentially).

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

## Dev lab (Podman)

To stand up a quick local MySQL lab environment for development/testing using Podman:

### Deploy a MySQL container

1. Pull the MySQL image:

```bash
podman pull mysql
```

2. Run MySQL (example: root password `MySql`, port `3306`):

```bash
podman run -d -p 3306:3306 -e MYSQL_ROOT_PASSWORD=MySql --name mysql-db mysql:latest
```

3. Confirm it is running:

```bash
podman ps
```

4. Connect to MySQL inside the container:

```bash
podman exec -it mysql-db mysql -u root -p
```

5. Validate from the MySQL prompt:

```sql
SHOW DATABASES;
```

### Create multiple databases and seed sample data

Run the following from your host to create a few databases, tables, and rows:

```bash
podman exec -i mysql-db mysql -u root -pMySql <<'SQL'
CREATE DATABASE IF NOT EXISTS appdb;
CREATE DATABASE IF NOT EXISTS testdb;
CREATE DATABASE IF NOT EXISTS analytics;

USE appdb;
CREATE TABLE IF NOT EXISTS users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  email VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO users (email) VALUES ('alice@example.com'), ('bob@example.com');

USE testdb;
CREATE TABLE IF NOT EXISTS notes (
  id INT PRIMARY KEY AUTO_INCREMENT,
  note TEXT NOT NULL
);
INSERT INTO notes (note) VALUES ('hello'), ('ppdm lab');

USE analytics;
CREATE TABLE IF NOT EXISTS events (
  id INT PRIMARY KEY AUTO_INCREMENT,
  event_name VARCHAR(100) NOT NULL,
  event_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO events (event_name) VALUES ('startup'), ('seeded');
SQL
```

Verify:

```bash
podman exec -it mysql-db mysql -u root -pMySql -e "SHOW DATABASES; SHOW TABLES FROM appdb; SELECT * FROM appdb.users;"
```

### Create DBs, load data, and simulate user activity (MySQL Workbench)

1. **Open MySQL Workbench** → **Database → Manage Connections** → **New**:
   - **Hostname**: `127.0.0.1`
   - **Port**: `3306`
   - **Username**: `root`
   - **Password**: `MySql`

2. **Create databases and tables**:
   - Open a new SQL tab and run the same SQL from the “seed sample data” section above.

3. **Load data (Workbench GUI options)**:
   - **Table Data Import Wizard**: Right-click a schema/table → **Table Data Import Wizard** (CSV/JSON).
   - **Server → Data Import**: Import from a self-contained file (a `.sql` dump) or from a folder of dump files.

4. **Simulate user activity** (run these in a Workbench SQL tab, a few times):

```sql
USE appdb;
INSERT INTO users (email) VALUES (CONCAT('user', FLOOR(RAND()*100000), '@example.com'));
SELECT COUNT(*) AS user_count FROM users;

USE analytics;
INSERT INTO events (event_name) VALUES ('login');
SELECT event_name, COUNT(*) AS c FROM events GROUP BY event_name ORDER BY c DESC;
```

### Stop and remove the lab container

```bash
podman stop mysql-db
podman rm mysql-db
```

Reference: [Database setup with Podman containers](https://sharafat.pages.dev/database-containers/)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions, bug reports, and feature requests are welcome!
