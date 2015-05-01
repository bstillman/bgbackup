#!/bin/bash

############################################
# Config

backupuser=testuser                      # MySQL backup username
backuppass=testpass                      # MySQL backup user password
monyog=yes                               # If server monitored by MONyog, should we disable alerts?
monyogserver=db-server-3                 # The name of the server as setup in MONyog
monyoguser=admin                         # MONyog username
monyogpass=password                      # MONyog password
monyoghost=192.168.0.230                 # MONyog host/ip
monyogport=5555                          # MONyog port
fullbackday=Wednesday                    # Day of week to do full backup
keepweek=4                               # Number of weeks worth of backups to keep
backupdir=/backups                       # Full path to backup directory root
logpath=/var/log                         # Path to keep logs
threads=4                                # Used for parallel and compress
parallel=yes                             # Use parallel threads for backup?
encrypt=yes                              # Encrypt backup?
cryptkey=/etc/my.cnf.d/backupscript.key  # Full path to encryption key
compress=yes                             # Compress backup?
galera=yes                               # Include Galera info?
slave=no                                 # Include slave info? 
maillist=ben@mariadb.com                 # Comma separated list of email address to be notified.
mailsubpre="[dbhc-mariadb]"              # Email subject prefix

############################################

# Functions

# Mail function
function mail_log {
	mail -s "$mailsubpre $HOSTNAME Backup $log_status $mdate" $maillist < "$logfile"
}

# Function to check log for okay
function log_check {
	if grep -q 'innobackupex: completed OK' "$logfile" ; then
		log_status=SUCCEEDED
	else
		log_status=FAILED
	fi
}

# Logging function
function log_info() {
	printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile";
}

# Function to create innobackupex command
function innocreate {
	mhost=$(hostname)
	innocommand="$innobackupex $backupdir --history=$mhost"
	if [ "$(date +%A)" = $fullbackday ] ; then
		butype=Full
	else
		butype=Incremental
		innocommand=$innocommand" --incremental --incremental-history-name=$mhost"
	fi
	[ ! -z "$backupuser" ] && innocommand=$innocommand" --user=$backupuser"
	[ ! -z "$backuppass" ] && innocommand=$innocommand" --password=$backuppass"
	if [ "$galera" = yes ] ; then innocommand=$innocommand" --galera-info" ; fi
	if [ "$slave" = yes ] ; then innocommand=$innocommand" --slave-info" ; fi
	if [ "$parallel" = yes ] ; then innocommand=$innocommand" --parallel=$threads" ; fi
	if [ "$compress" = yes ] ; then innocommand=$innocommand" --compress --compress-threads=$threads" ; fi
	if [ "$encrypt" = yes ] ; then innocommand=$innocommand" --encrypt=AES256 --encrypt-key-file=$cryptkey" ; fi
}

# Function to decrypt xtrabackup_checkpoints 
function checkpointsdecrypt {
	budirdate=$(date +%Y-%m-%d)
	files=("$backupdir"/"$budirdate"*); budir=${files[${#files[@]} -1 ]}
	xbcrypt -d --encrypt-key-file=$cryptkey --encrypt-algo=AES256 < "$budir"/xtrabackup_checkpoints.xbcrypt > "$budir"/xtrabackup_checkpoints
}

# Function to do the backup
function backer_upper {
	if [ "$monyog" = yes ] ; then
		log_info "Disabling MONyog alerts"
		curl "$monyoghost:$monyogport/?_object=MONyogAPI&_action=Alerts&_value=disable&_user=$monyoguser&_password=$monyogpass&_server=$monyogserver"
		sleep 30
	fi
	if [ "$galera" = yes ] ; then
		log_info "Enabling WSREP desync."
		mysql -u $backupuser -p $backuppass -e "SET GLOBAL wsrep_desync=ON;"
	fi
	log_info "Beginning $butype Backup"
	$innocommand 2>> "$logfile"
	if [ "$encrypt" = yes ] ; then 
		checkpointsdecrypt
	fi
	if [ "$galera" = yes ] ; then
		log_info "Disabling WSREP desync."
		# wsrep_local_recv_queue
		until [ "$queue" -eq 0 ]; do
    		queue=$(mysql -u $backupuser -p $backuppass -ss -e "show global status like 'wsrep_local_recv_queue';" | awk '{ print $2 }')
    		sleep 10
		done
		mysql -u $backupuser -p $backuppass -e "SET GLOBAL wsrep_desync=OFF;"
	fi
	if [ "$monyog" = yes ] ; then
		log_info "Disabling MONyog alerts"
		curl "${monyoghost}:${monyogport}/?_object=MONyogAPI&_action=Alerts&_value=enable&_user=${monyoguser}&_password=${monyogpass}&_server=${monyogserver}"
		sleep 30
	fi
	log_check
	log_info "$butype backup $log_status"
	log_info "CAUTION: ALWAYS VERIFY YOUR BACKUPS."
}

# Function to cleanup old backups.
function backup_cleanup {
	#...
	true
}

# Debug variables function
function debugme {
	echo "backupuser: " "$backupuser"
	echo "backuppass: " "$backuppass"
	echo "monyog: " "$monyog"
	echo "monyogserver: " "$monyogserver"
	echo "monyoguser: " "$monyoguser"
	echo "monyogpass: " "$monyogpass"
	echo "monyoghost: " "$monyoghost"
	echo "monyogport: " "$monyogport"
	echo "fullbackday: " "$fullbackday"
	echo "keepweek: " "$keepweek"
	echo "backupdir: " "$backupdir"
	echo "logpath: " "$logpath"
	echo "threads: " "$threads"
	echo "parallel: " "$parallel"
	echo "encrypt: " "$encrypt"
	echo "cryptkey: " "$cryptkey"
	echo "compress: " "$compress"
	echo "galera: " "$galera"
	echo "slave: " "$slave"
	echo "maillist: " "$maillist"
	echo "mailsubpre: " "$mailsubpre"
	echo "mdate: " "$mdate"
	echo "logfile: " "$logfile"
	echo "queue: " "$queue"
	echo "butype: " "$butype"
	echo "log_status: " "$log_status"
	echo "budirdate: " "$budirdate"	
}

############################################
# Begin script

# Set some specific variables
mdate=$(date +%m/%d/%y)	# Date for mail subject. Not in function so set at script start time, not when backup is finished.
logfile=$logpath/mariadb_backup_$(date +%Y-%m-%d-%T).log	# logfile

# Check for xtrabackup
if command -v innobackupex >/dev/null; then
    innobackupex=$(command -v innobackupex)
else
   log_info "xtrabackup/innobackupex does not appear to be installed. Please install and try again."
   log_status=FAILED
   mail_log
   exit
fi

backer_upper # Execute the backup. 

backup_cleanup # Cleanup old backups. 

mail_log # Mail results to maillist.

debugme	# Comment out to disable listing of all variables.

exit