#!/bin/bash

# bgbackup - A backup shell script for MariaDB, MySQL and Percona
#
# Authors: Ben Stillman <ben@mariadb.com>, Guillaume Lefranc <guillaume@mariadb.com>
# License: GNU General Public License, version 3.
# Redistribution/Reuse of this code is permitted under the GNU v3 license.
# As an additional term ALL code must carry the original Author(s) credit in comment form.
# See LICENSE in this directory for the integral text.



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
        printf "%s --> %s\n" "$(date +%Y-%m-%d-%T)" "$*" | tee -a "$logfile"
    fi
}

# Function to create innobackupex command
function innocreate {
    mhost=$(hostname)
    innocommand="$innobackupex"
    dirdate=$(date +%Y-%m-%d_%H-%M-%S)
    alreadyfullcmd=$mysqlcommand" \"SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE DATE(starttime) = CURDATE() AND butype = 'Full' AND status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at = 0 \" "
    alreadyfull=$(eval "$alreadyfullcmd")
    anyfullcmd=$mysqlcommand" \"SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE butype = 'Full' AND status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at = 0 \" "
    anyfull=$(eval "$anyfullcmd")
    if [ "$bktype" = "directory" ] || [ "$bktype" = "prepared-archive" ]; then
        if ( ( [ "$(date +%A)" = "$fullbackday" ] || [ "$fullbackday" = "Everyday" ]) && [ "$alreadyfull" -eq 0 ] ) || [ "$anyfull" -eq 0 ] ; then
            butype=Full
            dirname="$backupdir/full-$dirdate"
            innocommand=$innocommand" $dirname --no-timestamp"
        else
            if [ "$differential" = yes ] ; then
                butype=Differential
                diffbasecmd=$mysqlcommand" \"SELECT backupdir FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND hostname = '$mhost' AND butype = 'Full' AND deleted_at = 0 ORDER BY starttime DESC LIMIT 1\" "
                diffbase=$(eval "$diffbasecmd")
                dirname="$backupdir/diff-$dirdate"
                innocommand=$innocommand" $dirname --no-timestamp --incremental --incremental-basedir=$diffbase"
            else
                butype=Incremental
                incbasecmd=$mysqlcommand" \"SELECT backupdir FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at = 0 ORDER BY starttime DESC LIMIT 1\" "
                incbase=$(eval "$incbasecmd")
                dirname="$backupdir/incr-$dirdate"
                innocommand=$innocommand" $dirname --no-timestamp --incremental --incremental-basedir=$incbase"
            fi
        fi
    elif [ "$bktype" = "archive" ] ; then
        if [ "$(date +%A)" = "$fullbackday" ] ; then
            butype=Full
            innocommand=$innocommand" /tmp --stream=$arctype --no-timestamp"
            arcname="$backupdir/full-$dirdate.$arctype.gz"
        else
            butype=Incremental
            incbasecmd=$mysqlcommand" \"SELECT backupdir FROM $backuphistschema.backup_history WHERE status = 'SUCCEEDED' AND hostname = '$mhost' AND deleted_at = 0 ORDER BY starttime DESC LIMIT 1\" "
            incbase=$(eval "$incbasecmd")
            innocommand=$innocommand" /tmp --stream=$arctype --no-timestamp --incremental --incremental-basedir=$incbase"
            arcname="$backupdir/inc-$dirdate.$arctype.gz"
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
    if [ "$bktype" == "prepared-archive" ]; then
        prepcommand="$innobackupex $dirname --apply-log"
        if [ -n "$databases" ]; then prepcommand=$prepcommand" --export"; fi
        log_info "Preparing backup."
        $prepcommand 2>> "$logfile"
        log_check
        log_info "Backup prepare complete."
        log_info "Archiving backup."
        tar cf "$dirname.tar.gz" -C "$dirname" -I "$computil" . && rm -rf "$dirname"
        log_info "Archiving complete."
    fi
}

# Function to build mysql command
function mysqlcreate {
    mysql=$(command -v mysql)
    mysqlcommand="$mysql"
    mysqlcommand=$mysqlcommand" -u $backuphistuser"
    mysqlcommand=$mysqlcommand" -p$backuphistpass"
    mysqlcommand=$mysqlcommand" -h $backuphisthost"
    [ ! -z "$backuphistport" ] && innocommand=$innocommand" -P $backuphistport"
    mysqlcommand=$mysqlcommand" -Bse "
}

# Function to build mysqldump command 
function mysqldumpcreate {
    mysqldump=$(command -v mysqldump)
    mysqldumpcommand="$mysqldump"
    mysqldumpcommand=$mysqldumpcommand" -u $backuphistuser"
    mysqldumpcommand=$mysqldumpcommand" -p$backuphistpass"
    mysqldumpcommand=$mysqldumpcommand" -h $backuphisthost"
    [ ! -z "$backuphistport" ] && innocommand=$innocommand" -P $backuphistport"
    mysqldumpcommand=$mysqldumpcommand" $backuphistschema"
    mysqldumpcommand=$mysqldumpcommand" backup_history"
}

