#!/bin/bash

# bgbackup - A backup shell script for MariaDB, MySQL and Percona
#
# Authors: Ben Stillman <ben@mariadb.com>, Guillaume Lefranc <guillaume@signal18.io>
# License: GNU General Public License, version 3.
# Redistribution/Reuse of this code is permitted under the GNU v3 license.
# As an additional term ALL code must carry the original Author(s) credit in comment form.
# See LICENSE in this directory for the integral text.



# Functions

# Handle control-c
function sigint {
  echo "SIGINT detected. Exiting"
  if [ "$galera" = yes ] ; then
      log_info "Disabling WSREP desync on exit"
      mysql -u "$backupuser" -p"$backuppass" -e "SET GLOBAL wsrep_desync=OFF;"
  fi
  # 130 is the standard exit code for SIGINT
  exit 130
}

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
    if [ "$verbose" == "no" ] ; then
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" >>"$logfile"
    else
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" | tee -a "$logfile"
    fi
    if [ "$syslog" = yes ] ; then
        logger -p local0.notice -t bgbackup "$*"
    fi
}

# Function to create innobackupex command
function innocreate {
    mhost=$(hostname)
    innocommand="$innobackupex"
    dirdate=$(date +%Y-%m-%d_%H-%M-%S)
    alreadyfullcmd=$mysqlcommand" \"SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE DATE(end_time) = CURDATE() AND butype = 'Full' AND status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at = 0 \" "
    alreadyfull=$(eval "$alreadyfullcmd")
    anyfullcmd=$mysqlcommand" \"SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE butype = 'Full' AND status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at = 0 \" "
    anyfull=$(eval "$anyfullcmd")
    if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
        if ( ( [ "$(date +%A)" = "$fullbackday" ] || [ "$fullbackday" = "Everyday" ]) && [ "$alreadyfull" -eq 0 ] ) || [ "$anyfull" -eq 0 ] ; then
            butype=Full
            dirname="$backupdir/full-$dirdate"
            innocommand=$innocommand" --backup --target-dir $dirname --no-timestamp"
        else
            if [ "$differential" = yes ] ; then
                butype=Differential
                diffbasecmd=$mysqlcommand" \"SELECT bulocation FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND hostname = '$mhost' AND butype = 'Full' AND deleted_at = 0 ORDER BY start_time DESC LIMIT 1\" "
                diffbase=$(eval "$diffbasecmd")
                dirname="$backupdir/diff-$dirdate"
                innocommand=$innocommand" --backup --target-dir $dirname --no-timestamp --incremental --incremental-basedir=$diffbase"
            else
                butype=Incremental
                incbasecmd=$mysqlcommand" \"SELECT bulocation FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at = 0 ORDER BY start_time DESC LIMIT 1\" "
                incbase=$(eval "$incbasecmd")
                dirname="$backupdir/incr-$dirdate"
                innocommand=$innocommand" --backup --target-dir $dirname --no-timestamp --incremental --incremental-basedir=$incbase"
            fi
        fi
    elif [ "$bktype" = "archive" ] ; then

        [ ! -d $backupdir/.lsn ] && mkdir $backupdir/.lsn
        [ ! -d $backupdir/.lsn_full ] && mkdir $backupdir/.lsn_full

	#if tempfolder is not set then  use /tmp
	if [ -z "$tempfolder" ]	
         then
   		tempfolder=/tmp
	fi
 
	# verify the tempfolder directory exists
	if [ ! -d "$tempfolder" ]
	then
    		log_info "Error: $tempfolder  directory not found"
    		log_info "The configured directory for tempfolders does not exist. Please create this first."
    		log_status=FAILED
    		mail_log
    		exit 1
	fi

	# verify user running script has permissions needed to write to tempfolder  directory
	if [ ! -w "$tempfolder" ]; then
    		log_info "Error: $tempfolder  directory is not writable."
    		log_info "Verify the user running this script has write access to the configured tempfolder directory."
    		log_status=FAILED
    		mail_log
    		exit 1
	fi


        if [ "$(date +%A)" = "$fullbackday" ] || [ "$fullbackday" = "Everyday" ] ; then
            butype=Full
            innocommand=$innocommand" $tempfolder --stream=$arctype --no-timestamp --extra-lsndir=$backupdir/.lsn_full"
            arcname="$backupdir/full-$dirdate.$arctype.gz"
        else
            if [ "$differential" = yes ] ; then
                butype=Differential
                innocommand=$innocommand" $tempfolder --stream=$arctype --no-timestamp --incremental --incremental-basedir=$backupdir/.lsn_full --extra-lsndir=$backupdir/.lsn"
                arcname="$backupdir/diff-$dirdate.$arctype.gz"
            else
                butype=Incremental
                innocommand=$innocommand" $tempfolder --stream=$arctype --no-timestamp --incremental --incremental-basedir=$backupdir/.lsn --extra-lsndir=$backupdir/.lsn"
                arcname="$backupdir/inc-$dirdate.$arctype.gz"
            fi
        fi
    fi
    if [ -n "$databases" ] && [ "$bktype" = "prepared-archive" ]; then innocommand=$innocommand" --databases=$databases"; fi
    [ ! -z "$backupuser" ] && innocommand=$innocommand" --user=$backupuser"
    [ ! -z "$backuppass" ] && innocommand=$innocommand" --password=$backuppass"
    [ ! -z "$socket" ] && innocommand=$innocommand" --socket=$socket"
    [ ! -z "$host" ] && innocommand=$innocommand" --host=$host"
    [ ! -z "$hostport" ] && innocommand=$innocommand" --port=$hostport"
    if [ "$galera" = yes ] ; then innocommand=$innocommand" --galera-info" ; fi
    if [ "$slave" = yes ] ; then innocommand=$innocommand" --slave-info" ; fi
    if [ "$parallel" = yes ] ; then innocommand=$innocommand" --parallel=$threads" ; fi
    if [ "$compress" = yes ] ; then innocommand=$innocommand" --compress --compress-threads=$threads" ; fi
    if [ "$encrypt" = yes ] ; then innocommand=$innocommand" --encrypt=AES256 --encrypt-key-file=$cryptkey" ; fi
    if [ "$nolock" = yes ] ; then innocommand=$innocommand" --no-lock" ; fi
    if [ "$nolock" = yes ] && [ "$slave" = yes ] ; then innocommand=$innocommand" --safe-slave-backup" ; fi
}

