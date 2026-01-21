# MySQL Backup Script

Simple bash scripts for backing up MySQL/MariaDB databases and detecting MySQL environments. The backup script supports parallel processing, compression, and comprehensive log management. The environment detection script helps identify deployment types, privileges, and restrictions.

## Features

- **Complete Database Backup**: Backs up all user databases with routines, events, and triggers
- **Selective Backup**: Option to backup specific databases using `-D` option, or backup all databases by default
- **Automatic Exclusion**: Excludes system databases (information_schema, performance_schema, mysql, sys) by default
- **Compression**: Optional gzip compression for space efficiency
- **Parallel Processing**: Optional parallel backup execution for faster processing
- **Binlog Backup**: Automatically backs up binary logs using `mysqlbinlog` if enabled
- **Log Backup**: Backs up MySQL error logs, slow query logs, and general logs
- **Timestamped Logging**: All operations are logged with timestamps
- **Transaction Safety**: Uses `--single-transaction` for consistent backups
- **Error Handling**: Comprehensive error handling with cleanup on failures

## Requirements

- **Bash**: Version 3.2 or higher (compatible with macOS default bash)
- **MySQL Client Tools**: `mysql`, `mysqldump`, and `mysqlbinlog` binaries
- **Standard Unix Tools**: `gzip`, `xargs` (optional, for parallel processing)
- **MySQL Access**: Appropriate privileges to read databases and access log files

## Installation

1. Clone or download the script:
```bash
git clone <repository-url>
cd mysql-protect
```

2. Make the scripts executable:
```bash
chmod +x mysql_protect.sh mysql_detect_env.sh
```

3. (Optional) Move to a system path:
```bash
sudo mv mysql_protect.sh /usr/local/bin/mysql-protect
sudo mv mysql_detect_env.sh /usr/local/bin/mysql-detect-env
```

## Usage

### Basic Usage

```bash
./mysql_protect.sh -D mydb
```

This will use default settings:
- Connect to `localhost:3306` as `root`
- Backup to `DD_TARGET_DIRECTORY` (required)
- No compression (backups stored as plain SQL files)
- Backup all databases (excluding system databases: information_schema, performance_schema, mysql, sys)
- Use `-D` option to backup specific databases only

### Job-runner integration

The script supports running under an external job runner that exports environment variables.

Key behavior (when the job runner provides these exported variables):
- **`DD_TARGET_DIRECTORY`**: required; backups are written under this directory (target path for the job).
- **`ASSET_USERNAME` / `ASSET_PASSWORD`**: optional; when set, used for MySQL authentication. When not set, rely on defaults or client config (for example, `~/.my.cnf`).
- **`BACKUP_LEVEL`**: only `FULL` is supported; other values are ignored and the script forces a FULL backup with a warning.
- **`TRACE_ID`**: included in log output when present.

Run it manually (typical local test):

```bash
./mysql_protect.sh -h localhost -u root -d /tmp/mysql-backups -D mydb
```

Force parallel database dumps (use with care):

```bash
./mysql_protect.sh -D mydb1,mydb2 -j 4 -f
```

Run with debug enabled (example):

```bash
export DEBUG=1
export DD_TARGET_DIRECTORY=/tmp/mysql-backup-target
export BACKUP_LEVEL=FULL
./mysql_protect.sh -D mydb
```

### Command-Line Options

```
Usage: ./mysql_protect.sh [-h host] [-P port] [-s socket] [-D database1,database2,...] [-j jobs] [-f]
```

- `-j` requests parallel jobs, but **parallel is only enabled when `-f` is also provided** (otherwise it runs sequentially).

### Examples

**Using MySQL socket:**
```bash
./mysql_protect.sh -s /var/run/mysqld/mysqld.sock -D mydb
```

**Backup specific databases:**
```bash
# Backup single database
./mysql_protect.sh -D myapp

# Backup multiple databases (comma-separated)
./mysql_protect.sh -D myapp,mydb,testdb

# Backup specific databases with parallel processing
./mysql_protect.sh -D myapp,mydb -j 4 -f
```

## MySQL Environment Detection

The repository includes `mysql_detect_env.sh`, a utility script to detect and analyze your MySQL environment. This is particularly useful for understanding deployment type, available privileges, and any restrictions.

