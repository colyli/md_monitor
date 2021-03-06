#!/bin/bash
#
# Common functions for testcases
#

function devno_from_dasd() {
    local dasd=${1##*/}
    local devpath

    if [ ! -e /sys/block/$dasd ] ; then
	dasd=${dasd%1}
    fi
    if [ ! -L /sys/block/$dasd ] ; then
	echo "No sysfs entry for $1"
	exit 1
    fi
    devpath=$(cd -P /sys/block/${dasd}/device; echo $PWD)
    echo ${devpath##*/}
}

function error_exit() {
    local errstr=$1

    echo "$(date) $errstr"
    exit 1
}

function start_md() {
    local MD_NAME=$1
    local MD_DEVICES=$2
    local MD_MONITOR=/sbin/md_monitor
    local MD_SCRIPT=/usr/share/misc/md_notify_device.sh
    local MD_ARGS="--bitmap=internal --chunk=1024 --assume-clean --force"
    local n=0
    local devlist

    case "$MD_NAME" in
	md*)
	    MD_DEV=/dev/$MD_NAME
	    ;;
	*)
	    MD_DEV=/dev/md/$MD_NAME
	    ;;
    esac
    if [ -z "$MD_DEVICES" ] ; then
	MD_DEVICES=$MD_DEVNUM
    fi
    while [ $n -lt $(expr $MD_DEVICES / 2) ] ; do
	devlist="$devlist ${DEVICES_LEFT[$n]} ${DEVICES_RIGHT[$n]}"
	n=$(expr $n + 1)
    done

    STARTDATE=$(date +"%Y-%m-%d %H:%M:%S")

    if [ -f /usr/lib/systemd/system/mdmonitor.service ] ; then
	echo "Stopping mdmonitor"
	systemctl stop mdmonitor
    fi
    echo "Create MD array ..."
    mdadm --create ${MD_DEV} --name=${MD_NAME} \
	--raid-devices=${MD_DEVICES} ${MD_ARGS} --level=raid10 \
	--failfast ${devlist} \
	|| error_exit "Cannot create MD array."

    mdadm --wait ${MD_DEV} || true

    START_LOG="/tmp/monitor_${MD_NAME}_mdstat_start.log"
    mdadm --detail ${MD_DEV} | sed -n '/Devices/p' | tee ${START_LOG}
    echo "POLICY action=re-add" > /etc/mdadm.conf
    echo "AUTO -all" >> /etc/mdadm.conf
    mdadm --brief --detail ${MD_DEV} >> /etc/mdadm.conf
    echo "PROGRAM ${MD_SCRIPT}" >> /etc/mdadm.conf

    if ! which journalctl > /dev/null 2>&1 ; then
	rm /var/log/messages
	rcsyslog restart
    fi

    MONITOR_PID=$(/sbin/md_monitor -y -p 7 -d -s)
    trapcmd="[ \$? -ne 0 ] && echo TEST FAILED while executing \'\$BASH_COMMAND\', EXITING"
    trapcmd="$trapcmd ; logger ${MD_NAME}: failed"
    trapcmd="$trapcmd ; reset_devices ; stop_iotest"
    if [ -z "$MONITOR_PID" ] ; then
	error_exit "Failed to start md_monitor"
    fi
    trapcmd="$trapcmd ; stop_monitor"

    MDADM_PID=$(mdadm --monitor --scan --daemonise)
    if [ -z "$MDADM_PID" ] ; then
	error_exit "Failed to start mdadm"
    fi
    trapcmd="$trapcmd ; stop_mdadm"

    iostat -kt 1 > /tmp/monitor_${MD_NAME}_iostat.log 2>&1 &
    IOSTAT_PID=$!
    if [ -n "$IOSTAT_PID" ] ; then
	trapcmd="$trapcmd ; stop_iostat"
    fi
    trapcmd="$trapcmd ; write_log $MD_NAME"
    if [ -n "$trapcmd" ] ; then
	trap "$trapcmd" EXIT
    fi
}

function check_md_log() {
    local prefix=$1
    local logfile

    [ -z "${START_LOG}" ] && return
    logfile="/tmp/monitor_${MD_NAME}_${prefix}.log"
    mdadm --detail ${MD_DEV} | sed -n '/Devices/p' | tee ${logfile}
    if ! diff -u "${START_LOG}" "${logfile}" ; then
	error_exit "current ${MD_NAME} state differs after test but should be identical to initial state"
    fi
    rm -f $logfile
}

