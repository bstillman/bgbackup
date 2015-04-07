#!/bin/bash

############################################
# Config

fullbackday=Tuesday				# Day of week to do full backup
keepweek=4					# Number of weeks worth of backups to keep
backupdir=/backups				# Full path to backup directory root
logpath=/var/log                      		# Path to keep logs
cryptkey=/etc/my.cnf.d/backupscript.key		# Full path to encryption key
threads=4					# Used for parallel and compress
encrypt=yes					# To be used later
compress=yes					# To be used later
maillist=ben@mariadb.com			# Comma separated list of email address to be notified.
mailsubpre="[dbhc-mariadb]"			# Email subject prefix

############################################
# Functions

# Mail function
function mail_log {
	mail -s "$mailsubpre $HOSTNAME Backup $log_status $MDATE" $maillist < "$logfile"
	insert_db_stats
}

# Function to check log for okay
function log_check {
	if grep -q 'innobackupex: completed OK' "$logfile" ; then
		log_status=SUCCEEDED
	else
		log_status=FAILED
	fi
}

# Function to find or create backup base directory
function backer_upper {
	if [ "$(date +%A)" = $fullbackday ] && [ ! -d $backupdir/weekof"$(date +%m%d%y)" ]; then
		log_info "Creating backup base directory."
		mkdir -p $backupdir/weekof"$(date +%m%d%y)"
		BACKUPBASEDIR=$backupdir/weekof"$(date +%m%d%y)"
		full_backup
	elif [ "$(date +%A)" = $fullbackday ] && [ -d $backupdir/weekof"$(date +%m%d%y)" ] ; then
		log_info "It is the day scheduled for full backups, but the weekly folder"
		log_info "already exists. Assuming incremental backup. Check config." 
		log_info "Setting backup base directory variable." 
		BACKUPBASEDIR=$backupdir/weekof"$(date +%m%d%y)"
		incremental_backup
	elif [ "$(date +%A)" != $fullbackday ] && [ ! -d $backupdir/weekof"$(date +%m%d%y)" ] ; then
		log_info "It is an incremental backup day, however the weekly folder does"
		log_info "not appear to exist. Please check config."
		log_status=FAILED
		mail_log
		exit
	else
		log_info "Setting backup base directory variable."
		BACKUPBASEDIR=$backupdir/weekof"$(date -dlast-$fullbackday +%m%d%y)"
		incremental_backup
	fi
}

# Full backup function
function full_backup {	
	log_info "Full backup beginning."
	budirdate=$(date +%Y-%m-%d)
	$INNOBACKUPEX --galera-info --parallel=$threads --compress --compress-threads=$threads --encrypt=AES256 --encrypt-key-file=$cryptkey "$BACKUPBASEDIR" 2>> "$logfile"
	log_check
	log_info "Full backup" $log_status
	log_info "CAUTION: ALWAYS VERIFY YOUR BACKUPS."
	butype=full
	budir="$(ls "$BACKUPBASEDIR" | grep "$budirdate" | tail -1)"
	bulocation=$BACKUPBASEDIR/$budir
	xbcrypt -d --encrypt-key-file=$cryptkey --encrypt-algo=AES256 < "$bulocation"/xtrabackup_checkpoints.xbcrypt > "$bulocation"/xtrabackup_checkpoints
	backup_cleanup
	mail_log
}

# Incremental backup function
function incremental_backup {	
	log_info "Incremental backup beginning."
	budirdate=$(date +%Y-%m-%d)
	INCRBASE=$BACKUPBASEDIR/$(ls -tr "$BACKUPBASEDIR" | tail -1)
	$INNOBACKUPEX --galera-info --parallel=$threads --compress --compress-threads=$threads --encrypt=AES256 --encrypt-key-file=$cryptkey --incremental "$BACKUPBASEDIR" --incremental-basedir="$INCRBASE" 2>> "$logfile"
	log_check
	log_info "Incremental backup" $log_status 
	log_info "CAUTION: ALWAYS VERIFY YOUR BACKUPS."
	butype=incremental
	budir="$(ls "$BACKUPBASEDIR" | grep "$budirdate" | tail -1)"
	bulocation=$BACKUPBASEDIR/$budir
	xbcrypt -d --encrypt-key-file=$cryptkey --encrypt-algo=AES256 < "$bulocation"/xtrabackup_checkpoints.xbcrypt > "$bulocation"/xtrabackup_checkpoints
	backup_cleanup
	mail_log
}

# Function to cleanup old backup directories. This is definitely not the best way. 
function backup_cleanup {
	if [ $log_status = SUCCEEDED ] ; then
		TAILNUM=$(($keepweek+1))
		declare -a TO_DELETE=($(ls -ar "$backupdir" | grep weekof | tail -n +"$TAILNUM"))
		if [ ${#TO_DELETE[@]} -gt 1 ] ; then
			log_info "Beginning cleanup of old weekly backup directories."
			for d in "${TO_DELETE[@]}"
			do
				log_info "Deleted backup directory $d"
				rm -Rf "${backupdir}"/"$d"
			done
			log_info "Backup directory cleanup complete."
		else
			log_info "No backup directories to clean."
		fi
	else
		log_info "Backup failed. No old backups deleted at this time."
	fi
}

# Function to insert info into database table for MONyog monitoring
# use dbmon group suffix --defaults-group-suffix=dbmon
function insert_db_stats {
	source_host=$(hostname)
	end_time=$(date +'%T')
	backup_size="$(du -sm "$bulocation" | awk '{print $1}')"
	debugme
	mysql --defaults-group-suffix=backupmon -e "INSERT INTO backupmon.backups (created_date, start_time, end_time, source_host, location, type, threads, encrypted, compressed, size, status, mailed_to, log_file) VALUES ('$created_date', '$start_time', '$end_time', '$source_host', '$bulocation', '$butype', '$threads', '$encrypt', '$compress', '$backup_size', '$log_status', '$maillist', '$logfile');"	
}

# Logging function
function log_info() { 
	printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"; 
}


# Debug variables function
function debugme {
	echo "created_date: " "$created_date"
	echo "start_time: " "$start_time"
	echo "end_time: " "$end_time"
	echo "source_host: " "$source_host"
	echo "budirdate: " "$budirdate"
	echo "budir: " "$budir"
	echo "bulocation: " "$bulocation"
	echo "butype: " "$butype"
	echo "threads: " "$threads"
	echo "encrypt: " "$encrypt"
	echo "compress: " "$compress"
	echo "backup_size: " "$backup_size"
	echo "log_status: " "$log_status"
	echo "maillist: " "$maillist"
	echo "logfile: " "$logfile"
}

############################################
# Begin script 

# Set some specific variables
MDATE=$(date +%m/%d/%y)	# Date for mail subject. Not in function so set at script start time, not when backup is finished.
logfile=$logpath/mariadb_backup_$(date +%Y-%m-%d-%T).log	# logfile
created_date=$(date +'%F')
start_time=$(date +'%T')

# Create log file
touch "$logfile"

log_info "Backup of" "$(hostname)" "beginning."

# Check for xtrabackup
if command -v innobackupex >/dev/null; then
    INNOBACKUPEX=$(command -v innobackupex)
else
   log_info "xtrabackup/innobackupex does not appear to be installed. Please install and try again."
   log_status=FAILED
   mail_log
   exit
fi

backer_upper

exit
