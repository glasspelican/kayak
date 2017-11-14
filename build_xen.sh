#!/bin/bash
#
# {{{ CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License, Version 1.0 only
# (the "License").  You may not use this file except in compliance
# with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END }}}
#
# Copyright 2013 by Andrzej Szeszo. All rights reserved.
# Copyright 2013 OmniTI Computer Consulting, Inc.  All rights reserved.
# Copyright 2017 OmniOS Community Edition (OmniOSce) Association.
# Use is subject to license terms.
#

[ "`id -u`" != 0 ] && echo Run this script as root && exit 1

. install_help.sh 2>/dev/null
. disk_help.sh
. net_help.sh
. xen_help.sh

VMODE=hvm
USEGRUB=0

VERSION=`head -1 /etc/release | awk '{print $3}' | sed 's/[a-z]//g'`
ZFSSEND=/kayak_image/kayak_r$VERSION.zfs.bz2
PVGRUB=pv-grub.gz.d3950d8

RPOOL=syspool
BENAME=omnios
ALTROOT=/mnt
UNIX=/platform/i86xpv/kernel/amd64/unix

[ -f "$ZFSSEND" ] || ZFSSEND="omniosce-r$VERSION.zfs.bz2"
[ ! -f $ZFSSEND ] && echo "ZFS Image ($ZFSSEND) missing" && exit 

# Find the disk

DISK="`diskinfo -pH | grep -w 8589934592 | awk '{print $2}'`"
[ -z "$DISK" ] && echo "Cannot find 8GiB disk" && exit 1
cat << EOM

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

`diskinfo`

If you continue, disk $DISK will be completely erased

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

EOM
echo "Using disk $DISK...return to continue, ^C to abort...\\c"
read a

if [ $VMODE = pv -a  ! -f $PVGRUB ]; then
    wget https://downloads.omniosce.org/media/misc/pv-grub.gz.d3950d8
fi

# Begin

zpool destroy $RPOOL 2>/dev/null || true

if [ $VMODE = pv ]; then
    SetupPVPart
    SetupPVGrub
    SetupPVZPool
else
    if [ $USEGRUB -eq 1 ]; then
        SetupHVMPart
        zpool create -f $RPOOL ${DISK}s0
    else
        # Use whole-disk EFI
        zpool create -f $RPOOL ${DISK}
    fi
fi

BE_Create_Root $RPOOL
BE_Receive_Image cat "bzip2 -dc" $RPOOL $BENAME $ZFSSEND
BE_Mount $RPOOL $BENAME $ALTROOT raw
BE_SetUUID $RPOOL $BENAME $ALTROOT
BE_SeedSMF $ALTROOT
BE_LinkMsglog $ALTROOT

if [ $USEGRUB -eq 1 ]; then
    Grub_MakeBootable
else
    MakeBootable $RPOOL $BENAME
fi

ApplyChanges
Xen_Customise

SetTimezone UTC
Postboot '/sbin/ipadm create-if xnf0'
Postboot '/sbin/ipadm create-addr -T dhcp xnf0/v4'
Postboot 'for i in $(seq 0 9); do curl -f http://169.254.169.254/ >/dev/null 2>&1 && break; sleep 1; done'
Postboot 'HOSTNAME=$(curl http://169.254.169.254/latest/meta-data/hostname)'
Postboot '[ -z "$HOSTNAME" ] || (hostname $HOSTNAME && echo $HOSTNAME >/etc/nodename)'
Postboot 'exit $SMF_EXIT_OK'

BE_Umount $BENAME $ALTROOT raw

zpool export $RPOOL

# Once zpool_patch is able to properly update the vdev labels, the following
# code can be used to automate volume creation. For now, the pool needs
# to be imported under Xen.
exit 0

gmake zpool_patch
./zpool_patch /dev/rdsk/${DISK}s0

zdb -e -CC $RPOOL | sed -n '/^Configuration for import/,/^$/p'

echo "Creating raw disk image"
dd if=/dev/rdsk/${DISK}p0 of=xen-$VERSION.raw bs=2048

echo "Creating VMDK"
vmdkver=0.2
dir=VMDK-stream-converter-$vmdkver
file=$dir.tar.gz
if [ ! -d $dir ]; then
    wget -O /tmp/$file https://mirrors.omniosce.org/vmdk/$file
    gtar zxf /tmp/$file
fi

./$dir/VMDKstream.py xen-$VERSION.raw xen-$VERSION.vmdk
rm -f xen-$VERSION.raw

# Vim hints
# vim:ts=4:sw=4:et:fdm=marker