function stop_monitor() {
    if [ -n "$MONITOR_PID" ] ; then
	if ! /sbin/md_monitor -c'Shutdown:/dev/console' ; then
	    echo "Failed to stop md_monitor"
	    return 1
	fi
	MONITOR_PID=
    fi
    return 0
}

function stop_mdadm() {
    if [ -n "$MDADM_PID" ] ; then
	kill -TERM $MDADM_PID 2> /dev/null || true
	MDADM_PID=
    fi
    return 0
}

function stop_iostat() {
    if [ -n "$IOSTAT_PID" ] ; then
	if kill -TERM $IOSTAT_PID 2> /dev/null ; then
	    echo -n "waiting for iostat to finish ... "
	    wait %iostat 2> /dev/null || true
	    echo done
	    IOSTAT_PID=
	fi
    fi
    return 0
}

function stop_md() {
    local md_dev=$1
    local md
    local md_detail
    local cur_md

    if [ "$md_dev" ] ; then
	cur_md=$(resolve_md $md_dev)
	if ! grep -q "${cur_md} " /proc/mdstat 2> /dev/null ; then
	    return
	fi
	mdadm --misc /dev/${cur_md} --wait-clean
    fi
    check_md_log stop
    trap - EXIT
    stop_monitor
    stop_mdadm
    stop_iostat
    rm -f ${START_LOG}
    for md in $(sed -n 's/^\(md[0-9]*\) .*/\1/p' /proc/mdstat) ; do
	if [ -n "$cur_md"] && [ "$md" = "$cur_md" ] ; then
	    if grep -q /dev/$md /proc/mounts ; then
		echo "Unmounting filesystems ..."
		if ! umount /dev/$md ; then
		    echo "Cannot unmount /dev/$md"
		    exit 1
		fi
	    fi
	fi
	echo "Stopping MD array ..."
	mdadm --stop /dev/$md
    done
    clear_metadata
    if [ -n "$STARTDATE" ] ; then
	write_log $MD_NAME
    fi
    rm -f /etc/mdadm.conf
    rm -f /tmp/monitor_${MD_NAME}_step*.log
}

function write_log() {
    local MD_NAME=$1

    if which journalctl > /dev/null 2>&1 ; then
	journalctl --since "$STARTDATE" > /tmp/monitor_${MD_NAME}.log
    else
	cp /var/log/messages /tmp/monitor_${MD_NAME}.log
    fi
}