# Function to decrypt xtrabackup_checkpoints
function checkpointsdecrypt {
    xbcrypt -d --encrypt-key-file="$cryptkey" --encrypt-algo=AES256 < "$dirname"/xtrabackup_checkpoints.xbcrypt > "$dirname"/xtrabackup_checkpoints
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
    log_info "Executing xtrabackup command: $(echo "$innocommand" | sed -e 's/password=.* /password=XXX /g')"
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
        queue=1
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
    if [ "$log_status" = "SUCCEEDED" ] && [ "$bktype" == "prepared-archive" ] ; then
        backup_prepare
    fi
    log_info "$butype backup $log_status"
    log_info "CAUTION: ALWAYS VERIFY YOUR BACKUPS."
}

# Function to prepare backup
function backup_prepare {
    prepcommand="$innobackupex $dirname --apply-log"
    if [ -n "$databases" ]; then prepcommand=$prepcommand" --export"; fi
    log_info "Preparing backup."
    $prepcommand 2>> "$logfile"
    log_check
    log_info "Backup prepare complete."
    log_info "Archiving backup."
    tar cf "$dirname.tar.gz" -C "$dirname" -I "$computil" . && rm -rf "$dirname"
    log_info "Archiving complete."
}

# Function to build mysql command
function mysqlcreate {
    mysql=$(command -v mysql)
    mysqlcommand="$mysql"
    mysqlcommand=$mysqlcommand" -u $backuphistuser"
    mysqlcommand=$mysqlcommand" -p$backuphistpass"
    mysqlcommand=$mysqlcommand" -h $backuphisthost"
    [ -n "$backuphistport" ] && mysqlcommand=$mysqlcommand" -P $backuphistport"
    mysqlcommand=$mysqlcommand" -Bse "
}

# Function to build mysqldump command
function mysqldumpcreate {
    mysqldump=$(command -v mysqldump)
    mysqldumpcommand="$mysqldump"
    mysqldumpcommand=$mysqldumpcommand" -u $backuphistuser"
    mysqldumpcommand=$mysqldumpcommand" -p$backuphistpass"
    mysqldumpcommand=$mysqldumpcommand" -h $backuphisthost"
    [ -n "$backuphistport" ] && mysqldumpcommand=$myslqdumpcommand" -P $backuphistport"
    mysqldumpcommand=$mysqldumpcommand" $backuphistschema"
    mysqldumpcommand=$mysqldumpcommand" backup_history"
}

