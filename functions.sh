#!/bin/bash
#
# vzbkp © Dmitry Kopytov <kopytov@linuxprofy.ru>
#

source "/usr/local/etc/vzbkp.conf"

function info {
    echo $( date +"[%F %T]" ) "$@"
}

function notice {
    echo $( date +"[%F %T]" ) "> $@"
}

function error {
    echo $( date +"[%F %T]" ) "*** $@"
    exit -1
}

function warn {
    echo $( date +"[%F %T]" ) "*** $@"
}

function dump_name {
    local ctid=$1
    local date=$2
    echo "${BACKUP_DIR}/vzbkp-${ctid}-${date}.tar.gz"
}

function recent_dump {
    local ctid=$1
    ls -1 "$BACKUP_DIR"/vzbkp-$ctid-????-??-??.tar.gz 2>/dev/null | sort | tail -n 1
}

function mount_backup_dir {
    notice "Mounting $BACKUP_DIR"
    if ! fgrep -q "$BACKUP_DIR" /etc/fstab
    then
        info "$BACKUP_DIR not found in /etc/fstab - mounting skipped" 

    elif mountpoint -q "$BACKUP_DIR"
    then
        info "$BACKUP_DIR is already mounted"

    else
        mount "$BACKUP_DIR" || error "Failed to mount $BACKUP_DIR"
        info "$BACKUP_DIR mounted"
    fi
}

function umount_backup_dir {
    notice "Unmounting $BACKUP_DIR"
    if ! mountpoint -q "$BACKUP_DIR"
    then
        info "$BACKUP_DIR is already unmounted"

    else
        umount "$BACKUP_DIR" || error "Failed to unmount $BACKUP_DIR"
        info "$BACKUP_DIR unmounted"
    fi
}

function rotate_dumps {
    local ctid=$1
    local dir=$2
    local num=$3
    local suffix=$4

    local num_dumps=$( ls -1 "$dir"/vzbkp-$ctid-????-??-??${suffix:+-${suffix}}.tar.gz | sort | wc -l )
    if [ $num_dumps -ge $num ]
    then
        local num_excess=$(( num_dumps - num + 1 ))
        local dump
        for dump in $( ls -1 "$dir"/vzbkp-$ctid-????-??-??${suffix:+-${suffix}}.tar.gz | sort | head -n $num_excess )
        do
            rm -f "$dump" || error "Failed to remove $dump"
            info "$dump removed"
        done

    else
        info "No excess dumps found"

    fi
}

function recent_date {
    local ctid=$1
    local suffix=$2
    ls -1 "$BACKUP_DIR"/vzbkp-$ctid-????-??-??-$suffix.tar.gz | sort -rn | head -n1 | sed -e "s|.*vzbkp-$ctid-\(.*\)-$suffix.*|\1|"
}

function link_recent_dump {
    local ctid=$1
    local suffix=$2

    local recent_dump=$( recent_dump $ctid )
    if [ -n "$recent_dump" ]
    then
        local link=$( echo "$recent_dump" | sed -e "s/\.tar\.gz$/-$suffix.tar.gz/" )
        ln "$recent_dump" "$link" || error "Failed to link $recent_dump to $link"

    else
        info "No recent dump of CT $ctid found"

    fi
}

function rotate {
    local ctid=$1
    notice "Rotating daily dumps of CT $ctid"
    rotate_dumps $ctid "$BACKUP_DIR" "$NUM_DAILY"

    local days7=604800
    if [ $NUM_WEEKLY -gt 0 ]
    then
        local recent_date=$( recent_date $ctid "weekly" )
        echo $recent_date
        if [ -z "$recent_date" ] || [ $(( $( date +%s ) - $( date +%s -d "$recent_date" ) )) -gt $days7 ]
        then
            notice "Rotating weekly dumps of CT $ctid"
            rotate_dumps $ctid "$BACKUP_DIR" "$NUM_WEEKLY" "weekly"
            link_recent_dump $ctid "weekly"
        fi
    fi

    local days30=2592000
    if [ $NUM_MONTHLY -gt 0 ]
    then
        local recent_date=$( recent_date $ctid "monthly" )
        if [ -z "$recent_date" ] || [ $(( $( date +%s ) - $( date +%s -d "$recent_date" ) )) -gt $days30 ]
        then
            notice "Rotating monthly dumps of CT $ctid"
            rotate_dumps $ctid "$BACKUP_DIR" "$NUM_MONTHLY" "monthly"
            link_recent_dump $ctid "monthly"
        fi
    fi
}