function resolve_md() {
    local MD_NAME=$1

    if [ -L "$MD_NAME" ] ; then
	md_link=$(readlink $MD_NAME)
	MD_NUM=${md_link##*/}
    else
	MD_NUM=${MD_NAME##*/}
    fi
    echo "$MD_NUM"
    exit 0
}

function wait_md() {
    local MD_DEV=$1

    mdadm --wait ${MD_DEV} || true
}

function setup_one_dasd() {
    local devno=$(printf "0.0.%04x" $(($1)))
    local online dasd

    if [ ! -d /sys/bus/ccw/devices/$devno ] ; then
	error_exit "Device $devno is not available"
    fi
    read online < /sys/bus/ccw/devices/$devno/online
    if [ "$online" -ne 1 ] ; then
	if ! echo 1 > /sys/bus/ccw/devices/$devno/online ; then
	    error_exit "Cannot set device $devno online"
	fi
	udevadm settle
    fi
    dasd=
    for d in /sys/bus/ccw/devices/$devno/block/* ; do
	if [ -d "$d" ] ; then
	    dasd=${d##*/}
	fi
    done
    if [ -z "$dasd" ] ; then
	error_exit "Cannot activate device $devno"
    fi
    read status < /sys/bus/ccw/devices/$devno/status
    if [ "$status" = "unformatted" ] ; then
	if ! dasdfmt -p -y -b 4096 -f /dev/$dasd ; then
	    error_exit "Failed to format $dasd"
	fi
	read status < /sys/bus/ccw/devices/$devno/status
    fi
    if [ "$status" != "online" ] ; then
	error_exit "Failed to activate $dasd"
    fi
    if [ ! -d /sys/block/${dasd}/${dasd}1 ] || [ -d /sys/block/dasd/${dasd}/${dasd}2 ] ; then
	if ! fdasd -a /dev/$dasd > /dev/null 2>&1 ; then
	    error_exit "Failed to partition $dasd"
	fi
    fi
    echo "$devno" "$dasd"
}

function activate_dasds() {
    local userid=$1
    local devno_max=$2
    local devno;
    local dasd;
    local DEVNO_LEFT_START="0xa010"
    local DEVNO_LEFT_END="0xa0c8"
    local DEVNO_RIGHT_START="0xa110"
    local DEVNO_RIGHT_END="0xa1c8"
    local i=0

    [ -f /proc/mdstat ] || modprobe raid10
    if [ "$userid" = "LINUX025" ] ; then
        # linux025 layout
	DEVNO_LEFT_START="0x0210"
	DEVNO_LEFT_END="0x0217"
	DEVNO_RIGHT_START="0x0220"
	DEVNO_RIGHT_END="0x0227"
    elif [ "$userid" != "LINUX021" ] ; then
	error_exit "Cannot determine DASD layout for $userid"
    fi

    # Use 8 DASDs per side per default
    if [ -z "$devno_max" ] ; then
	devno_max=8
    fi
    devno_start=$((DEVNO_LEFT_START))
    devno_end=$(( devno_start + $devno_max ))
    if [ $devno_end -gt $((DEVNO_LEFT_END)) ] ; then
	devno_end=$((DEVNO_LEFT_END))
    fi
    while [ $devno_start -lt $devno_end ] ; do
	D=($(setup_one_dasd $devno_start))
	DEVNOS_LEFT="$DEVNOS_LEFT ${D[0]}"
	DASDS_LEFT+=("${D[1]}")
	DEVICES_LEFT+=("/dev/${D[1]}1")
	(( devno_start++)) || true
    done

    devno_start=$((DEVNO_RIGHT_START))
    devno_end=$(( devno_start + $devno_max ))
    if [ $devno_end -gt $((DEVNO_RIGHT_END)) ] ; then
	devno_end=$((DEVNO_RIGHT_END))
    fi
    while [ $devno_start -lt $devno_end ] ; do
	D=($(setup_one_dasd $devno_start))
	DEVNOS_RIGHT="$DEVNOS_RIGHT ${D[0]}"
	DASDS_RIGHT+=("${D[1]}")
	DEVICES_RIGHT+=("/dev/${D[1]}1")
	(( devno_start++)) || true
    done
}

function activate_scsi() {
    local hostname=$1
    local devno_max=$2
    local devno;
    local dasd;
    local i=0

    unset SHOSTS_LEFT
    unset SDEVS_LEFT
    unset DEVICES_LEFT
    unset SHOSTS_RIGHT
    unset SDEVS_RIGHT
    unset DEVICES_RIGHT

    if [ "$hostname" = "elnath" ] ; then
	SCSIID_LEFT="3600a098032466955593f416531744a39 3600a098032466955593f416531744a41 3600a098032466955593f416531744a43 3600a098032466955593f416531744a45"
	SCSIID_RIGHT="3600a098032466955593f41653174496c 3600a098032466955593f416531744a2d 3600a098032466955593f416531744a42 3600a098032466955593f416531744a44"
    elif [ "$hostname" = "LINUX042" ] ; then
	SCSIID_LEFT="36005076305ffc73a00000000000013c3 36005076305ffc73a000000000000105d 36005076305ffc73a000000000000105c 36005076305ffc73a000000000000115c 36005076305ffc73a000000000000100c 36005076305ffc73a000000000000105b 36005076305ffc73a000000000000115b 36005076305ffc73a000000000000105a 36005076305ffc73a000000000000115a 36005076305ffc73a000000000000115d"
	SCSIID_RIGHT="36005076305ffc73a00000000000013db 36005076305ffc73a00000000000013da 36005076305ffc73a000000000000115f 36005076305ffc73a0000000000001167 36005076305ffc73a000000000000115e 36005076305ffc73a0000000000001166 36005076305ffc73a0000000000001165 36005076305ffc73a0000000000001164 36005076305ffc73a0000000000001163 36005076305ffc73a0000000000001162"
    else
	return 1
    fi

    # Use 8 devices per side per default
    if [ -z "$devno_max" ] ; then
	devno_max=8
    fi
    devno=0
    for scsiid in ${SCSIID_LEFT} ; do
	[ $devno -ge $devno_max ] && break
	paths=$(multipathd -k"show map $scsiid topology" | \
	        sed -n 's/.*[0-9]*:[0-9]*:[0-9]*:[0-9]* \(sd[a-z]*\) .*/\1/p')
	for path in ${paths} ; do
	    devpath="/sys/block/$path/device"
	    shost_left=$(cd -P $devpath; echo $PWD | sed -n 's/.*\(host[0-9]*\).*/\1/p')
	    read state < $devpath/state
	    if [ "$state" != "running" ] ; then
		error_exit "SCSI device $path in state $state, cannot continue"
	    fi
	    shost_found=0
	    for shost in ${SHOSTS_LEFT[@]} ; do
		if [ "$shost" = "$shost_left" ] ; then
		    shost_found=1
		    break;
		fi
	    done
	    if [ "$shost_found" = "0" ] ; then
		SHOSTS_LEFT+=("$shost_left")
	    fi
	    mpath_state=$(multipathd -k'show paths format "%d %t %T"' | sed -n "s/$path  *\(.*\)/\1/p")
	    if [ "$mpath_state" != "active ready " ] ; then
		error_exit "Multipath device $path in state $mpath_state, cannot continue"
	    fi
	    SDEVS_LEFT+=("${path}")
	done
	mpath_dev=$(multipathd -k'show multipaths' | sed -n "s/.* \(dm-[0-9]*\) *$scsiid/\1/p")
	DEVICES_LEFT+=("/dev/$mpath_dev")
	(( devno++ )) || true
    done

    devno=0
    for scsiid in ${SCSIID_RIGHT} ; do
	[ $devno -ge $devno_max ] && break
	paths=$(multipathd -k"show map $scsiid topology" | \
	        sed -n 's/.*[0-9]*:[0-9]*:[0-9]*:[0-9]* \(sd[a-z]*\) .*/\1/p')
	for path in ${paths} ; do
	    devpath="/sys/block/$path/device"
	    shost_right=$(cd -P $devpath; echo $PWD | sed -n 's/.*\(host[0-9]*\).*/\1/p')
	    read state < $devpath/state
	    if [ "$state" != "running" ] ; then
		error_exit "SCSI device $path in state $state, cannot continue"
	    fi
	    shost_found=0
	    for shost in ${SHOSTS_LEFT[@]} ; do
		if [ "$shost" = "$shost_right" ] ; then
		    shost_found=1
		    break;
		fi
	    done
	    if [ "$shost_found" = "1" ] ; then
		error_exit "SCSI $shost_right for SCSI device $path already attached to the left side"
	    fi
	    shost_found=0
	    for shost in ${SHOSTS_RIGHT[@]} ; do
		if [ "$shost" = "$shost_right" ] ; then
		    shost_found=1
		    break;
		fi
	    done
	    if [ "$shost_found" = "0" ] ; then
		SHOSTS_RIGHT+=("$shost_right")
	    fi
	    mpath_state=$(multipathd -k'show paths format "%d %t %T"' | sed -n "s/$path  *\(.*\)/\1/p")
	    if [ "$mpath_state" != "active ready " ] ; then
		error_exit "Multipath device $path in state $mpath_state, cannot continue"
	    fi
	    SDEVS_RIGHT+=("$path")
	done
	mpath_dev=$(multipathd -k'show multipaths' | sed -n "s/.* \(dm-[0-9]*\) *$scsiid/\1/p")
	DEVICES_RIGHT+=("/dev/$mpath_dev")
	(( devno++ )) || true
    done
}

function activate_devices()
{
    local num_devs=$1

    arch=$(arch)
    if [ "$arch" = "s390x" ] ; then
	if ! zgrep -q VMCP=y /proc/config.gz ; then
	    if ! grep -q vmcp /proc/modules ; then
		modprobe vmcp
	    fi
	fi
	hostname=$(vmcp q userid 2> /dev/null | cut -f 1 -d ' ')
    else
	hostname=$(hostname)
    fi
    if ! activate_scsi $hostname $num_devs ; then
	activate_dasds $hostname $num_devs
    fi
}

function clear_metadata() {
    echo -n "Clear MD Metadata ..."
    MD_DEVNUM=0
    for dev in ${DEVICES_LEFT[@]} ${DEVICES_RIGHT[@]} ; do
	echo -n " $dev ..."
	if [ ! -b $dev ] ; then
	    echo -n " (missing)"
	    continue
	fi
	mdadm --zero-superblock --force $dev > /dev/null 2>&1
	dd if=/dev/zero of=${dev} bs=4096 count=4096 >/dev/null 2>&1
	MD_DEVNUM=$(( $MD_DEVNUM + 1 ))
    done
    echo " done"
}

function run_dd() {
    local PRG=$1
    local MNT=$2
    local BLKS=$3
    local SIZE
    local CPUS

    if [ "$PRG" = "dt" ] ; then
	CPUS=$(sed -n 's/^# processors *: \([0-9]*\)/\1/p' /proc/cpuinfo)
	(( CPUS * 2 )) || true
	SIZE=$(( $BLKS * 4096 ))
	exec ${DT_PROG} of=${MNT}/dt.scratch bs=4k incr=var min=4k max=256k errors=1 procs=$CPUS oncerr=abort disable=pstats disable=fsync oflags=trunc errors=1 dispose=keep pattern=iot iotype=random runtime=24h limit=${SIZE} log=/tmp/dt.log > /dev/null 2>&1
    else
	while true ; do
	    dd if=/dev/random of=${MNT}/dd.scratch bs=4k count=${BLKS} &
	    trap "kill $!" EXIT
	    wait
	    dd if=${MNT}/dd.scratch of=/dev/null bs=4k count=${BLKS} &
	    trap "kill $!" EXIT
	    wait
	    trap - EXIT
	done
    fi
}

function run_iotest() {
    local MNT=$1
    local DT_PROG
    local CPUS
    local BLKS

    DT_PROG=$(which dt 2> /dev/null) || true

    BLKS=$(df | sed -n "s/[a-z/]*[0-9]* *[0-9]* *[0-9]* *\([0-9]*\) *[0-9]*% *.*${MNT##*/}/\1/p")
    if [ -z "$BLKS" ] ; then
	echo "Device $MNT not found"
	exit 1
    fi
    BLKS=$(( BLKS >> 3 ))
    if [ -z "$DT_PROG" ] ; then
	run_dd "dd" $MNT $BLKS > /tmp/dt.log 2>&1 &
    else
	run_dd "dt" $MNT $BLKS > /tmp/dt.log 2>&1 &
    fi
}

function stop_iotest() {
    DT_PROG=$(which dt 2> /dev/null) || true

    if kill -TERM %run_dd 2> /dev/null ; then
	echo -n "waiting for ${DT_PROG:-dd} to finish ... "
	wait %run_dd 2> /dev/null || true
	echo done
    fi
}

declare -a RECOVERY_HOOKS

function push_recovery_fn() {
    [ -z "$1" ] && echo "WARNING: no parameters passed to push_recovery_fn"
    RECOVERY_HOOKS[${#RECOVERY_HOOKS[*]}]="$1"
}

function pop_recovery_fn() {
    local fn=$1
    local num_hook=${#RECOVERY_HOOKS[*]}

    [ $num_hook -eq 0 ] && return 1
    (( num_hook--)) || true
    eval ${RECOVERY_HOOKS[$num_hook]} || true
    unset RECOVERY_HOOKS[$num_hook]
    return 0
}

function reset_devices() {
    local dasd
    local devno

    for dev in ${DEVICES_LEFT[@]} ${DEVICES_RIGHT[@]} ; do
	case "$dev" in
	    dasd*)
		setdasd -q 0 -d /dev/${dev} || true
		;;
	esac
    done

    for fn in "${RECOVERY_HOOKS[@]}"; do
	echo "calling \"$fn\""
	eval $fn || true
    done
}

function wait_for_sync () {
  echo "waiting for sync...";
  local START_TIME=`date +%s`;
  local ELAPSED_TIME;
  local status;
  local resync_time;
  local MD_DEV=$1
  local MD
  local wait_for_bitmap=$2
  local RAIDLVL
  local raid_status
  local raid_disks=0;
  local working_disks=0;
  local MONITORTIMEOUT=30
  local RESYNCSPEED=4000

  MD=$(resolve_md ${MD_DEV})
      
  local RAIDLVL=$(sed -n "s/${MD}.*\(raid[0-9]*\) .*/\1/p" /proc/mdstat)
  if [ -z "$RAIDLVL" ] ; then
      echo "ERROR: array not started"
      return 1
  fi

  # Check overall status
  raid_status=$(sed -n 's/.*\[\([0-9]*\/[0-9]*\)\].*/\1/p' /proc/mdstat)
  if [ "$raid_status" ] ; then
      raid_disks=${raid_status%/*}
      working_disks=${raid_status#*/}
  fi
  if [ $raid_disks -eq 0 ] ; then
      echo "ERROR: No raid disks on mirror ${MD}"
      mdadm --detail ${MD_DEV}
      return 1
  fi
  # Reshaping might not have been started, at which point the new disks
  # will show up in the device list but not the array disk count
  num_disks=0
  for d in $(sed -n 's/.*active raid10 \(.*\)/\1/p' /proc/mdstat) ; do
      (( num_disks++ )) || true
  done
  if [ $num_disks -gt $raid_disks ] ; then
      raid_disks=$num_disks
  fi
  # This is tricky
  # Recovery is done in several stages
  # 1. The failed devices are removed
  # 2. The removed devices are re-added
  # 3. Recovery will start
  # 
  # To complicate things any of theses steps
  # might already be done by the time we get
  # around checking for it.
  #
  # So first check if all devices are working
  #
  resync_time=$(sed -n 's/.* finish=\(.*\)min speed.*/\1/p' /proc/mdstat)
  if [ $raid_disks -eq $working_disks ] && [ -z "$resync_time" ] ; then
      # All devices in sync, ok
      echo "All devices in sync"
      return 0
  fi
  action=$(sed -n 's/.* \([a-z]*\) =.*/\1/p' /proc/mdstat)
  if [ "$action" != "reshape" ] ; then
      # Bump resync speed
      echo $RESYNCSPEED > /sys/block/${MD}/md/sync_speed_min
  fi
  # Wait for resync process to be started
  wait_time=0
  while [ $wait_time -lt $MONITORTIMEOUT ] ; do
      resync_time=$(sed -n 's/.* finish=\(.*\)min speed.*/\1/p' /proc/mdstat)
      # Recovery will start as soon as the devices have been re-added
      [ -z "$resync_time" ] || break
      raid_status=$(sed -n 's/.*\[\([0-9]*\/[0-9]*\)\].*/\1/p' /proc/mdstat)
      working_disks=${raid_status#*/}
      # Stop loop if all devices are working
      [ $working_disks -eq $raid_disks ] && break
      sleep 1
      (( wait_time++ )) || true
  done
  if [ $wait_time -ge $MONITORTIMEOUT ] ; then
      echo "ERROR: recovery didn't start after $MONITORTIMEOUT seconds"
      mdadm --detail ${MD_DEV}
      return 1
  fi
  wait_md ${MD_DEV}

  if [ "$action" != "reshape" ] ; then
      # Reset sync speed
      echo "system" > /sys/block/${MD}/md/sync_speed_min
  fi
  raid_status=$(sed -n 's/.*\[\([0-9]*\/[0-9]*\)\].*/\1/p' /proc/mdstat)
  if [ -z "$raid_status" ] ; then
      echo "ERROR: no raid disks on mirror $MD"
      return 1;
  fi
  raid_disks=${raid_status%/*}
  working_disks=${raid_status#*/}
  if [ $raid_disks -ne $working_disks ] ; then
      echo "ERROR: mirror $MD degraded after recovery"
      mdadm --detail ${MD_DEV}
      return 1;
  fi
  if [ "$wait_for_bitmap" ] ; then
      # Waiting for bitmap to clear
      num_pages=1
      wait_time=0
      while [ $wait_time -lt $MONITORTIMEOUT ] ; do
	  num_pages=$(sed -n 's/ *bitmap: \([0-9]*\)\/[0-9]* .*/\1/p' /proc/mdstat)
	  [ $num_pages -eq 0 ] && break
	  sleep 1
	  (( wait_time++ )) || true
      done
      if [ $wait_time -ge $MONITORTIMEOUT ] ; then
	  echo "bitmap didn't clear after $MONITORTIMEOUT seconds:"
	  cat /proc/mdstat
      fi
  fi

  let ELAPSED_TIME=`date +%s`-$START_TIME || true
  echo "sync finished after $ELAPSED_TIME secs";
}

function wait_for_monitor() {
    local MD_DEV=$1
    local oldstatus=$2
    local timeout=$3
    local newstatus tmpstatus

    echo "Wait for md_monitor to pick up changes"
    starttime=$(date +%s)
    runtime=$starttime
    endtime=$(date +%s --date="+ $timeout sec")
    while [ $runtime -lt $endtime ] ; do
	newstatus=$(md_monitor -c"MonitorStatus:${MD_DEV}")
	if [ "$oldstatus" = "$newstatus" ] ; then
	    break;
	fi
	sleep 1
	if [ -n "$tmpstatus" ] && [ $tmpstatus != $newstatus ] ; then
	    break;
	fi
	tmpstatus=$newstatus
	runtime=$(date +%s)
    done
    elapsed=$(( $runtime - $starttime ))

    if [ $runtime -ge $endtime ] ; then
	echo "Monitor status does not match: is ${newstatus} was ${oldstatus}"
	return 1
    else
	echo "md_monitor picked up changes after $elapsed seconds"
    fi
    true
}

function wait_for_md_failed() {
    local timeout=$1

    echo "$(date) Ok. Waiting for MD to pick up changes ..."
    # Wait for md_monitor to pick up changes
    starttime=$(date +%s)
    runtime=$starttime
    endtime=$(date +%s --date="+ $timeout sec")
    while [ $runtime -lt $endtime ] ; do
	raid_status=$(sed -n 's/.*\[\([0-9]*\/[0-9]*\)\].*/\1/p' /proc/mdstat)
	if [ "$raid_status" ] ; then
	    raid_disks=${raid_status%/*}
	    working_disks=${raid_status#*/}
	    failed_disks=$(( raid_disks - working_disks))
	    [ $working_disks -eq $failed_disks ] && break;
	fi
	sleep 1
	runtime=$(date +%s)
    done
    elapsed=$(( $runtime - $starttime ))
    if [ $runtime -lt $endtime ] ; then
	echo "$(date) MD monitor picked up changes after $elapsed seconds"
    else
	error_exit "$working_disks / $raid_disks are still working after $elapsed seconds"
    fi
}

function wait_for_md_running_left() {
    local timeout=$1
    local MD_NUM

    MD_NUM=$(resolve_md ${MD_DEV})

    echo "$(date) Ok. Waiting for MD to pick up changes ..."
    # Wait for md_monitor to pick up changes
    num=${#DEVICES_LEFT[@]}
    starttime=$(date +%s)
    runtime=$starttime
    endtime=$(date +%s --date="+ $timeout sec")
    while [ $num -gt 0  ] ; do
	[ $runtime -ge $endtime ] && break
	for d in ${DEVICES_LEFT[@]} ; do
	    dev=${d##*/}
	    md_dev=$(sed -n "s/${MD_NUM}.* \(${dev}\[[0-9]*\]\).*/\1/p" /proc/mdstat)
	    if [ "$md_dev" ] ; then
		(( num -- )) || true
	    fi
	done
	[ $num -eq 0 ] && break
	num=${#DEVICES_LEFT[@]}
	sleep 1
	runtime=$(date +%s)
    done
    elapsed=$(( $runtime - $starttime ))
    if [ $runtime -lt $endtime ] ; then
	echo "$(date) MD monitor picked up changes after $elapsed seconds"
    else
	error_exit "$(date) $num are still faulty after $elapsed seconds"
    fi
}

function wait_for_md_running_right() {
    local timeout=$1
    local MD_NUM

    MD_NUM=$(resolve_md ${MD_DEV})

    echo "$(date) Ok. Waiting for MD to pick up changes ..."
    # Wait for md_monitor to pick up changes
    num=${#DEVICES_RIGHT[@]}
    starttime=$(date +%s)
    runtime=$starttime
    endtime=$(date +%s --date="+ $timeout sec")
    while [ $num -gt 0  ] ; do
	[ $runtime -ge $endtime ] && break
	for d in ${DEVICES_RIGHT[@]} ; do
	    dev=${d##*/}
	    md_dev=$(sed -n "s/${MD_NUM}.* \(${dev}\[[0-9]*\]\).*/\1/p" /proc/mdstat)
	    if [ "$md_dev" ] ; then
		(( num -- )) || true
	    fi
	done
	[ $num -eq 0 ] && break
	num=${#DEVICES_RIGHT[@]}
	sleep 1
	runtime=$(date +%s)
    done
    elapsed=$(( $runtime - $starttime ))
    if [ $runtime -lt $endtime ] ; then
	echo "$(date) MD monitor picked up changes after $elapsed seconds"
    else
	error_exit "$(date) $num are still faulty after $elapsed seconds"
    fi
}