### Features

- **Environment Detection**: Automatically detects AWS RDS, Azure Database, GCP Cloud SQL, Percona, MariaDB, and containerized deployments
- **Container Detection**: Identifies Docker/Podman containers by analyzing hostname patterns and datadir paths
- **Privilege Check**: Verifies SUPER privilege availability
- **Environment-Specific Warnings**: Provides relevant guidance based on detected environment type

### Usage

```bash
# Basic usage (uses defaults: 127.0.0.1:3306 as root)
./mysql_detect_env.sh

# With custom connection parameters
MYSQL_HOST=192.168.1.100 MYSQL_USER=backup_user ./mysql_detect_env.sh

# With password (or use .my.cnf)
MYSQL_HOST=127.0.0.1 MYSQL_USER=root MYSQL_PASSWORD=mypassword ./mysql_detect_env.sh
```

### Example Output

For a containerized MySQL instance:

```
🔍 Detecting MySQL environment...
--------------------------------------
Version           : 9.5.0
Version comment   : MySQL Community Server - GPL
Hostname          : ef0e77980304
Datadir           : /var/lib/mysql/
SUPER privilege   : YES
Containerized     : YES (Container (Docker/Podman))

🧠 Detected environment: MySQL Community (Container: Docker/Podman)
--------------------------------------
📦 Containerized environment detected:
   - Full MySQL control available
   - Streaming binlog OK
   - Filesystem access limited to container
   - Binlog files may need remote access (--read-from-remote-server)
   - Consider volume mounts for persistent data

✅ Detection completed
```

### Detected Environments

- **AWS RDS**: Amazon RDS MySQL
- **Azure Database for MySQL**: Azure PaaS offering
- **GCP Cloud SQL**: Google Cloud SQL MySQL
- **Percona Server**: Percona Server (VM/on-prem or container)
- **MariaDB**: MariaDB (VM/on-prem or container)
- **MySQL Community**: MySQL Community Server (VM/on-prem or container)

### Environment Variables

The detection script supports the same environment variables as the backup script:

- `MYSQL_HOST`: MySQL host (default: 127.0.0.1)
- `MYSQL_PORT`: MySQL port (default: 3306)
- `MYSQL_USER`: MySQL user (default: root)
- `MYSQL_PASSWORD`: MySQL password (default: empty, use .my.cnf recommended)
- `MYSQL_SOCKET`: MySQL socket path (default: empty)
- `ASSET_USERNAME`: Alternative username (for job-runner integration)
- `ASSET_PASSWORD`: Alternative password (for job-runner integration)

## Configuration

### Default Settings

Default configuration values (can be overridden by environment variables):

```bash
MYSQL_HOST="127.0.0.1"       # Default: 127.0.0.1 (use 127.0.0.1 instead of localhost to force TCP/IP)
MYSQL_PORT="3306"            # Default: 3306
MYSQL_USER="root"            # Default: root
MYSQL_PASSWORD=""            # Default: empty (recommended: use .my.cnf)
MYSQL_SOCKET=""              # Default: empty (use TCP/IP if not set)
BACKUP_DIR=""                # Default: empty (must be set via DD_TARGET_DIRECTORY or LOCAL_DIRECTORY)
COMPRESS="no"                # Default: no (set to "yes" for gzip compression)
```

**Override with environment variables:**

These defaults can be overridden by exporting environment variables before running the script:

```bash
export MYSQL_HOST="192.168.1.100"
export MYSQL_PORT="3307"
export MYSQL_USER="backup_user"
export MYSQL_PASSWORD="secret"
export COMPRESS="yes"
./mysql_protect.sh -D mydb
```

If environment variables are not set, the default values shown above will be used.

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
├── binlogs/
│   └── binlogs_2024-01-15_14-30-45/
│       ├── mysql-bin.000001.sql
│       ├── mysql-bin.000002.sql
│       └── ...
├── backuplogs/
│   └── mysql_protect_20240115_143045_12345.log
└── mysqllogs/
    ├── error.log_2024-01-15_14-30-45
    ├── slow-query.log_2024-01-15_14-30-45
    └── general.log_2024-01-15_14-30-45
