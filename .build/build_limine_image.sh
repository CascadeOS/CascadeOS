#!/bin/bash
# SPDX-License-Identifier: MIT

PAD_DISK_SIZE=500

set -e

die() {
    >&2 echo "die: $*"
    exit 1
}

# Arguments
IMAGE="$1"
TARGET_ARCH="$2"
LIMINE="$3"
LIMINE_EXECUTABLE="$4"

if [ ! -d "$LIMINE" ]; then
    die "provided limine directory does not exist"
fi

if [ ! -f "$LIMINE_EXECUTABLE" ]; then
    die "provided limine executable does not exist"
fi

# Setup variables
BUILD_DIR=$(pwd -P)
PROJECT_DIR="$BUILD_DIR/.."

CACHE="$PROJECT_DIR/zig-cache"
IMAGE_BOOT="$CACHE/esp_mount_$TARGET_ARCH"
IMAGE_ROOT="$CACHE/root_mount_$TARGET_ARCH"

OUT_ROOT="$PROJECT_DIR/zig-out/$TARGET_ARCH/root"

LIMINE_CONFIG="$BUILD_DIR/limine.cfg"

mkdir -p "$CACHE"

# calculate disk size
disk_usage() {
    if [ "$(uname -s)" = "Darwin" ]; then
        du -sm "$1" | cut -f1
    else
        du -sm --apparent-size "$1" | cut -f1
    fi
}
DISK_SIZE=$(($(disk_usage "$OUT_ROOT") + PAD_DISK_SIZE))

# clean up old disk image
rm -rf "$IMAGE" || die "couldn't delete old disk image"

# setting up disk image
dd if=/dev/zero bs=1M count=0 seek="${DISK_SIZE:-800}" of="$IMAGE" status=none || die "couldn't create disk image"

# partition disk image
parted -s "$IMAGE" mklabel gpt || die "couldn't create gpt partition scheme"
parted -s "$IMAGE" mkpart ESP fat32 2048s 64MiB || die "couldn't create ESP partition" # This is a much larger partition that necessary to deal with FATs minimum size
parted -s "$IMAGE" mkpart ROOT ext2 64MiB 100% || die "couldn't create ROOT partition"
parted -s "$IMAGE" set 1 esp on || die "couldn't set ESP partiton to boot"

# deploy limine
"$LIMINE_EXECUTABLE" bios-install "$IMAGE" &>/dev/null || die "couldn't deploy limine"

# creating loopback device
USED_LOOPBACK=$(sudo losetup -Pf --show "$IMAGE")
if [ -z "$USED_LOOPBACK" ]; then
    die "couldn't mount loopback device"
fi

cleanup() {
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

# creating filesystems
sudo mkfs.fat -F 32 "${USED_LOOPBACK}p1" &>/dev/null || die "couldn't create efi filesystem"
sudo mke2fs -q -t ext2 "${USED_LOOPBACK}p2" &>/dev/null || die "couldn't create root filesystem"

# mounting filesystems
mkdir -p "$IMAGE_BOOT"
sudo mount "${USED_LOOPBACK}p1" "$IMAGE_BOOT" || die "couldn't mount efi filesystem"
mkdir -p "$IMAGE_ROOT"
sudo mount "${USED_LOOPBACK}p2" "$IMAGE_ROOT" || die "couldn't mount root filesystem"

# copying limine files
sudo mkdir -p "$IMAGE_BOOT"/EFI/BOOT || die "couldn't create EFI/BOOT directory"
sudo cp "$LIMINE_CONFIG" "$IMAGE_BOOT"/limine.cfg || die "couldn't copy limine files"

case "$TARGET_ARCH" in
'aarch64')
    sudo cp "$LIMINE"/BOOTAA64.EFI "$IMAGE_BOOT"/EFI/BOOT/ || die "couldn't copy limine files"
    ;;
'x86_64')
    sudo cp "$LIMINE"/limine-bios.sys "$IMAGE_BOOT"/ || die "couldn't copy limine files"
    sudo cp "$LIMINE"/BOOTX64.EFI "$IMAGE_BOOT"/EFI/BOOT/ || die "couldn't copy limine files"
    ;;
*)
    die "unsupported target arch"
    ;;
esac

# construct the filesystem
umask 0022

# creating initial filesystem structure
for dir in boot test tmp; do
    sudo mkdir -p "$IMAGE_ROOT/$dir" || die "couldn't create $dir directory"
done
sudo chmod 500 "$IMAGE_ROOT/boot" || die "couldn't set permission on boot directory"
sudo chmod 555 "$IMAGE_ROOT/test" || die "couldn't set permission on boot directory"
sudo chmod 1777 "$IMAGE_ROOT/tmp" || die "couldn't set permission on tmp directory"

# installing base system
if ! command -v rsync &>/dev/null; then
    die "Please install rsync."
fi

sudo rsync -aH --inplace "$OUT_ROOT/" "$IMAGE_ROOT/" || die "couldn't copy staging root to image root"

sudo chown -R 0:0 "$IMAGE_ROOT/" || die "couldn't set permission on image root"

sudo chmod -R g+rX,o+rX "$IMAGE_ROOT/" || die "couldn't set permission on image root"
sudo chmod -R 400 "$IMAGE_ROOT/boot/" || die "couldn't recursively set permissions on boot folder"
sudo chmod -R 755 "$IMAGE_ROOT/test/" || die "couldn't recursively set permissions on test folder"