# Function to create backup_history table if not exists
function create_history_table {
    createtable=$(cat <<EOF
CREATE TABLE IF NOT EXISTS $backuphistschema.backup_history (
uuid varchar(40) NOT NULL,
hostname varchar(100) DEFAULT NULL,
start_time timestamp NULL DEFAULT NULL,
end_time timestamp NULL DEFAULT NULL,
bulocation varchar(255) DEFAULT NULL,
logfile varchar(255) DEFAULT NULL,
status varchar(25) DEFAULT NULL,
butype varchar(20) DEFAULT NULL,
bktype varchar(20) DEFAULT NULL,
arctype varchar(20) DEFAULT NULL,
compressed varchar(5) DEFAULT NULL,
encrypted varchar(5) DEFAULT NULL,
cryptkey varchar(255) DEFAULT NULL,
galera varchar(5) DEFAULT NULL,
slave varchar(5) DEFAULT NULL,
threads tinyint(2) DEFAULT NULL,
xtrabackup_version varchar(120) DEFAULT NULL,
server_version varchar(50) DEFAULT NULL,
backup_size varchar(20) DEFAULT NULL,
deleted_at timestamp NULL DEFAULT NULL,
PRIMARY KEY (uuid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8
EOF
)
    $mysqlcommand "$createtable" >> "$logfile"
    log_info "backup history table created"
}

# Function to check if Percona backup history records exist and need migrated
function check_migrate {
    perconacnt=$($mysqlcommand "SELECT COUNT(a.uuid) FROM PERCONA_SCHEMA.xtrabackup_history a LEFT JOIN $backuphistschema.backup_history b ON a.uuid = b.uuid WHERE b.uuid IS NULL;")
    if [ "$perconacnt" -gt 0 ];
    then
        log_info "$perconacnt Percona backup history records not migrated. Migrating."
        migrate
    fi
}

# Function to migrate percona backup history records
function migrate {
    migratesql=$(cat <<EOF
INSERT INTO $backuphistschema.backup_history (
  uuid,
  hostname,
  start_time,
  end_time,
  bulocation,
  status,
  butype,
  compressed,
  encrypted,
  xtrabackup_version
  )
SELECT
  uuid,
  name,
  start_time,
  end_time,
  SUBSTRING_INDEX(SUBSTRING_INDEX(tool_command, ' ', 1), ' ', -1) as backupdirV,
  CASE
    WHEN partial = 'N' THEN 'SUCCEEDED'
    ELSE 'FAILED'
    END AS statusV,
  CASE
    WHEN incremental = 'Y' THEN 'Incremental'
    WHEN incremental = 'N' THEN 'Full'
    ELSE null
    END AS butypeV,
  compressed,
  encrypted,
  concat('MIGRATED FROM PERCONA_SCHEMA - ',tool_version)
FROM PERCONA_SCHEMA.xtrabackup_history
EOF
)
    $mysqlcommand "$migratesql" >> "$logfile"

    $mysqlcommand "SELECT uuid, bulocation FROM $backuphistschema.backup_history WHERE deleted_at IS NULL" |
        while read -r uuid bulocation; do
        if test -d "$bulocation"
        then
            $mysqlcommand "UPDATE $backuphistschema.backup_history SET deleted_at = '0000-00-00 00:00:00' WHERE uuid = '$uuid' "
        else
            $mysqlcommand "UPDATE $backuphistschema.backup_history SET deleted_at = NOW() WHERE uuid = '$uuid' "
        fi
    done



    lefttomigratecnt=$($mysqlcommand "SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE deleted_at IS NULL")
    if [ "$lefttomigratecnt" -gt 0 ];
    then
        log_info "Something went wrong, some migrated records not updated correctly."
        exit 1
    else
        log_info "$perconacnt Percona backup history records migrated."
    fi

}

# Function to write backup history to database
function backup_history {
    versioncommand=$mysqlcommand" \"SELECT @@version\" "
    server_version=$(eval "$versioncommand")
    xtrabackup_version=$(($innobackupex -version) 2>&1)
    if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
        backup_size=$(du -sm "$dirname" | awk '{ print $1 }')"M"
        bulocation="$dirname"
    elif [ "$bktype" = "archive" ] ; then
        backup_size=$(du -sm "$arcname" | awk '{ print $1 }')"M"
        bulocation="$arcname"
    fi
    historyinsert=$(cat <<EOF
INSERT INTO $backuphistschema.backup_history (uuid, hostname, start_time, end_time, bulocation, logfile, status, butype, bktype, arctype, compressed, encrypted, cryptkey, galera, slave, threads, xtrabackup_version, server_version, backup_size, deleted_at)
VALUES (UUID(), "$mhost", "$starttime", "$endtime", "$bulocation", "$logfile", "$log_status", "$butype", "$bktype", "$arctype", "$compress", "$encrypt", "$cryptkey", "$galera", "$slave", "$threads", "$xtrabackup_version", "$server_version", "$backup_size", 0)
EOF
)
    $mysqlcommand "$historyinsert"
    #verify insert
    verifyinsert=$($mysqlcommand "select count(*) from $backuphistschema.backup_history where hostname='$mhost' and end_time='$endtime'")
    if [ "$verifyinsert" -eq 1 ]; then
        log_info "Backup history database record inserted successfully."
    else
        echo "Backup history database record NOT inserted successfully!"
        log_info "Backup history database record NOT inserted successfully!"
        log_status=FAILED
        mail_log
        exit 1
    fi
}

# Function to cleanup backups.
function backup_cleanup {
    if [ $log_status = "SUCCEEDED" ]; then
        limitoffset=$((keepnum-1))
        delcountcmd=$mysqlcommand" \"SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE end_time < (SELECT end_time FROM $backuphistschema.backup_history WHERE butype = 'Full' ORDER BY end_time DESC LIMIT $limitoffset,1) AND hostname = '$mhost' AND status = 'SUCCEEDED' AND deleted_at = 0\" "
        delcount=$(eval "$delcountcmd")
        if [ "$delcount" -gt 0 ]; then
            deletecmd=$mysqlcommand" \"SELECT bulocation FROM $backuphistschema.backup_history WHERE end_time < (SELECT end_time FROM $backuphistschema.backup_history WHERE butype = 'Full' ORDER BY end_time DESC LIMIT $limitoffset,1) AND hostname = '$mhost' AND status = 'SUCCEEDED' AND deleted_at = 0\" "
            eval "$deletecmd" | while read -r todelete; do
                log_info "Deleted backup $todelete"
                markdeletedcmd=$mysqlcommand" \"UPDATE $backuphistschema.backup_history SET deleted_at = NOW() WHERE bulocation = '$todelete' AND hostname = '$mhost' AND status = 'SUCCEEDED' \" "
                rm -Rf "$todelete"
                eval "$markdeletedcmd"
            done
        else
            log_info "No backups to delete at this time."
        fi
    else
        log_info "Backup failed. No backups deleted at this time."
    fi
}

# Function to dump $backuphistschema schema
function mdbutil_backup {
    if [ $backuphistschema != "" ] &&  [ $log_status = "SUCCEEDED" ]; then
        mysqldumpcreate
        mdbutildumpfile="$backupdir"/"$backuphistschema".backup_history-"$dirdate".sql
        $mysqldumpcommand > "$mdbutildumpfile"
        log_info "Backup history table dumped to $mdbutildumpfile"
    fi
}

# Function to cleanup mdbutil backups
function mdbutil_backup_cleanup {
    if [ $log_status = "SUCCEEDED" ]; then
        delbkuptbllist=$(ls -tp "$backupdir" | grep "$backuphistschema".backup_history | tail -n +$((keepbkuptblnum+=1)))
        for bkuptbltodelete in $delbkuptbllist; do
            rm -f "$backupdir"/"$bkuptbltodelete"
            log_info "Deleted backup history backup $bkuptbltodelete"
        done
    else
        log_info "Backup failed. No backup history backups deleted at this time."
    fi
}

# Function to check config parameters
function config_check {
    if [[ "$bktype" = "archive" || "$bktype" = "prepared-archive" ]] && [ "$compress" = "yes" ] ; then
        log_info "Archive backup type selected, disabling built-in compression."
        compress="no"
    fi
    if [[ "$computil" != "gzip" && "$computil" != "pigz"* ]] && [ "$bktype" = "archive" ]; then
        verbose="yes"
        log_info "Fatal: $computil compression method is unsupported."
        log_status=FAILED
        mail_log
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
    echo "nolock: " "$nolock"
    echo "compress: " "$compress"
    echo "tempfolder: " "$tempfolder"
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
    echo "run_after_success: " "$run_after_success"
    echo "run_after_fail: " "$run_after_fail"
}

############################################
# Begin script

# we trap control-c
trap sigint INT

# find and source the config file
etccnf=$( find /etc -name bgbackup.cnf )
scriptdir=$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -e "$etccnf" ]; then
    source "$etccnf"
elif [ -e "$scriptdir"/bgbackup.cnf ]; then
    source "$scriptdir"/bgbackup.cnf
else
    echo "Error: bgbackup.cnf configuration file not found"
    echo "The configuration file must exist somewhere in /etc or"
    echo "in the same directory where the script is located"
    exit 1
fi

if [ ! -d "$logpath" ]; then
    echo "Error: Log dir $logpath not found"
    exit 1
fi

if [ ! -w "$logpath" ]; then
    echo "Error: Log dir $logpath not writeable"
    exit 1
fi

# Set some specific variables
starttime=$(date +"%Y-%m-%d %H:%M:%S")
mdate=$(date +%m/%d/%y)    # Date for mail subject. Not in function so set at script start time, not when backup is finished.
logfile=$logpath/bgbackup_$(date +%Y-%m-%d-%T).log    # logfile


# verify the backup directory exists
if [ ! -d "$backupdir" ]
then
    log_info "Error: $backupdir directory not found"
    log_info "The configured directory for backups does not exist. Please create this first."
    log_status=FAILED
    mail_log
    exit 1
fi

# verify user running script has permissions needed to write to backup directory
if [ ! -w "$backupdir" ]; then
    log_info "Error: $backupdir directory is not writable."
    log_info "Verify the user running this script has write access to the configured backup directory."
    log_status=FAILED
    mail_log
    exit 1
fi


# Check for mariabackup or xtrabackup
if [ "$backuptool" == "1" ] && command -v mariabackup >/dev/null; then
    innobackupex=$(command -v mariabackup)
    compress="no"
elif [ "$backuptool" == "2" ] && command -v innobackupex >/dev/null; then
    innobackupex=$(command -v innobackupex)
else
    echo "The backuptool does not appear to be installed. Please check that a valid backuptool is chosen in bgbackup.cnf and that it's installed."
    log_info "The backuptool does not appear to be installed. Please check that a valid backuptool is chosen in bgbackup.cnf and that it's installed."
    log_status=FAILED
    mail_log
    exit 1
fi

# Check that we are not already running

lockfile=/tmp/bgbackup.lock
if [ -f $lockfile ]
then
    log_info "Another instance of bgbackup is already running. Exiting."
    log_status=FAILED
    mail_log
    exit 1
fi
trap 'rm -f $lockfile' 0
touch $lockfile

mysqlcreate

# Check that mysql client can connect
$mysqlcommand "SELECT 1 FROM DUAL" 1>/dev/null
if [ "$?" -eq 1 ]; then
  log_info "Error: mysql client is unable to connect with the information you have provided. Please check your configuration and try again."
  log_status=FAILED
  mail_log
  exit 1
fi

# Check that the database exists before continuing further
$mysqlcommand "USE $backuphistschema"
if [ "$?" -eq 1 ]; then
    echo "Error: The database '$backuphistschema' containing the history does not exist. Please check your configuration and try again."
    log_info "Error: The database '$backuphistschema' containing the history does not exist. Please check your configuration and try again."
    log_status=FAILED
    mail_log
    exit 1
else
    $mysqlcommand "USE $backuphistschema"
fi

check_table=$($mysqlcommand "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$backuphistschema' AND table_name='backup_history' ")
if [ "$check_table" -eq 0 ]; then
    create_history_table # Create history table if it doesn't exist
fi

if [ "$checkmigrate" = yes ] ; then
    check_migrate # Check if Percona backup history records exist and migrate if needed
fi

config_check # Check vital configuration parameters

backer_upper # Execute the backup.

backup_cleanup # Cleanup old backups.

endtime=$(date +"%Y-%m-%d %H:%M:%S")

backup_history

mdbutil_backup

mdbutil_backup_cleanup

if ( [ "$log_status" = "FAILED" ] && [ "$mailon" = "failure" ] ) || [ "$mailon" = "all" ] ; then
    mail_log # Mail results to maillist.
fi

# run commands after backup, eventually
if [ "$log_status" = "SUCCEEDED" ] && [ ! -z "$run_after_success" ] ; then
    $run_after_success # run the command if backup was successful
elif [ "$log_status" = "FAILED" ] && [ ! -z "$run_after_fail" ] ; then
    $run_after_fail # run the command if backup had failed
fi

if [ "$debug" = yes ] ; then
    debugme
fi

exit