```

Each database has its own directory under `dumps/`, making it easy to organize and manage backups per database. Binary logs are converted to SQL format using `mysqlbinlog` and stored in `binlogs/`. Script execution logs are stored in `backuplogs/`, while MySQL server logs (error, slow query, general) are stored in `mysqllogs/`.

## Logging

All operations are logged with timestamps. Example output:

```
[2024-01-15 14:30:45] [INFO] Discovering MySQL databases
[2024-01-15 14:30:46] [SKIP] Excluding database information_schema
[2024-01-15 14:30:47] [INFO] Backing up 3 databases
[2024-01-15 14:30:48] [OK] myapp backed up and compressed
[2024-01-15 14:30:49] [OK] mydb backed up and compressed
[2024-01-15 14:30:50] [INFO] Backing up binlogs
[2024-01-15 14:30:51] [INFO] Backed up binlog: mysql-bin.000001
[2024-01-15 14:30:52] [OK] 2 binlog(s) backed up
[2024-01-15 14:30:52] [OK] MySQL backup completed: /var/backups/mysql
```

Log levels:
- `INFO`: Informational messages
- `OK`: Successful operations
- `ERROR`: Error conditions
- `SKIP`: Skipped/excluded items

Script execution logs are stored in `$BACKUP_DIR/backuplogs/` and include timestamps for all operations.

## Parallel Processing

When using the `-j` option with a value greater than 1, the script will process multiple databases concurrently. This can significantly reduce backup time for multiple databases.

**Note**: Parallel processing requires `xargs` to be available. If not available, the script falls back to sequential processing.

Example:
```bash
./mysql_protect.sh -D mydb1,mydb2 -j 4 -f
```

## Backup Features

### Database Dumps

- Uses `mysqldump` for database backups
- Uses `--single-transaction` for consistent backups without locking tables
- Includes stored routines (`--routines`)
- Includes events (`--events`)
- Includes triggers (`--triggers`)
- Optional gzip compression

### Binary Logs

- Automatically detects if binary logging is enabled
- Uses `mysqlbinlog` to convert binary logs to SQL format
- Each binlog file is converted and saved as a `.sql` file
- Stored in `$BACKUP_DIR/binlogs/binlogs_${DATE}/`

### MySQL Logs

- Error log (`log_error`)
- Slow query log (`slow_query_log_file`)
- General log (`general_log_file`)
- Stored in `$BACKUP_DIR/mysqllogs/`

Only logs that exist and are configured are backed up.

## Error Handling

- The script uses `set -euo pipefail` for strict error handling
- Failed database backups are logged and cleaned up (partial files removed)
- Connection errors are reported and the script exits
- Individual backup failures don't stop the entire process

## Cron Integration

Example cron job to run daily at 2 AM:

```bash
0 2 * * * DD_TARGET_DIRECTORY=/backups/mysql BACKUP_LEVEL=FULL /path/to/mysql_protect.sh -D mydb >> /var/log/mysql-backup.log 2>&1
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

The script automatically locates `mysql`, `mysqldump`, and `mysqlbinlog` using `which`. If they are not found in PATH, the script will exit with an error. Ensure MySQL client tools are installed and in your PATH:

```bash
# Check if binaries are available
which mysql mysqldump mysqlbinlog
```

If needed, install MySQL client tools for your system:
- **macOS**: `brew install mysql-client`
- **Debian/Ubuntu**: `apt-get install mysql-client`
- **RHEL/CentOS**: `yum install mysql`

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

-- Note: If your SQL client does not allow multiple statements per execution,
-- run these statements one-by-one.

CREATE TABLE IF NOT EXISTS appdb.users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  email VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP NULL
);
INSERT INTO appdb.users (email, created_at) VALUES ('alice@example.com', NOW());
INSERT INTO appdb.users (email, created_at) VALUES ('bob@example.com', NOW());

CREATE TABLE IF NOT EXISTS testdb.notes (
  id INT PRIMARY KEY AUTO_INCREMENT,
  note TEXT NOT NULL
);
INSERT INTO testdb.notes (note) VALUES ('hello');
INSERT INTO testdb.notes (note) VALUES ('lab');

