#!/bin/bash

# bgbackup - A backup shell script for MariaDB, MySQL and Percona
#
# Authors: Ben Stillman <ben@2co.com>, Guillaume Lefranc <guillaume@mariadb.com>
# License: GNU General Public License, version 3.
# Redistribution/Reuse of this code is permitted under the GNU v3 license.
# As an additional term ALL code must carry the original Author(s) credit in comment form.
# See LICENSE in this directory for the integral text.

dir=$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -e "$dir"/bgbackup.cnf ]
then
	source "$dir"/bgbackup.cnf
else
	echo "Error: bgbackup.cnf configuration file not found"
	echo "The configuration file must exist in the same directory where the script is located"
	exit 1
fi

if [ ! -d "$backupdir" ]
then
        echo "Error: $backupdir directory not found"
        echo "The configured directory for backups does not exist. Please create this first"
        exit 1
fi

# Functions

# Mail function
function mail_log {
	mail -s "$mailsubpre $HOSTNAME Backup $log_status $mdate" "$maillist" < "$logfile"
}

# Function to check log for okay
function log_check {
	if grep -Eq 'completed OK!$' "$logfile" ; then
		log_status=SUCCEEDED
	else
		log_status=FAILED
	fi
}

# Logging function
function log_info() {
    if [ "$verbose" == "no" ]; then
    	printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"
    else
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" | tee "$logfile"
    fi
}

# Function to create innobackupex command
function innocreate {
	mhost=$(hostname)
	innocommand="$innobackupex"
	if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
    	if [[ "$(date +%A)" = "$fullbackday" || "$fullbackday" = "Always" ]] ; then
    		butype=Full
    		dirname="$backupdir/full-$(date +%Y-%m-%d_%H-%M-%S)"
    		innocommand=$innocommand" $dirname --no-timestamp --history=$mhost"
    	else
    		butype=Incremental
    		dirname="$backupdir/incr-$(date +%Y-%m-%d_%H-%M-%S)"
    		innocommand=$innocommand" $dirname --no-timestamp --history=$mhost --incremental --incremental-history-name=$mhost"
	    fi
	elif [ "$bktype" = "archive" ] ; then
	   	if [ "$(date +%A)" = "$fullbackday" ] ; then
    		butype=Full
    		innocommand=$innocommand" /tmp --stream=$arctype --no-timestamp --history=$mhost"
    		arcname="$backupdir/full-$(date +%Y-%m-%d_%H-%M-%S).$arctype.gz"
    	else
    		butype=Incremental
    		innocommand=$innocommand" /tmp --stream=$arctype --no-timestamp --history=$mhost --incremental --incremental-history-name=$mhost"
    		arcname="$backupdir/inc-$(date +%Y-%m-%d_%H-%M-%S).$arctype.gz"
	    fi
	fi
	if [ -n "$databases" ] && [ "$bktype" = "prepared-archive" ]; then innocommand=$innocommand" --databases=$databases"; fi
	[ ! -z "$backupuser" ] && innocommand=$innocommand" --user=$backupuser"
	[ ! -z "$backuppass" ] && innocommand=$innocommand" --password=$backuppass"
        [ ! -z "$host" ] && innocommand=$innocommand" --host=$host"
        [ ! -z "$hostport" ] && innocommand=$innocommand" --port=$hostport"
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
	xbcrypt -d --encrypt-key-file="$cryptkey" --encrypt-algo=AES256 < "$budir"/xtrabackup_checkpoints.xbcrypt > "$budir"/xtrabackup_checkpoints
}

# Function to disable/enable MONyog alerts
function monyog {
	curl "${monyoghost}:${monyogport}/?_object=MONyogAPI&_action=Alerts&_value=${1}&_user=${monyoguser}&_password=${monyogpass}&_server=${monyogserver}"
}

