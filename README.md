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
CREATE DATABASE backupmon; <br />
CREATE TABLE backupmon.backups ( <br />
	id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, <br />
	created_date DATE, <br />
	start_time TIME, <br />
	end_time TIME, <br />
	source_host VARCHAR(100), <br />
	location VARCHAR(255), <br />
	type ENUM('full','incremental'), <br />
	threads TINYINT, <br />
	encrypted ENUM('yes','no'), <br />
	compressed ENUM('yes','no'), <br />
	size VARCHAR(20), <br />
	status ENUM('FAILED','SUCCEEDED'), <br />
	mailed_to VARCHAR(255), <br />
	log_file VARCHAR(255) <br />
	); <br />
```

Grant these permissions to the backup user  <br />
GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup_user'@'localhost' IDENTIFIED BY 'backup_password'; <br />
GRANT INSERT, SELECT ON backupmon.backups TO 'backupmon_user'@'localhost' IDENTIFIED BY 'backupmon_password'; <br />
FLUSH PRIVILEGES; <br />

Add this info to bottom of /etc/my.cnf (MySQL) or /etc/my.cnf.d/server.cnf (MariaDB):  <br />
[mysqlbackupmon]  <br />
user = backupmon_user <br />
password = backupmon_password  <br />

Add this info to bottom of /etc/my.cnf (MySQL) or new /etc/my.cnf.d/xtrabackup.cnf (MariaDB): <br />
[xtrabackup]  <br />
port = 3306  <br />
user = backup_user <br />
password = backup_password  <br />
socket = /path/to/socket <br />
datadir = /path/to/datadir  <br />
innodb_data_home_dir = /path/to/innodb_data_home_dir <br />

Lock down permissions on config file  <br />
chown mysql /etc/my.cnf <br />
chmod 600 /etc/my.cnf <br />
OR <br />
chown mysql /etc/my.cnf.d/xtrabackup.cnf <br />
chmod 600 /etc/my.cnf.d/xtrabackup.cnf <br />


Todo: 
- Rewrite. Go?
- Clean up the clean up.
- Add check for [xtrabackup] conf section.
- Change innobackupex command to be dynamic, flags for parallel, compress, galera, slave, etc.
- Add check for backup database user/permissions. Output exact commands needed to fix to log. 
- Add check for db backup tracking table. Output commands to create table. Or create it auto?
- Create a setup script to create key file, user, add [xtrabackup] conf info, etc. 
- Add desync and wsrep_local_recv_queue check for Galera. 