CREATE TABLE IF NOT EXISTS analytics.events (
  id INT PRIMARY KEY AUTO_INCREMENT,
  event_name VARCHAR(100) NOT NULL,
  event_time TIMESTAMP NULL
);
INSERT INTO analytics.events (event_name, event_time) VALUES ('startup', NOW());
INSERT INTO analytics.events (event_name, event_time) VALUES ('seeded', NOW());
SQL
```

Verify:

```bash
podman exec -it mysql-db mysql -u root -pMySql -e "SHOW DATABASES; SHOW TABLES FROM appdb; SELECT * FROM appdb.users;"
```

### Load official sample databases (optional)

MySQL provides several official sample databases (for example: **Sakila**, **World**, **Employees**) that are useful for demos and testing. See the “Example Databases” section here:

- [Other MySQL Documentation → Example Databases](https://dev.mysql.com/doc/index-other.html)

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
INSERT INTO appdb.users (email, created_at) VALUES (CONCAT('user', FLOOR(RAND()*100000), '@example.com'), NOW());
SELECT COUNT(*) AS user_count FROM appdb.users;

INSERT INTO analytics.events (event_name, event_time) VALUES ('login', NOW());
SELECT event_name, COUNT(*) AS c FROM analytics.events GROUP BY event_name ORDER BY c DESC;
```

### Do the same using the MySQL CLI only (no Workbench)

### Avoid putting `-pPASSWORD` in commands

To avoid exposing passwords in shell history/process lists, prefer one of these approaches:

1. **Prompt for password interactively** (no password in the command):

```bash
mysql -h 127.0.0.1 -P 3306 -u root -p --get-server-public-key --ssl-mode=DISABLED
```

2. **Use a client config file** (recommended):

Create `~/.my.cnf`:

```ini
[client]
user=root
password=MySql
host=127.0.0.1
port=3306
ssl-mode=DISABLED
get-server-public-key=1
```

Then secure it:

```bash
chmod 600 ~/.my.cnf
```

Now you can run:

```bash
mysql
```

Note: For container-only access, you can also run `mysql -p` *inside* the container via `podman exec` and type the password when prompted.

Connect from your host:

```bash
mysql -h 127.0.0.1 -P 3306 -u root -pMySql --get-server-public-key --ssl-mode=DISABLED
```

Or connect from inside the container:

```bash
podman exec -it mysql-db mysql -u root -pMySql
```

Create databases and tables (run in the MySQL prompt):

```sql
CREATE DATABASE IF NOT EXISTS `appdb`;
CREATE DATABASE IF NOT EXISTS `testdb`;
CREATE DATABASE IF NOT EXISTS `analytics`;

CREATE TABLE IF NOT EXISTS appdb.users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  email VARCHAR(255) NOT NULL UNIQUE,
  created_at TIMESTAMP NULL
);

CREATE TABLE IF NOT EXISTS testdb.notes (
  id INT PRIMARY KEY AUTO_INCREMENT,
  note TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS analytics.events (
  id INT PRIMARY KEY AUTO_INCREMENT,
  event_name VARCHAR(100) NOT NULL,
  event_time TIMESTAMP NULL
);
```

Insert sample data (run in the MySQL prompt):

```sql
INSERT INTO appdb.users (email, created_at) VALUES ('alice@example.com', NOW());
INSERT INTO appdb.users (email, created_at) VALUES ('bob@example.com', NOW());
INSERT INTO testdb.notes (note) VALUES ('hello');
INSERT INTO testdb.notes (note) VALUES ('lab');
INSERT INTO analytics.events (event_name, event_time) VALUES ('startup', NOW());
INSERT INTO analytics.events (event_name, event_time) VALUES ('seeded', NOW());
```

Simulate “user activity” (run a few times):

```sql
INSERT INTO appdb.users (email, created_at) VALUES (CONCAT('user', FLOOR(RAND()*100000), '@example.com'), NOW());
INSERT INTO analytics.events (event_name, event_time) VALUES ('login', NOW());
SELECT COUNT(*) AS user_count FROM appdb.users;
SELECT event_name, COUNT(*) AS c FROM analytics.events GROUP BY event_name ORDER BY c DESC;
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