function dump {
    local ctid=$1
    local dump=$2
    [ -f "/etc/vz/conf/$ctid.conf" ] || error "CTID $ctid does not exist"
    [ -f "$dump" ] && error "Dump $dump is already exists"

    notice "Compacting CT $ctid"
    vzctl compact $ctid

    notice "Creating a snapshot $uuid"
    local uuid=$(uuidgen)
    local ct_private=$(VEID=$ctid; source /etc/vz/vz.conf; source /etc/vz/conf/$ctid.conf; echo $VE_PRIVATE)
    local disk_desriptor="$ct_private/root.hdd/DiskDescriptor.xml"
    vzctl snapshot $ctid --id $uuid --skip-suspend

    notice "Creating $dump"
    if type pigz >/dev/null 2>&1
    then
        tar -C "$ct_private" -I pigz -cf "$dump" .
        local tar_returnval=$?
    else
        tar -C "$ct_private" -czf "$dump" .
        local tar_returnval=$?
    fi

    notice "Deleting a snapshot $uuid"
    vzctl snapshot-delete $ctid --id $uuid

    if [ $tar_returnval -ne 0 ]
    then
        warn "tar returned $tar_returnval while creating $dump"
    fi
}

function restore {
    local ctid=$1
    local dump=$2
    [ -f "/etc/vz/conf/$ctid.conf" ] || error "CTID $ctid does not exist"
    [ -f "$dump" ] || error "Dump $dump does not exist"

    local ct_private=$(VEID=$ctid; source /etc/vz/vz.conf; source /etc/vz/conf/$ctid.conf; echo $VE_PRIVATE)

    notice "Stopping CT $ctid"
    vzctl stop $ctid
    vzctl umount $ctid

    notice "Removing $ct_private"
    rm -rf "$ct_private"/*

    notice "Extracting $dump"
    tar -xzf "$dump" -C "$ct_private" .

    local uuid=$(
        grep '<SavedStateItem .* current="yes">' "$ct_private/Snapshots.xml" | \
        cut -f2 -d{ | cut -f1 -d}
    )
    notice "Switching and deleting a snapshot $uuid"
    vzctl snapshot-switch $ctid --id $uuid
    vzctl snapshot-delete $ctid --id $uuid

    notice "Starting CT $ctid"
    vzctl start $ctid
}

LOCK_UPLOAD_FTP="/var/lock/LCK..vzbkp-upload_ftp"

function mount_ftp_dir {
    if mountpoint -q "$FTP_DIR"
    then
        info "$FTP_DIR is already mounted"

    else
        curlftpfs "ftp://${FTP_USERNAME}:${FTP_PASSWORD}@${FTP_SERVER}" "$FTP_DIR" || error "Failed to mount $FTP_DIR"
        info "$FTP_DIR mounted"

    fi
}

function umount_ftp_dir {
    if mountpoint -q "$FTP_DIR"
    then
        umount "$FTP_DIR" || error "Failed to unmount $FTP_DIR"
        info "$FTP_DIR unmounted"

    else
        info "$FTP_DIR is already unmounted"

    fi
}

function upload_ftp {
    local ctid=$1
    local dump=$2

    mount_ftp_dir

    notice "Rotating dumps of CT $ctid on FTP"
    rotate_dumps $ctid "$FTP_DIR" "$NUM_FTP_DUMPS"

    notice "Uploading $dump to $FTP_DIR"
    cp -f "$dump" "$FTP_DIR" || error "Failed to upload $dump to $FTP_DIR"

    umount_ftp_dir
}

function check_md_action {
    [ -z "$MD_DEVICE" ] && return 0
    local sync_action=$( cat /sys/block/$MD_DEVICE/md/sync_action )
    info "$MD_DEVICE action is $sync_action"
    if [ "$sync_action" != "idle" ]
    then
        warn "Skipping dump because $MD_DEVICE action is $sync_action"
        exit 0
    fi
    return 0
}

