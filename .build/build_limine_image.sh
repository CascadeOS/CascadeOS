#!/bin/bash

LIMINE_BRANCH="v4.x-branch-binary"
PAD_DISK_SIZE=500

set -e

die() {
    >&2 echo "die: $*"
    exit 1
}

# Arguments
IMAGE="$1"
TARGET_NAME="$2"
TARGET_ARCH="$3"

# Setup variables

BUILD_DIR=$(pwd -P)
PROJECT_DIR="$BUILD_DIR/.."

CACHE="$PROJECT_DIR/zig-cache/working-area"
IMAGE_BOOT="$CACHE/esp_mount_$TARGET_NAME"
IMAGE_ROOT="$CACHE/root_mount_$TARGET_NAME"

OUT_ROOT="$PROJECT_DIR/zig-out/$TARGET_NAME/root"

LIMINE="$CACHE/limine-$LIMINE_BRANCH"
LIMINE_CONFIG="$BUILD_DIR/limine.cfg"

mkdir -p "$CACHE"

# building limine
if [ ! -d "${LIMINE}" ]; then
    echo "> cloning limine"
    git clone -b "$LIMINE_BRANCH" --depth=1 --single-branch https://github.com/limine-bootloader/limine.git "${LIMINE}" &>/dev/null || die "couldn't clone limine"
else
    echo "> check for limine updates"
    git -C "${LIMINE}" pull &>/dev/null || die "couldn't update limine"
fi
echo "> building limine"
make -C "$LIMINE" &>/dev/null || die "couldn't make limine"

# calculate disk size
disk_usage() {
    if [ "$(uname -s)" = "Darwin" ]; then
        du -sm "$1" | cut -f1
    else
        du -sm --apparent-size "$1" | cut -f1
    fi
}

DISK_SIZE=$(($(disk_usage "$OUT_ROOT") + PAD_DISK_SIZE))

echo "> building disk image"

rm -rf "$IMAGE" || die "couldn't delete old disk image"

# setting up disk image
dd if=/dev/zero bs=1M count=0 seek="${DISK_SIZE:-800}" of="$IMAGE" status=none || die "couldn't create disk image"

parted -s "$IMAGE" mklabel gpt || die "couldn't create gpt partition scheme"
# This is a much larger partition that necessary to deal with FATs minimum size
parted -s "$IMAGE" mkpart ESP fat32 2048s 64MiB || die "couldn't create ESP partition"
parted -s "$IMAGE" mkpart ROOT ext2 64MiB 100% || die "couldn't create ROOT partition"
parted -s "$IMAGE" set 1 esp on || die "couldn't set ESP partiton to boot"

echo "> deploying limine"

"$LIMINE"/limine-deploy "$IMAGE" &>/dev/null || die "couldn't deploy limine"

echo "> mounting disk image"

# creating loopback device
USED_LOOPBACK=$(sudo losetup -Pf --show "$IMAGE")
if [ -z "$USED_LOOPBACK" ]; then
    die "couldn't mount loopback device"
fi

cleanup() {
    echo "> unmounting disk image"
    
    sync
    
    if [ -d "$IMAGE_ROOT" ]; then
        # unmounting root partition
        sudo umount -R "$IMAGE_ROOT" || ( sleep 1 && sync && sudo umount -R "$IMAGE_ROOT" )
        rmdir "$IMAGE_ROOT"
    fi

    if [ -d "$IMAGE_BOOT" ]; then
        # unmounting efi partition
        sudo umount -R "$IMAGE_BOOT" || ( sleep 1 && sync && sudo umount -R "$IMAGE_BOOT" )
        rmdir "$IMAGE_BOOT"
    fi

    if [ -e "${USED_LOOPBACK}" ]; then
        # cleaning up loopback device
        sudo losetup -d "${USED_LOOPBACK}"
    fi
}

trap cleanup EXIT

echo "> creating file systems"

sudo mkfs.fat -F 32 "${USED_LOOPBACK}p1" &>/dev/null || die "couldn't create efi filesystem"
sudo mke2fs -q -t ext2 "${USED_LOOPBACK}p2" &>/dev/null || die "couldn't create root filesystem"

echo "> mounting file systems"

# mounting filesystems
mkdir -p "$IMAGE_BOOT"
sudo mount "${USED_LOOPBACK}p1" "$IMAGE_BOOT" || die "couldn't mount efi filesystem"
mkdir -p "$IMAGE_ROOT"
sudo mount "${USED_LOOPBACK}p2" "$IMAGE_ROOT" || die "couldn't mount root filesystem"

echo "> copying limine files"

sudo mkdir -p "$IMAGE_BOOT"/EFI/BOOT || die "couldn't create EFI/BOOT directory"
sudo cp "$LIMINE_CONFIG" "$IMAGE_BOOT"/limine.cfg || die "couldn't copy limine files"

case "$TARGET_ARCH" in
'x86_64')
    sudo cp "$LIMINE"/limine.sys "$IMAGE_BOOT"/ || die "couldn't copy limine files"
    sudo cp "$LIMINE"/BOOTX64.EFI "$IMAGE_BOOT"/EFI/BOOT/ || die "couldn't copy limine files"
    ;;
'aarch64')
    sudo cp "$LIMINE"/BOOTAA64.EFI "$IMAGE_BOOT"/EFI/BOOT/ || die "couldn't copy limine files"
    ;;
esac

# Construct the filesystem

echo "> constructing file system structure and permissions"

umask 0022

# creating initial filesystem structure
for dir in boot tmp; do
    sudo mkdir -p "$IMAGE_ROOT/$dir" || die "couldn't create $dir directory"
done
sudo chmod 700 "$IMAGE_ROOT/boot" || die "couldn't set permission on boot directory"
sudo chmod 1777 "$IMAGE_ROOT/tmp" || die "couldn't set permission on tmp directory"

echo "> installing base system and kernel files"

# installing base system
if ! command -v rsync &>/dev/null; then
    die "Please install rsync."
fi

sudo rsync -aH --inplace "$OUT_ROOT/" "$IMAGE_ROOT/" || die "couldn't copy staging root to image root"

sudo chown -R 0:0 "$IMAGE_ROOT/" || die "couldn't set permission on image root"

sudo chmod -R g+rX,o+rX "$IMAGE_ROOT/" || die "couldn't set permission on image root"
sudo chmod -R 0400 "$IMAGE_ROOT/boot/" || die "couldn't recursively set 0400 permission on boot folder"