# Function to do the backup
function backer_upper {
	innocreate
	if [ "$monyog" = yes ] ; then
		log_info "Disabling MONyog alerts"
		monyog disable
		sleep 30
	fi
	if [ "$galera" = yes ] ; then
		log_info "Enabling WSREP desync."
		mysql -u "$backupuser" -p"$backuppass" -e "SET GLOBAL wsrep_desync=ON;"
	fi
	log_info "Beginning ${butype} Backup"
	if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
    	$innocommand 2>> "$logfile"
	    log_check
	    if [ "$encrypt" = yes ] && [ "$log_status" = "SUCCEEDED" ] ; then 
	    	checkpointsdecrypt
	    fi
	fi
	if [ "$bktype" = "archive" ] ; then
	    $innocommand 2>> "$logfile" | $computil -c > "$arcname"
	    log_check
	fi
	if [ "$galera" = yes ] ; then
		log_info "Disabling WSREP desync."
		until [ "$queue" -eq 0 ]; do
    		queue=$(mysql -u "$backupuser" -p"$backuppass" -ss -e "show global status like 'wsrep_local_recv_queue';" | awk '{ print $2 }')
    		sleep 10
		done
		mysql -u "$backupuser" -p"$backuppass" -e "SET GLOBAL wsrep_desync=OFF;"
	fi
	if [ "$monyog" = yes ] ; then
		log_info "Enabling MONyog alerts"
		monyog enable
		sleep 30
	fi
	backup_prepare
	log_info "$butype backup $log_status"
	log_info "CAUTION: ALWAYS VERIFY YOUR BACKUPS."
}

# Function to prepare backup
function backup_prepare {
    if [ $bktype == "prepared-archive" ]; then
        prepcommand="$innobackupex $dirname --apply-log"
        if [ -n $databases ]; then prepcommand=$prepcommand" --export"; fi
        log_info "Preparing backup."
        $prepcommand 2>> "$logfile"
        log_check
        log_info "Backup prepare complete."
        log_info "Archiving backup."
        tar cf "$dirname.tar.gz" -C "$dirname" -I "$computil" . && rm -rf "$dirname"
        log_info "Archiving complete."
    fi
}
        
# Function to cleanup old backups.
function backup_cleanup {
	if [ $log_status = "SUCCEEDED" ] ; then
		firstfulldel=$(find "$backupdir" -name 'full-*' -mtime +"$keepday" | sort -r | head -n 1)
		deldate=$(stat -c %y "$firstfulldel" | awk '{print $1}')
		declare -a TO_DELETE=($(find "$backupdir" -maxdepth 1 -name 'full*' -o -name 'incr*' -not -newermt "$deldate"))
		if [ ${#TO_DELETE[@]} -gt 1 ] ; then
			log_info "Beginning cleanup of old backups."
			for d in "${TO_DELETE[@]}"
			do
				log_info "Deleted backup $d"
				rm -Rf "${backupdir:?}"/"$d"
			done
			log_info "Backup cleanup complete."
		else
			log_info "No backups to clean."
		fi
	else
		log_info "Backup failed. No old backups deleted at this time."
	fi
}

# Function to check config parameters
function config_check {
    if [[ "$bktype" = "archive" || "$bktype" = "prepared-archive" ]] && [ "$compress" = "yes" ] ; then
        log_info "Archive backup type selected, disabling built-in compression."
        compress="no"
    fi
    if [[ "$computil" != "gzip" && "$computil" != "pigz" ]]; then
        verbose="yes"
        log_info "Fatal: $computil compression method is unsupported."
        exit 1
    fi
}

# Debug variables function
function debugme {
	echo "host: " "$host"
	echo "hostport: " "$hostport"
	echo "backupuser: " "$backupuser"
	echo "backuppass: " "$backuppass"
	echo "bktype: " "$bktype"
	echo "arctype: " "$arctype"
	echo "monyog: " "$monyog"
	echo "monyogserver: " "$monyogserver"
	echo "monyoguser: " "$monyoguser"
	echo "monyogpass: " "$monyogpass"
	echo "monyoghost: " "$monyoghost"
	echo "monyogport: " "$monyogport"
	echo "fullbackday: " "$fullbackday"
	echo "keepday: " "$keepday"
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
	echo "innocommand: " "$innocommand"
	echo "prepcommand: " "$prepcommand"
	echo "dirname: " "$dirname"
	echo "mhost: " "$mhost"
	echo "budir: " "$budir"
}

############################################
# Begin script

# Set some specific variables
mdate=$(date +%m/%d/%y)	# Date for mail subject. Not in function so set at script start time, not when backup is finished.
logfile=$logpath/bgbackup_$(date +%Y-%m-%d-%T).log	# logfile

# Check for xtrabackup
if command -v innobackupex >/dev/null; then
    innobackupex=$(command -v innobackupex)
else
    log_info "xtrabackup/innobackupex does not appear to be installed. Please install and try again."
    log_status=FAILED
    mail_log
    exit
fi

config_check # Check vital configuration parameters

backer_upper # Execute the backup. 

backup_cleanup # Cleanup old backups. 

if [ "$log_status" = "FAILED" ] || [ "$mailonsuccess" = "yes" ] ; then
    mail_log # Mail results to maillist.
fi

#debugme	# Comment out to disable listing of all variables.

exit
