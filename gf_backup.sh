#!/usr/bin/env bash
#set -x
# ##################################################
# Gemfire Backup And Recovery
#
version="1.0.0"               # Sets version variable
#
#
# HISTORY:
#
# * DATE - v1.0.0  - First Creation
#
# ##################################################
# GLOBALS
base=$(readlink -f "$0")
basedir=$(dirname "$base")

send_alert ()
{
if [[ $resync = "FALSE" ]]; then
   mail -s "$enviroment: GEMFIRE PRODUCTION BACKUP SUCCESSFUL! `date`" $email_list < $logdir/gf_backup.log else
   mail -s "$enviroment: ALERT!! One or more Gemfire backups did not SYNC: `date`" $email_list < $logdir/gf_backup.log fi
}


aws_sync ()
{
# sync with aws
echo "Running AWS SYNC"
pssh -p 6 -t 0  -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup 'aws s3 sync /dbbackup/gemfireBackup s3://pske-gemfire-backup/$HOSTNAME --delete --include "*.tar.gz*"'

check_aws_sync
}


backup_gemfire ()
{
sudo gfsh <<EOF
connect --locator=localhost[10334] --security-properties-file=/opt/penske/gemfire/gfsecurity.properties
backup disk-store --dir=$backupdir/$backupts
EOF
}

compact_backup ()
{
echo "Checking for a backup directory"
if [[ -d $backupdir/$backupts ]]; then
  echo "Backup directory found. Compressing Backup"
  pssh -p 6 -t 0  -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup "tar -czf $backupdir/$backupts.tar.gz $backupdir/$backupts --remove-files"
  if [[ -e $backupdir/$backupts.tar.gz ]]; then
    pssh -p 6 -t 0 -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup "rm -rf $backupdir/$backupts"
  else
    echo "File failed to compact directory was not removed"
  fi
  echo "Backup Compression Complete cleaning up"
  if [[ -e $backupdir/$backupts.tar.gz ]]; then
     pssh -p 6 -t 0 -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup "rm -rf $backupdir/$backupts"
   else
  echo "File failed to compact directory was not removed"
  fi
else
  echo "No backup directory Exists"
fi

}

archive_backup ()
{
backup_count=`ls -l $backupdir/*.tar.gz | wc -l` expired_backups=`find $backupdir/*.tar.gz -type f -mtime +$keepbackup ` if [[ ! -z $expired_backups ]]; then
    echo "Deleting backups "
    echo "$expired_backups"
    pssh -p 6 -t 0 -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup "find /dbbackup/gemfireBackup/*.tar.gz -type f -mtime +$keepbackup -exec rm -rf {} +"
else
    echo "No backups to delete"
fi
}

IndexOf ()
{
    local i=0 S=$1; shift
    while [ "$S" != "$1" ]
    do    ((i++)); shift
        [ -z "$1" ] && { i=0; break; }
    done
    arrayindex=$i
}

containsElement ()
{
  local e
  for e in "${@:2}";
	do [[ "$e" == "$1" ]] && return 0;
	done
  return 1
}

function check_aws_sync ()
{
##Array that will execute the following steps for each hostname listed
for hname in ${hostlist[@]}; do
  ##Query S3 backup location, AWK is being used to cut the size and filename

  ##Verify file and size exist in AWS as it is on disk
  aws s3 ls s3://pske-gemfire-backup/$hname.penske.com/ | awk -F" " '{print $3" "$4}' | tr " " "\n"  > /tmp/awsarrayfile
  readarray awsarr < /tmp/awsarrayfile

# Backups on disk
  ssh $hname ls -lt /dbbackup/gemfireBackup |  awk -F" " '{print $5" "$9}' | tr " " "\n" > /tmp/backuparray
  readarray  backuparr < /tmp/backuparray #  echo "#####################################"
#  echo "Starting Server " $hname > $logfile #  echo "#####################################"
  for y in "${backuparr[@]}"
  do
    #if $?; then echo "Found File"; else echo "Not a File"; fi
    if [ -n $y ]; then
      if [[ $y == *"tar.gz"* ]]; then
        if containsElement "$y" "${awsarr[@]}"; then
#          echo "Found Element" > $logfile
	  IndexOf "$y" "${awsarr[@]}"
	  let arrayindex=arrayindex-1
  	  #awsfileSize="${awsarr[$arrayindex]}"
  	  awsfileSize="$(echo -e "${awsarr[$arrayindex]}" | tr -d '[:space:]')"
	#  echo "            awsfilesize="  $awsfileSize
	  IndexOf "$y" "${backuparr[@]}"
	  let arrayindex=arrayindex-1
  	  localfileSize="$(echo -e "${backuparr[$arrayindex]}" | tr -d '[:space:]')"
  	  #localfileSize="${backuparr[$arrayindex]}"
	#  echo "            localfilesize="  $awsfileSize
	  if [ "$awsfileSize" -eq "$localfileSize" ];then
	    resync="FALSE"
	  else
	    resync="TRUE"
	  fi
        fi
      fi
    fi
  done
done
if [[ $resync = 'FALSE' ]];then
  echo "AWS SYNC COMPLETE "
else
  echo "AWS SYNC FAILED"
fi
}

main ()
{
tries=0
resync="TRUE"
backup_gemfire
compact_backup
archive_backup

while [[ $tries -lt $sync_tries ]] && [[ "$resync" != "FALSE" ]]; do  aws_sync
 ((tries++))
done
}

echo "Reading Config File"


main
send_alert



#END OF SCRIPT