# Function to create backup_history table if not exists
function create_history_table {
    createtable=$(cat <<EOF
CREATE TABLE IF NOT EXISTS $backuphistschema.backup_history (
uuid varchar(40) NOT NULL,
hostname varchar(100) DEFAULT NULL,
starttime timestamp NULL DEFAULT NULL,
endtime timestamp NULL DEFAULT NULL,
backupdir varchar(255) DEFAULT NULL,
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
    perconacnt=$(mysql -ss -e "SELECT COUNT(a.uuid) FROM PERCONA_SCHEMA.xtrabackup_history a LEFT JOIN mdbutil.backup_history b ON a.uuid = b.uuid WHERE b.uuid IS NULL;")
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
  starttime,
  endtime, 
  backupdir, 
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

    $mysqlcommand "SELECT uuid, backupdir FROM $backuphistschema.backup_history WHERE deleted_at IS NULL" | 
        while read -r uuid backupdir; do
        if test -d "$backupdir"
        then
            mysql -ss -e "UPDATE $backuphistschema.backup_history SET deleted_at = '0000-00-00 00:00:00' WHERE uuid = '$uuid' "
        else
            mysql -ss -e "UPDATE $backuphistschema.backup_history SET deleted_at = NOW() WHERE uuid = '$uuid' "
        fi
    done



    lefttomigratecnt=$(mysql -ss -e "SELECT COUNT(*) FROM mdbutil.backup_history WHERE deleted_at IS NULL")
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
    xtrabackup_version=$(cat "$logfile" | grep "/usr/bin/innobackupex version")
    backup_size=$(du -sm "$dirname" | awk '{ print $1 }')"M"
    historyinsert=$(cat <<EOF
INSERT INTO $backuphistschema.backup_history (uuid, hostname, starttime, endtime, backupdir, logfile, status, butype, bktype, arctype, compressed, encrypted, cryptkey, galera, slave, threads, xtrabackup_version, server_version, backup_size, deleted_at)
VALUES (UUID(), "$mhost", "$starttime", "$endtime", "$dirname", "$logfile", "$log_status", "$butype", "$bktype", "$arctype", "$compress", "$encrypt", "$cryptkey", "$galera", "$slave", "$threads", "$xtrabackup_version", "$server_version", "$backup_size", 0)
EOF
)
    $mysqlcommand "$historyinsert"
    #verify insert
    verifyinsert=$($mysqlcommand "select count(*) from $backuphistschema.backup_history where hostname='$mhost' and endtime='$endtime'")
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
        delcountcmd=$mysqlcommand" \"SELECT COUNT(*) FROM $backuphistschema.backup_history WHERE starttime < (SELECT starttime FROM $backuphistschema.backup_history WHERE butype = 'Full' ORDER BY starttime DESC LIMIT $limitoffset,1) AND hostname = '$mhost' AND status = 'SUCCEEDED' AND deleted_at = 0\" "
        delcount=$(eval "$delcountcmd")
        if [ "$delcount" -gt 0 ]; then
            deletecmd=$mysqlcommand" \"SELECT backupdir FROM $backuphistschema.backup_history WHERE starttime < (SELECT starttime FROM $backuphistschema.backup_history WHERE butype = 'Full' ORDER BY starttime DESC LIMIT $limitoffset,1) AND hostname = '$mhost' AND status = 'SUCCEEDED' AND deleted_at = 0\" "
            eval "$deletecmd" | while read -r deletedir; do
                log_info "Deleted backup $deletedir"
                markdeletedcmd=$mysqlcommand" \"UPDATE $backuphistschema.backup_history SET deleted_at = NOW() WHERE backupdir = '$deletedir' AND hostname = '$mhost' AND status = 'SUCCEEDED' \" "
                rm -Rf "$deletedir"
                eval "$markdeletedcmd"
            done
        else
            log_info "No backups to delete at this time."
        fi
    else
        log_info "Backup failed. No backups deleted at this time."
    fi
}

# Function to dump mdbutil schema
function mdbutil_backup {
    if [ $log_status = "SUCCEEDED" ]; then
        mysqldumpcreate
        mdbutildumpfile="$dirname"/"$backuphistschema".backup_history.sql
        $mysqldumpcommand > "$mdbutildumpfile"
        log_info "Backup history table dumped to $mdbutildumpfile"
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
    echo "run_after_success: " "$run_after_success"
    echo "run_after_fail: " "$run_after_fail"
}

############################################
# Begin script

# find and source the config file
etccnf=$( find /etc -name bgbackup.cnf )
scriptdir=$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ -e "$etccnf" ]; then
    source "$etccnf"
elif [ -e "$scriptdir"/bgbackup.cnf ]; then
    source "$scriptdir"/bgbackup.cnf
else
    log_info "Error: bgbackup.cnf configuration file not found"
    log_info "The configuration file must exist somewhere in /etc or"
    log_info "in the same directory where the script is located"
    log_status=FAILED
    mail_log
    exit 1
fi

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

# Set some specific variables
starttime=$(date +"%Y-%m-%d %H:%M:%S")
mdate=$(date +%m/%d/%y)    # Date for mail subject. Not in function so set at script start time, not when backup is finished.
logfile=$logpath/bgbackup_$(date +%Y-%m-%d-%T).log    # logfile

# Check for xtrabackup
if command -v innobackupex >/dev/null; then
    innobackupex=$(command -v innobackupex)
else
    log_info "xtrabackup/innobackupex does not appear to be installed. Please install and try again."
    log_status=FAILED
    mail_log
    exit 1
fi

mysqlcreate
 
create_history_table # Create history table if it doesn't exist

if [ "$checkmigrate" = yes ] ; then
    check_migrate # Check if Percona backup history records exist and migrate if needed
fi

config_check # Check vital configuration parameters

backer_upper # Execute the backup.

backup_cleanup # Cleanup old backups.

endtime=$(date +"%Y-%m-%d %H:%M:%S")

backup_history

mdbutil_backup

if [ "$log_status" = "FAILED" ] || [ "$mailonsuccess" = "yes" ] ; then
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
