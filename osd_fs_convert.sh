#!/bin/bash

##############
# NOTE
# The number at the end of the path where osd data is stored must match the number used in naming the osd
# Must be able to execute ceph health successfully on each osd host
#
# Last tested
# FROM XFS -> BTRFS (12/11/2012)
# FROM BTRFS -> XFS (12/10/2012)

## EDIT BEFORE RUNNING! ##
desiredfs="xfs"
pool="default"
## EDIT END             ##

hostname=`hostname -s`
username=`whoami`

if [[ "$username" != "root" ]]; then
  echo "This script must be executed by the root user."
  exit 1;
fi

mounts=( `mount | grep osd | awk {'print $1'}` )
paths=( `mount | grep osd | awk {'print $3'}` )
types=( `mount | grep osd | awk {'print $5'}` )

count=`echo ${#mounts[@]}`
count=`expr $count - 1`
current="0"

while [ $current -le $count ];
do
  curmount=${mounts[$current]};
  curpath=${paths[$current]};
  curtype=${types[$current]};

  folderdepth=`echo $curpath | grep -o "/" | wc -l`
  awkloc=`expr $folderdepth + 1`
  osdnumcmd="echo $curpath | awk -F/ {'print \$$awkloc'}"
  osdnumber=`eval $osdnumcmd | sed "s/[^0-9]//g;s/^$/-1/;"`
  osdinfo=`ceph osd dump | grep "^osd.\$osdnumber "`
  osdname=`echo $osdinfo | awk {'print $1'}`
  osdweight=`echo $osdinfo | awk {'print $5'}`

  echo "mount: " $curmount;
  echo "path: " $curpath;
  echo "fstype: " $curtype;
  echo "desiredfs: " $desiredfs;

  if [ "$curtype" != "$desiredfs" ];
  then

    echo "$curmount needs to be converted!"

    echo "Checking cluster health..."
    health=`ceph health`
    while [ "$health" != "HEALTH_OK" ];
    do
      echo "Cluster is not reporting HEALTH_OK:"
      echo "Current health: $health"
      echo "Sleeping 30s and checking again..."
      sleep 30;
      health=`ceph health`;
    done;
    echo "Cluster is healthy, continuing..."

    echo "Marking out OSD, this will start a backfill process."
    ceph osd out $osdnumber

    echo "Waiting 30 seconds to be safe."
    sleep 30; #waiting for cluster status to change
    echo "Checking cluster health..."
    health=`ceph health`
    while [ "$health" != "HEALTH_OK" ];
    do
      echo "Current health: $health"
      echo "Sleeping 30s and checking again..."
      sleep 30;
      health=`ceph health`
    done;
    echo "Cluster is healthy, continuing..."

    echo "Stopping the OSD"
    /etc/init.d/ceph stop $osdname

    echo "Mark the OSD Down"
    ceph osd down $osdnumber

    echo "Removing the OSD from the crushmap"
    ceph osd crush remove $osdname

    echo "Removing authentication for OSD"
    ceph auth del $osdname

    echo "Removing OSD from Ceph"
    ceph osd rm $osdnumber

    echo "Unmounting OSD path"
    umount $curpath

    echo "Formatting to new FS"
    if [ "$desiredfs" == "xfs" ]
    then
      mkfs.xfs -f $curmount
    elif [ "$desiredfs" == "btrfs" ]
    then
      mkfs.btrfs $curmount
    else
      echo "Do not know how to handle $dersiredfs"
      exit 1
    fi

    echo "Mounting"
    mount -t $desiredfs $curmount $curpath

    echo "Create the OSD in Ceph"
    ceph osd create $osdnumber

    echo "Initializing the OSD"
    ceph-osd -i $osdnumber --mkfs --mkkey

    echo "Registering keyring"
    ceph-authtool -n $osdname $curpath/keyring --cap osd 'allow *' --cap mon 'allow rwx'
    ceph auth add $osdname -i $curpath/keyring

    echo "Adding OSD to crushmap"
    ceph osd crush set $osdnumber $osdname $osdweight pool=$pool host=$hostname

    echo "Starting the OSD"
    /etc/init.d/ceph start $osdname

    echo "Finished the OSD, sleeping for 30 seconds."
    sleep 30; #waiting for cluster status to change

  fi

  let current++;

done;
