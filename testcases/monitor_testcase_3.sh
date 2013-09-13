#!/bin/bash
#
# Testcase 3: Disk online/offline
#

. ./monitor_testcase_functions.sh

MD_NUM="md1"
MD_NAME="testcase3"

logger "Monitor Testcase 3: Disk offline/online"

stop_md $MD_NUM

activate_dasds

clear_metadata

ulimit -c unlimited
start_md ${MD_NUM}

echo "Create filesystem ..."
if ! mkfs.ext3 /dev/${MD_NUM} ; then
    error_exit "Cannot create fs"
fi

echo "Mount filesystem ..."
if ! mount /dev/${MD_NUM} /mnt ; then
    error_exit "Cannot mount MD array."
fi

echo "Write test file 1 ..."
dd if=/dev/zero of=/mnt/testfile1 bs=4096 count=1024

echo "Shutting down first half ..."
for d in ${DEVICES_LEFT[@]} ; do
    md_monitor -c "Remove:/dev/${MD_NUM}@$d"
done
if ! mdadm --manage /dev/${MD_NUM} --fail ${DEVICES_LEFT[@]} ; then
    error_exit "Cannot fail first half in MD array $MD_NUM"
fi
if ! mdadm --manage /dev/${MD_NUM} --remove ${DEVICES_LEFT[@]} ; then
    error_exit "Cannot fail $d in MD array $MD_NUM"
fi

mdadm --wait /dev/${MD_NUM}
for devno in $DEVNOS_LEFT ; do
    if ! echo 0 > /sys/bus/ccw/devices/$devno/online ; then
	error_exit "Cannot set device $devno offline"
    fi
done
echo "Write test file 2 ..."
dd if=/dev/zero of=/mnt/testfile2 bs=4096 count=1024
sleep 6
mdadm --detail /dev/${MD_NUM}
ls -l /mnt
echo "Restart first half ..."
for devno in $DEVNOS_LEFT ; do
    if ! echo 1 > /sys/bus/ccw/devices/$devno/online ; then
	error_exit "Cannot set device $devno online"
    fi
done
echo "Wait for sync"
if ! wait_for_sync ${MD_NUM} ; then
    error_exit "Failed to activate first half"
fi

mdadm --detail /dev/${MD_NUM}
md_monitor -c"ArrayStatus:/dev/${MD_NUM}"

echo "Shutting down second half ..."
for d in ${DEVICES_RIGHT[@]} ; do
    md_monitor -c "Remove:/dev/${MD_NUM}@$d"
done
if ! mdadm --manage /dev/${MD_NUM} --fail ${DEVICES_RIGHT[@]} ; then
    error_exit "Cannot fail $d in MD array $MD_NUM"
fi
mdadm --wait /dev/${MD_NUM}
if ! mdadm --manage /dev/${MD_NUM} --remove ${DEVICES_RIGHT[@]} ; then
    error_exit "Cannot remove $d in MD array $MD_NUM"
fi
mdadm --wait /dev/${MD_NUM}
for devno in $DEVNOS_RIGHT ; do
    if ! echo 0 > /sys/bus/ccw/devices/$devno/online ; then
	error_exit "Cannot set device $devno offline"
    fi
done
echo "Write test file 3 ..."
dd if=/dev/zero of=/mnt/testfile3 bs=4096 count=1024
sleep 5
mdadm --detail /dev/${MD_NUM}
ls -l /mnt
echo "Restart second half ..."
for devno in $DEVNOS_RIGHT ; do
    if ! echo 1 > /sys/bus/ccw/devices/$devno/online ; then
	error_exit "Cannot set device $devno online"
    fi
done
sleep 6
mdadm --detail /dev/${MD_NUM}
ls -l /mnt

diff -u /dev/stdin <(stat --printf='%n %s\n' /mnt/testfile*) <<EOE
/mnt/testfile1 4194304
/mnt/testfile2 4194304
/mnt/testfile3 4194304
EOE
if [ $? -ne 0 ] ; then
    error_exit "test file inconsistency found"
fi

echo "Umount filesystem ..."
umount /mnt

stop_md ${MD_NUM}
