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
## GLOBALS
backupts=`date +%Y%m%d%H%M%S`
backupdir=/dbbackup/gemfireBackup
base=$(readlink -f "$0")
basedir=$(dirname "$base")
sync_tries=3
#email_lst=shall@zdatainc.com
email_lst=`cat $basedir/mail_list`
echo "Email List:"$email_lst
enviroment="STAGE"
logdir=$basedir/logs
logfile=$logdir/gf_backup_$backupts.log
keepbackup=$1
#exec 2>&1 >> $basedir/logs/gf_backup_$backupts.err


send_alert ()
{
if [[ $resync = "FALSE" ]]; then
   mail -s "$enviroment: GEMFIRE STAGING BACKUP SUCCESSFUL! `date`" $email_lst < $logdir/gf_backup.log
else
   mail -s "$enviroment: ALERT!! One or more Gemfire backups did not SYNC: `date`" $email_lst < $logdir/gf_backup.log
fi

}


aws_sync ()
{
# sync with aws
echo "Running AWS SYNC"
pssh -p 6 -t 0  -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup 'aws s3 sync /dbbackup/gemfireBackup s3://pske-gemfire-stg-backup/$HOSTNAME --delete --include "*.tar.gz*"'
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
# Tar up
pssh -p 6 -t 0  -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup "tar -czf $backupdir/$backupts.tar.gz $backupdir/$backupts --remove-files"
}

archive_backup ()
{
#Remove old backups
echo "Removing Old Backup Directories"
#sudo rmdir $backupdir/$backupts
pssh -p 6 -t 0 -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup "rm -rf $backupdir/$backupts"

# remove old backups from /dbbackup
backup_count=`ls -l $backupdir/*.tar.gz | wc -l`
echo "$backup_count"

if [ $backup_count -gt $keepbackup ]; then
        rm_backup_count="$(($backup_count-$keepbackup))"
        old_backup=`ls $backupdir/*.tar.gz | sort -n | head -$rm_backup_count`
        echo "deleting backup $old_backup"
#        sudo rm -rf $old_backup
        pssh -p 4 -t 0 -o $basedir/logs -e $basedir/logs -h $basedir/hosts.backup "sudo rm -rf $old_backup"

else echo "no backups to delete"
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

##List of Gemfire hostnames
hnlst=( aue1lxsgf001ptl aue1lxsgf002ptl aue1lxsgf003ptl aue1lxsgf004ptl aue1lxsgf005ptl aue1lxsgf006ptl )

##Array that will execute the following steps for each hostname listed
for hname in ${hnlst[@]}; do
  ##Query S3 backup location, AWK is being used to cut the size and filename


  ##Verify file and size exist in AWS as it is on disk
  aws s3 ls s3://pske-gemfire-stg-backup/$hname.penske.com/ | awk -F" " '{print $3" "$4}' | tr " " "\n"  > /tmp/awsarrayfile
  readarray awsarr < /tmp/awsarrayfile

  # Backups on disk
  ssh $hname ls -lt /dbbackup/gemfireBackup |  awk -F" " '{print $5" "$9}' | tr " " "\n" > /tmp/backuparray
  readarray  backuparr < /tmp/backuparray
  echo "#####################################"
  echo "Starting Server " $hname > $logfile
  echo "#####################################"
  for y in "${backuparr[@]}"
  do
     #if $?; then echo "Found File"; else echo "Not a File"; fi
     if [ -n $y ]; then
       if [[ $y == *"tar.gz"* ]]; then
         echo "Starting Test for Backup "$y > $logfile
         if containsElement "$y" "${awsarr[@]}"; then
 #          echo "Found Element" > $logfile
           IndexOf "$y" "${awsarr[@]}"
           let arrayindex=arrayindex-1
           #awsfileSize="${awsarr[$arrayindex]}"
           awsfileSize="$(echo -e "${awsarr[$arrayindex]}" | tr -d '[:space:]')"
           echo "            awsfilesize="  $awsfileSize
           IndexOf "$y" "${backuparr[@]}"
           let arrayindex=arrayindex-1
           localfileSize="$(echo -e "${backuparr[$arrayindex]}" | tr -d '[:space:]')"
           #localfileSize="${backuparr[$arrayindex]}"
           echo "            localfilesize="  $awsfileSize
           if [ "$awsfileSize" -eq "$localfileSize" ];then
             echo "**********SYNC COMPLETE**********"
             resync="FALSE"
           else
             echo "**********SYNC FAILED**********"
             resync="TRUE"
           fi
         fi
       fi
     fi
   done
 done
 echo "Sync Check Complete resync value is "$resync
 }

 main ()
 {
 tries=0
 resync="TRUE"
 archive_backup
 backup_gemfire
 compact_backup

 #echo "tries:"$tries " " "resync:"$resync > $logfile
 while [[ $tries -lt $sync_tries ]] && [[ "$resync" != "FALSE" ]]; do
  aws_sync
  check_aws_sync
  ((tries++))
 done
 }

 main
 send_alert



 #END OF SCRIPT
