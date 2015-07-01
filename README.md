# mariadb-backup

Backups ran on "fullbackday" will be full backups. Backups ran on other days will be incremental. 

The backups are done with xtrabackup/innobackupex. Backups are compressed (qpress) and encrypted (xbcrypt). 

Details about each backup are emailed to all email addresses listed in MAILLIST and also logged in the database (PERCONA_SCHEMA.xtrabackup_history) for easier monitoring in MONyog. 

Encrypted incremental backups are enabled by decrypting the xtrabackup_checkpoints file. 

Options for inclusion of Galera and slave info.

If Galera option is yes, the script will enable wsrep_desync on the node being backed up. When the backup is finished, it will check for wsrep_local_recv_queue to return to zero before disabling wsrep_desync. 

Option to disable MONyog alerts before, and enable after. 

Use the following to create the encryption key file: 
```
openssl rand -base64 24
```
Send output to key file like:
```
echo -n "openssl_output_here" > /etc/my.cnf.d/backupscript.key
```

Grant these permissions to the backup user  <br />
```
GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup_user'@'localhost' IDENTIFIED BY 'backup_password';
GRANT CREATE, INSERT, SELECT ON PERCONA_SCHEMA.* TO 'backup_user'@'localhost';
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
```

Todo: 
- Clean up the clean up.
- Continue testing. 
- Add logic to allow subsequent runs on fullbackday to be incremental.
