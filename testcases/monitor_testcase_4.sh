#!/bin/bash
#
# Testcase 4: Disk attach/detach
#             (HBA attach/detach for zFCP)
#

set -o errexit

. $(dirname "$0")/monitor_testcase_functions.sh

MD_NAME="testcase4"
MD_DEV="/dev/md/${MD_NAME}"

MONITOR_TIMEOUT=60

function attach_dasd() {
    local userid=$1
    local devno=$2
    
    if [ "$userid" = "LINUX025" ] ; then
	vmcp link \* ${devno##*.} ${devno##*.} || \
	    error_exit "Cannot link device $devno"
    else
	vmcp att ${devno##*.} \* || \
	    error_exit "Cannot attach device $devno"
    fi
}

function attach_scsi() {
    local vdev=$1
    local rdev=$2

    if [ -n "$rdev" ] ; then
	vmcp att ${rdev} \* ${vdev} || \
	    error_exit "Cannot attach device $rdev to $vdev"
    else
	vmcp att ${vdev} || \
	    error_exit "Cannot attach device $vdev"
    fi
}

stop_md ${MD_DEV}

activate_devices

clear_metadata

if [ -n "$DEVNOS_LEFT" ] ; then
    userid=$(vmcp q userid | cut -f 1 -d ' ')
    if [ -z "$userid" ] ; then
	error_exit "This testcase can only run under z/VM"
    fi
fi

ulimit -c unlimited
start_md ${MD_NAME}

logger "${MD_NAME}: Disk detach/attach"

echo "$(date) Create filesystem ..."
if ! mkfs.ext3 ${MD_DEV} ; then
    error_exit "Cannot create fs"
fi

echo "$(date) Mount filesystem ..."
if ! mount ${MD_DEV} /mnt ; then
    error_exit "Cannot mount MD array."
fi

echo "$(date) Run I/O test"
run_iotest /mnt;

if [ -n "$DEVNOS_LEFT" ] ; then
    echo "$(date) Detach disk on first half ..."
    for devno in ${DEVNOS_LEFT} ; do
	vmcp det ${devno##*.} || \
	    error_exit "Cannot detach device ${devno##*.}"
	push_recovery_fn "attach_dasd $userid ${devno##*.}"
	break;
    done
else
    echo "$(date) Detach HBA on first half ..."
    for shost in ${SHOSTS_LEFT[@]} ; do
	hostpath=$(cd -P /sys/class/scsi_host/$shost; echo $PWD)
	ccwpath=${hostpath%%/host*}
	devno=${ccwpath##*/}
	vdev=${devno##*.}
	rdev=$(vmcp q v ${vdev} | sed -n 's/.*ON FCP  *\([0-9A-F]*\) CHPID.*/\1/p')
	vmcp det ${vdev} || \
	    error_exit "Cannot detach device ${vdev}"
	push_recovery_fn "attach_scsi ${vdev} ${rdev}"
    done
fi

wait_for_md_failed $MONITOR_TIMEOUT

echo "$(date) Wait for 10 seconds"
sleep 10
mdadm --detail ${MD_DEV}

echo "$(date) Re-attach disk on first half ..."
while true ; do
    if ! pop_recovery_fn ; then
	break;
    fi
done

wait_for_md_running_left $MONITOR_TIMEOUT

echo "$(date) MD status"
mdadm --detail ${MD_DEV}

echo "$(date) Stop I/O test"
stop_iotest

echo "$(date) Wait for sync"
wait_for_sync ${MD_DEV} || \
    error_exit "Failed to synchronize array"

check_md_log step1

if [ "$detach_other_half" ] ; then
    if [ -n "$DEVNOS_RIGHT" ] ; then
	echo "Detach disk on second half ..."
	for devno in ${DEVNOS_RIGHT} ; do
	    vmcp det ${devno##*.}
	    push_recovery_fn "attach_dasd $userid ${devno##*.}"
	    break;
	done
    else
	echo "$(date) detach HBAs on second half ..."
	for shost in ${SHOSTS_RIGHT[@]} ; do
	    hostpath=$(cd -P /sys/class/scsi_host/$shost; echo $PWD)
	    ccwpath=${hostpath%%/host*}
	    devno=${ccwpath##*/}
	    vdev=${devno##*.}
	    rdev=$(vmcp q v ${vdev} | sed -n 's/.*ON FCP  *\([0-9A-F]*\) CHPID.*/\1/p')
	    vmcp det ${vdev} || \
		error_exit "Cannot detach device ${vdev}"
	    push_recovery_fn "attach_scsi ${vdev} ${rdev}"
	done
    fi

    wait_for_md_failed $MONITOR_TIMEOUT

    sleep 5
    mdadm --detail ${MD_DEV}
    ls /mnt
    echo "Re-attach disk on second half ..."
    while true ; do
	if ! pop_recovery_fn ; then
	    break;
	fi
    done

    wait_for_md_running_right $MONITOR_TIMEOUT
    
    wait_for_sync ${MD_DEV} || \
	error_exit "Failed to synchronize array"

    check_md_log step2
fi

logger "${MD_NAME}: success"

echo "$(date) Umount filesystem ..."
umount /mnt

stop_md ${MD_DEV}
