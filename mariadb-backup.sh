#!/bin/bash

############################################
# Config

FULLBACKDAY=Tuesday				# Day of week to do full backup
KEEPWEEK=4					# Number of weeks worth of backups to keep
BACKUPDIR=/backups				# Full path to backup directory root
LOGPATH=/var/log                      		# Path to keep logs
CRYPTKEY=/etc/my.cnf.d/backupscript.key		# Full path to encryption key
THREADS=4					# Used for parallel and compress
ENCRYPT=yes					# To be used later
COMPRESS=yes					# To be used later
MAILLIST=ben@mariadb.com			# Comma separated list of email address to be notified.
MAILSUBPRE=[dbhc-mariadb			# Email subject prefix

############################################
# Functions

# Mail function
function mail_log {
	mail -s "$MAILSUBPRE $HOSTNAME Backup $LOG_STATUS $MDATE" $MAILLIST < $LOGFILE
	insert_db_stats
}

# Function to check log for okay
function log_check {
	if grep -q 'innobackupex: completed OK' $LOGFILE ; then
		LOG_STATUS=SUCCEEDED
	else
		LOG_STATUS=FAILED
	fi
}

# Function to find or create backup base directory
function backer_upper {
	if [ "$(date +%A)" = $FULLBACKDAY ] && [ ! -d $BACKUPDIR/weekof$(date +%m%d%y) ]; then
		echo $(date +%Y-%m-%d-%T) "--> Creating backup base directory." >>$LOGFILE
		mkdir -p $BACKUPDIR/weekof$(date +%m%d%y)
		BACKUPBASEDIR=$BACKUPDIR/weekof$(date +%m%d%y)
		full_backup
	elif [ "$(date +%A)" = $FULLBACKDAY ] && [ -d $BACKUPDIR/weekof$(date +%m%d%y) ] ; then
		echo $(date +%Y-%m-%d-%T) "--> It is the day scheduled for full backups, but the weekly folder" >>$LOGFILE
		echo $(date +%Y-%m-%d-%T) "--> already exists. Assuming incremental backup. Check config." >>$LOGFILE
		echo $(date +%Y-%m-%d-%T) "--> Setting backup base directory variable." >>$LOGFILE
		BACKUPBASEDIR=$BACKUPDIR/weekof$(date +%m%d%y)
		incremental_backup
	elif [ "$(date +%A)" != $FULLBACKDAY ] && [ ! -d $BACKUPDIR/weekof$(date +%m%d%y) ] ; then
		echo $(date +%Y-%m-%d-%T) "--> It is an incremental backup day, however the weekly folder does" >>$LOGFILE
		echo $(date +%Y-%m-%d-%T) "--> not appear to exist. Please check config." >>$LOGFILE
		LOG_STATUS=FAILED
		mail_log
		exit
	else
		echo $(date +%Y-%m-%d-%T) "--> Setting backup base directory variable." >>$LOGFILE
		BACKUPBASEDIR=$BACKUPDIR/weekof$(date -dlast-$FULLBACKDAY +%m%d%y)
		incremental_backup
	fi
}

# Full backup function
function full_backup {	
	echo $(date +%Y-%m-%d-%T) "--> Full backup beginning." >>$LOGFILE
	BUDIRDATE=$(date +%Y-%m-%d)
	$INNOBACKUPEX --galera-info --parallel=$THREADS --compress --compress-threads=$THREADS --encrypt=AES256 --encrypt-key-file=$CRYPTKEY $BACKUPBASEDIR 2>>$LOGFILE
	log_check
	echo $(date +%Y-%m-%d-%T) "--> Full backup" $LOG_STATUS >>$LOGFILE
	echo $(date +%Y-%m-%d-%T) "--> CAUTION: ALWAYS VERIFY YOUR BACKUPS." >>$LOGFILE
	BUTYPE=full
	BUDIR="$(ls $BACKUPBASEDIR | grep $BUDIRDATE | tail -1)"
	BULOCATION=$BACKUPBASEDIR/$BUDIR
	xbcrypt -d --encrypt-key-file=$CRYPTKEY --encrypt-algo=AES256 < $BULOCATION/xtrabackup_checkpoints.xbcrypt > $BULOCATION/xtrabackup_checkpoints
	backup_cleanup
	mail_log
}

# Incremental backup function
function incremental_backup {	
	echo $(date +%Y-%m-%d-%T) "--> Incremental backup beginning." >>$LOGFILE
	BUDIRDATE=$(date +%Y-%m-%d)
	INCRBASE=$BACKUPBASEDIR/$(ls -tr $BACKUPBASEDIR | tail -1)
	$INNOBACKUPEX --galera-info --parallel=$THREADS --compress --compress-threads=$THREADS --encrypt=AES256 --encrypt-key-file=$CRYPTKEY --incremental $BACKUPBASEDIR --incremental-basedir=$INCRBASE 2>>$LOGFILE
	log_check
	echo $(date +%Y-%m-%d-%T) "--> Incremental backup" $LOG_STATUS >>$LOGFILE
	echo $(date +%Y-%m-%d-%T) "--> CAUTION: ALWAYS VERIFY YOUR BACKUPS." >>$LOGFILE
	BUTYPE=incremental
	BUDIR="$(ls $BACKUPBASEDIR | grep $BUDIRDATE | tail -1)"
	BULOCATION=$BACKUPBASEDIR/$BUDIR
	xbcrypt -d --encrypt-key-file=$CRYPTKEY --encrypt-algo=AES256 < $BULOCATION/xtrabackup_checkpoints.xbcrypt > $BULOCATION/xtrabackup_checkpoints
	backup_cleanup
	mail_log
}

# Function to cleanup old backup directories. This is definitely not the best way. 
function backup_cleanup {
	if [ $LOG_STATUS = SUCCEEDED ] ; then
		TAILNUM=$(($KEEPWEEK+1))
		declare -a TO_DELETE=($(ls -ar $BACKUPDIR | grep weekof | tail -n +$TAILNUM))
		if [ ${#TO_DELETE[@]} -gt 1 ] ; then
			echo $(date +%Y-%m-%d-%T) "--> Beginning cleanup of old weekly backup directories." >>$LOGFILE
			for d in "${TO_DELETE[@]}"
			do
				echo $(date +%Y-%m-%d-%T) "--> Deleted backup directory $d" >>$LOGFILE
				rm -Rf $BACKUPDIR/$d
			done
			echo $(date +%Y-%m-%d-%T) "--> Backup directory cleanup complete." >>$LOGFILE
		else
			echo $(date +%Y-%m-%d-%T) "--> No backup directories to clean." >>$LOGFILE
		fi
	else
		echo $(date +%Y-%m-%d-%T) "--> Backup failed. No old backups deleted at this time." >>$LOGFILE
	fi
}

# Function to insert info into database table for MONyog monitoring
# use dbmon group suffix --defaults-group-suffix=dbmon
function insert_db_stats {
	SOURCE_HOST=$(hostname)
	END_TIME=$(date +'%T')
	BACKUP_SIZE="$(du -sm $BULOCATION | awk '{print $1}')"
	debugme
	mysql --defaults-group-suffix=backupmon -e "INSERT INTO backupmon.backups (created_date, start_time, end_time, source_host, location, type, threads, encrypted, compressed, size, status, mailed_to, log_file) VALUES ('$CREATED_DATE', '$START_TIME', '$END_TIME', '$SOURCE_HOST', '$BULOCATION', '$BUTYPE', '$THREADS', '$ENCRYPT', '$COMPRESS', '$BACKUP_SIZE', '$LOG_STATUS', '$MAILLIST', '$LOGFILE');"	
}

# Debug variables function
function debugme {
	echo "CREATED_DATE: " $CREATED_DATE
	echo "START_TIME: " $START_TIME
	echo "END_TIME: " $END_TIME
	echo "SOURCE_HOST: " $SOURCE_HOST
	echo "BUDIRDATE: " $BUDIRDATE
	echo "BUDIR: " $BUDIR
	echo "BULOCATION: " $BULOCATION
	echo "BUTYPE: " $BUTYPE
	echo "THREADS: " $THREADS
	echo "ENCRYPT: " $ENCRYPT
	echo "COMPRESS: " $COMPRESS
	echo "BACKUP_SIZE: " $BACKUP_SIZE
	echo "LOG_STATUS: " $LOG_STATUS
	echo "MAILLIST: " $MAILLIST
	echo "LOGFILE: " $LOGFILE
}

############################################
# Begin script 

# Set some specific variables
MDATE=$(date +%m/%d/%y)	# Date for mail subject. Not in function so set at script start time, not when backup is finished.
LOGFILE=$LOGPATH/mariadb_backup_$(date +%Y-%m-%d-%T).log	# Logfile
CREATED_DATE=$(date +'%F')
START_TIME=$(date +'%T')

# Create log file
touch $LOGFILE

echo $(date +%Y-%m-%d-%T) "--> Backup of" $(hostname) "beginning." >>$LOGFILE

# Check for xtrabackup
if command -v innobackupex >/dev/null; then
    INNOBACKUPEX=$(command -v innobackupex)
else
   echo $(date +%Y-%m-%d-%T) "--> xtrabackup/innobackupex does not appear to be installed. Please install and try again." >>$LOGFILE
   LOG_STATUS=FAILED
   mail_log
   exit
fi

backer_upper

exit
