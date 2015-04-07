# mariadb-backup

This backup script is designed to be able to be ran multiple times per day. The first run on the day specified as the "FULLBACKUPDAY" will create a new folder for the week's backups. A full backup will then be ran. Each additional run throughout the week, including subsequent runs on "FULLBACKUPDAY", will be incremental backups also going to the week's folder. 

The backups are done with xtrabackup/innobackupex. Backups are compressed (qpress) and encrypted (xbcrypt). 

Details about each backup are emailed to all email addresses listed in MAILLIST and also logged in the database (backupmon.backups) for easier monitoring in MONyog. 

Use the following to create the encryption key file: 
openssl rand -base64 24 <br />
Send output to key file like: <br />
echo -n "openssl_output_here" > /etc/my.cnf.d/xtrabackup.key <br />

Create table for backup logging.  <br />
```
CREATE DATABASE backupmon;
CREATE TABLE backupmon.backups ( 
	id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, 
	created_date DATE, 
	start_time TIME, 
	end_time TIME, 
	source_host VARCHAR(100), 
	location VARCHAR(255), 
	type ENUM('full','incremental'), 
	threads TINYINT, 
	encrypted ENUM('yes','no'), 
	compressed ENUM('yes','no'), 
	size VARCHAR(20), 
	status ENUM('FAILED','SUCCEEDED'), 
	mailed_to VARCHAR(255),
	log_file VARCHAR(255) 
	); 
```

Grant these permissions to the backup user  <br />
```
GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup_user'@'localhost' IDENTIFIED BY 'backup_password';
GRANT INSERT, SELECT ON backupmon.backups TO 'backupmon_user'@'localhost' IDENTIFIED BY 'backupmon_password'; 
FLUSH PRIVILEGES; 
```

Add this info to bottom of /etc/my.cnf (MySQL) or /etc/my.cnf.d/server.cnf (MariaDB):  <br />
```
[mysqlbackupmon] 
user = backupmon_user 
password = backupmon_password 
```

Add this info to bottom of /etc/my.cnf (MySQL) or new /etc/my.cnf.d/xtrabackup.cnf (MariaDB): <br />
```
[xtrabackup]
port = 3306
user = backup_user
password = backup_password
socket = /path/to/socket
datadir = /path/to/datadir
innodb_data_home_dir = /path/to/innodb_data_home_dir
```

Lock down permissions on config file  <br />
```
chown mysql /etc/my.cnf
chmod 600 /etc/my.cnf
```
OR <br />
```
chown mysql /etc/my.cnf.d/xtrabackup.cnf
chmod 600 /etc/my.cnf.d/xtrabackup.cnf
```

Todo: 
- Rewrite. Go?
- Clean up the clean up.
- Add check for [xtrabackup] conf section.
- Change innobackupex command to be dynamic, flags for parallel, compress, galera, slave, etc.
- Add check for backup database user/permissions. Output exact commands needed to fix to log. 
- Add check for db backup tracking table. Output commands to create table. Or create it auto?
- Create a setup script to create key file, user, add [xtrabackup] conf info, etc. 
- Add desync and wsrep_local_recv_queue check for Galera. 
