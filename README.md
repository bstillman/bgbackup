# bgbackup

bgbackup is a MySQL ecosystem wrapper script for setting up a daily database backup routine. It can be configured to run different types of backups, and send a status email upon completion.

bgbackup works with MariaDB, Percona, MySQL, Galera Cluster, WebscaleSQL, etc.

The backups are done with xtrabackup/innobackupex. bgbackup supports multiple backup types, such as:

 * Standalone directories, with optional compression (qpress) and encryption (xbcrypt).
 
 * Compressed tar archives with gzip and pigz (parallel gzip) support. bgbackup may support multiple compressors in future. 
 
 * Optional "prepared" stage for tar archives where logs are applied before compression.
 
 * Optional partial backup on specific database names.
 
## Main features
 
### Scheduling

Set `fullbackday` to the day you would like full backups taken. The first backup of `fullbackday` will be full backups. All subsequent backups (including backups taken later the same day) will be incremental or differential based on the setting `differential`. 

To disable incremental/differential backups and have every run be a full backup, set `fullbackday` to `Always`

### Emails

Details about all backups are emailed to all email addresses listed in MAILLIST if `mailonsuccess` is enabled. Otherwise, only details about failed backups are emailed. 

### Backup History

Details about each backup are logged in the database (`backuphistschema`.mariadb_backup_history) for easier monitoring in MONyog, Nagios, Cacti, etc. This table is also used by innobackupex to find the backup base directory for incremental and differential backups. 

### Encryption

xbcrypt encryption is fully supported for directory backup type.

Encrypted incremental backups are enabled by decrypting the xtrabackup_checkpoints file. 

### Compression

bgbackup supports two different compression modes:

 * qpress for standalone directory backup types. Each file is compressed individually.

 * gzip and pigz (parallel gzip) for tar archive backup types. Additional support for other compressors will be added in the future.

### Galera

If Galera option is set to yes, the script will enable wsrep_desync on the node being backed up. When the backup is finished, it will check for wsrep_local_recv_queue to return to zero before disabling wsrep_desync. 

### MONYog support

Option to disable MONyog alerts before, and enable after. 

### Run external commands after backup

Optionally set external commands to be run after successful or failed backup, respectively.

## Setup instructions

Use the following to create the encryption key file: <br />
```
echo -n $(openssl rand -base64 24) > /etc/my.cnf.d/backupscript.key
```

Create the MDB Utilities schema/database: <br />
```
CREATE DATABASE `backuphistschema`;
```

Create the backup user:  <br />
```
GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'bgbackup'@'localhost' IDENTIFIED BY 'your_password_here';
GRANT ALL PRIVILEGES ON `backuphistschema`.* TO 'backup_user'@'localhost';
FLUSH PRIVILEGES; 
```

Add this info to bottom of /etc/my.cnf (MySQL) or new /etc/my.cnf.d/xtrabackup.cnf (MariaDB): <br />
```
[xtrabackup]
port = 3306
socket = /path/to/socket
datadir = /path/to/datadir
innodb_data_home_dir = /path/to/innodb_data_home_dir
```

Lock down permissions on config file(s)  <br />
```
chown mysql /etc/my.cnf
chmod 600 /etc/my.cnf

chown mysql /etc/my.cnf.d/xtrabackup.cnf
chmod 600 /etc/my.cnf.d/xtrabackup.cnf

chown mysql /etc/my.cnf.d/backupscript.key
chmod 600 /etc/my.cnf.d/backupscript.key

chown mysql /PATH/TO/bgbackup.cnf
chmod 600 /PATH/TO/bgbackup.cnf
```
