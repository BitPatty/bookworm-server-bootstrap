#!/bin/bash
#
# bootstrap.sh
#
# This script bootstraps the debian server
#

set -e
set -u
set -o pipefail

############################################################################
# Preconditions
############################################################################

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Ensure a configuration file is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <config-file>"
    exit 1
fi

CONFIG_FILE="$1"

# Ensure the configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found."
    exit 1#!/bin/bash
fi


REQUIRED_COMMANDS=(
    chmod
    zfs
    zpool
    sgdisk
    partprobe
    dd
    lsblk
    readlink
    read
    mkfs.fat
    blkid
    partprobe
)

# Ensure all required commands are installed
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' is not available. Please install it."
        exit 1
    fi
done

############################################################################
# Validate the config file
############################################################################

echo "Loading configuration from $CONFIG_FILE..."
. "$CONFIG_FILE"

REQUIRED_CONFIG_VALUES=(
  TARGET_DISK
  ZFS_PASSPHRASE
)

# Ensure all required variables are set
for VAR in "${REQUIRED_CONFIG_VALUES[@]}"; do
  if [[ -z "$VAR" ]]; then
    echo "Configuration value for $VAR is not set."
    exit 1
  fi
done


############################################################################
# Target disk selection
############################################################################

# Print all block devices with their canonical paths
echo "Available block devices:"
lsblk -dn -o NAME,SIZE,TYPE | while read -r name size type; do
    if [ "$type" = "disk" ]; then
        canonical_path=$(readlink -f "/dev/$name")
        echo "  /dev/$name (size: $size, canonical: $canonical_path)"
    fi
done

# If TARGET_DISK is not set, autodetect the largest block device
if [ -z "${TARGET_DISK:-}" ]; then
    echo "No TARGET_DISK provided in configuration. Detecting the largest available disk..."
    TARGET_DISK=$(lsblk -b -dn -o NAME,SIZE,TYPE | grep -w 'disk' | sort -h -k2 | tail -1 | awk '{print $1}')
    if [ -z "$TARGET_DISK" ]; then
        echo "Error: No suitable disk found."
        exit 1
    fi
    TARGET_DISK="/dev/$TARGET_DISK"
    echo "Autodetected TARGET_DISK: $TARGET_DISK"
fi

CANONICAL_DISK=$(readlink -f "$TARGET_DISK")
echo "Using canonical disk name: $CANONICAL_DISK"
TARGET_DISK="$CANONICAL_DISK"

# Ensure the TARGET_DISK is valid
if [ -z "$TARGET_DISK" ] || [ ! -b "$TARGET_DISK" ]; then
    echo "Error: Invalid TARGET_DISK detected."
    exit 1
fi

############################################################################
# User confrmation
############################################################################

echo "WARNING: This operation will erase all data on $TARGET_DISK."
read -p "Are you sure you want to proceed? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Operation canceled."
    exit 1
fi

############################################################################
# Disk partitioning
############################################################################

# Ensure the disk is not mounted
if lsblk -n -o MOUNTPOINT "$TARGET_DISK" | grep -q "/"; then
    echo "Error: Target disk ($TARGET_DISK) or its partitions are mounted. Unmount them before proceeding."
    exit 1
fi

# Wipe the partition table and clear all data on the disk
echo "Wiping the partition table and clearing data on $TARGET_DISK..."
sgdisk --clear --align-entire "$TARGET_DISK"

# Will always error when it reaches the end of the disk
dd if=/dev/zero of="$TARGET_DISK" bs=1M status=progress || true

# Create the partition table
echo "Creating a new partition table on $TARGET_DISK..."
sgdisk -o "$TARGET_DISK"

# Create the EFI partition
echo "Creating an EFI partition..."
sgdisk -n 1:1M:+512M -t 1:EF00 -c 1:"EFI System" "$TARGET_DISK"

EFI_PARTITION="/dev/$(lsblk -r -n -o NAME "$TARGET_DISK" | grep -E "^$(basename $TARGET_DISK)p?1$")"

if [ ! -b "$EFI_PARTITION" ]; then
    echo "Error: EFI partition ($EFI_PARTITION) does not exist."
    exit 1
fi

# Format the EFI partition to FAT32
echo "Formatting the EFI partition ($EFI_PARTITION) as FAT32..."
mkfs.fat -F32 "$EFI_PARTITION" || {
    echo "Error: Failed to format EFI partition ($EFI_PARTITION) as FAT32."
    exit 1
}

blkid "$EFI_PARTITION"

# Create the ZFS boot partition
echo "Creating an ZFS boot partition..."
sgdisk -n 2:0:+2G -t 2:BF01 -c 2:"ZFS Boot Partition" "$TARGET_DISK"

ZFS_BOOT_PARTITION="/dev/$(lsblk -r -n -o NAME "$TARGET_DISK" | grep -E "^$(basename $TARGET_DISK)p?2$")"

if [ ! -b "$ZFS_BOOT_PARTITION" ]; then
    echo "Error: ZFS boot partition ($ZFS_BOOT_PARTITION) does not exist."
    exit 1
fi

# Create the ZFS primary filesystem partition
echo "Creating a ZFS root partition..."
sgdisk -n 3:0:0 -t 3:BF00 -c 3:"ZFS Root Partition" "$TARGET_DISK"

ZFS_ROOT_PARTITION="/dev/$(lsblk -r -n -o NAME "$TARGET_DISK" | grep -E "^$(basename $TARGET_DISK)p?3$")"

if [ ! -b "$ZFS_ROOT_PARTITION" ]; then
    echo "Error: ZFS root partition ($ZFS_ROOT_PARTITION) does not exist."
    exit 1
fi

blkid "$ZFS_ROOT_PARTITION"

# Ensure all changes are written
partprobe "$TARGET_DISK"


# Done
echo "Partitioning complete. Current layout:"
lsblk "$TARGET_DISK"

############################################################################
# ZFS Pool Creation
############################################################################

echo "Creating ZFS boot pool"

if [ -z "${ZFS_BOOT_PARTITION:-}" ] || [ ! -b "$ZFS_BOOT_PARTITION" ]; then
    echo "Error: ZFS_BOOT_PARTITION ($ZFS_BOOT_PARTITION) is not valid."
    exit 1
fi

zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off \
    -O acltype=posixacl \
    -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=/boot \
    -R /mnt \
    bpool "$ZFS_BOOT_PARTITION"

echo "Creating ZFS root pool"

if [ -z "${ZFS_ROOT_PARTITION:-}" ] || [ ! -b "$ZFS_ROOT_PARTITION" ]; then
    echo "Error: ZFS_ROOT_PARTITION ($ZFS_ROOT_PARTITION) is not valid."
    exit 1
fi

echo "$ZFS_PASSPHRASE" | zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O compression=lz4 \
    -O normalization=formD \
    -O atime=off \
    -O relatime=on \
    -O xattr=sa \
    -O encryption=on \
    -O keyformat=passphrase \
    -O canmount=off \
    -O mountpoint=/ \
    -R /mnt \
    rpool "$ZFS_ROOT_PARTITION"

############################################################################
# ZFS Root Dataset Creation
############################################################################

echo "Creating root datasets"
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

echo "Creating root/boot datasets"
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/debian
zfs mount rpool/ROOT/debian
zfs create -o mountpoint=/boot bpool/BOOT/debian

echo "Creating default datasets"
zfs create                     rpool/home
zfs create -o mountpoint=/root rpool/home/root
chmod 700 /mnt/root
zfs create -o canmount=off     rpool/var
zfs create -o canmount=off     rpool/var/lib
zfs create                     rpool/var/log
zfs create                     rpool/var/spool

zfs create -o com.sun:auto-snapshot=false  rpool/tmp
chmod 1777 /mnt/tmp

############################################################################
# ZFS summary
############################################################################

echo "Pools created. ZFS filesystem mounted to /mnt"
zpool status
zfs list
zfs get encryption

############################################################################
# Mount tmpfs
############################################################################

echo "Mounting tmpfs"
mkdir /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir /mnt/run/lock

############################################################################
# Debian Base Installation
############################################################################

echo "Installing debian"
debootstrap --arch=amd64 bookworm /mnt https://deb.debian.org/debian/

############################################################################
# ZFS cache
############################################################################

echo "Copying zpool.cache"
mkdir /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/


############################################################################
# Mount runtime fs
############################################################################

echo "Mounting runtime fs"

mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

############################################################################
# Configure apt sources
############################################################################

echo "Configuring apt sources"

chroot /mnt bash << CHROOTSCRIPT
cat > /etc/apt/sources.list << SOURCES
deb https://deb.debian.org/debian bookworm main contrib
deb https://deb.debian.org/debian bookworm-updates main contrib
deb https://security.debian.org/debian-security bookworm-security main
SOURCES

apt update
CHROOTSCRIPT

############################################################################
# Install kernel
############################################################################

echo "Installing kernel"
chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y linux-image-amd64
CHROOTSCRIPT

############################################################################
# Install systemd
############################################################################

echo "Installing systemd"
chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y systemd-sysv
CHROOTSCRIPT

############################################################################
# Configure Locale
############################################################################

echo "Configuring locale"

chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y locales console-setup

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen

echo 'export LC_ALL="en_US.UTF-8"' >> ~/.bashrc
echo 'export LANG="en_US.UTF-8"' >> ~/.bashrc
echo 'export LANGUAGE="en_US.UTF-8"' >> ~/.bashrc
CHROOTSCRIPT

############################################################################
# Configure Keyboard Layout
############################################################################

echo "Configuring keyboard layout..."

chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y keyboard-configuration
dpkg-reconfigure keyboard-configuration

cat > /etc/default/keyboard <<KEYBOARD_CONFIGURATION
XKBMODEL="$XKBMODEL"
XKBLAYOUT="$XKBLAYOUT"
XKBVARIANT="$XKBVARIANT"
XKBOPTIONS=""

KEYBOARD_CONFIGURATION
CHROOTSCRIPT

############################################################################
# Update the hostname
############################################################################

echo "Updating hostname"

chroot /mnt bash << CHROOTSCRIPT
hostname "$HOSTNAME"
hostname > /etc/hostname
CHROOTSCRIPT

############################################################################
# Update /etc/hosts
############################################################################

echo "Updating /etc/hosts"

chroot /mnt bash << CHROOTSCRIPT
cat > /etc/hosts << HOSTS
127.0.0.1   localhost $HOSTNAME $FQDN

::1         localhost ip6-localhost ip6-loopback $HOSTNAME $FQDN
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS
CHROOTSCRIPT

############################################################################
# Setup zfs
############################################################################

echo "Configuring ZFS"
chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y zfs-initramfs zfsutils-linux linuxheaders-amd64
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf
CHROOTSCRIPT

############################################################################
# Setup GRUB
############################################################################

echo "Configuring GRUB"
chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install dosfstools

mkdosfs -F 32 -s 1 -n EFI $ZFS_BOOT_PARTITION
mkdir /boot/efi
echo /dev/disk/by-uuid/$(blkid -s UUID -o value ${ZFS_BOOT_PARTITION}) \
   /boot/efi vfat defaults 0 0 >> /etc/fstab
mount /boot/efi
apt install --yes grub-efi-amd64 shim-signed
CHROOTSCRIPT

############################################################################
# Enable bpool importing
############################################################################

echo "Configuring bpool import"
chroot /mnt bash << CHROOTSCRIPT
cat /etc/systemd/system/zfs-import-bpool.service << SERVICE
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
SERVICE
CHROOTSCRIPT

############################################################################
# Set up tmpfs
############################################################################

echo "Configuring tmp fs"
chroot /mnt bash << CHROOTSCRIPT
cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount
CHROOTSCRIPT


############################################################################
# Configure Time Zone
############################################################################

echo "Configuring timezone"

chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y tzdata
echo "$TIMEZONE" > /etc/timezone
ln -sf /usr/share/zoneinfo/Europe/Zurich /etc/localtime
dpkg-reconfigure -f noninteractive tzdata
CHROOTSCRIPT

############################################################################
# Configure systemd-timesyncd
############################################################################

echo "Configuring NTP"

chrot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y systemd-timesyncd
cat > /etc/systemd/timesyncd.conf << TIMESYNC
[Time]
NTP=${NTP_SERVERS}
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
TIMESYNC

systemctl enable systemd-timesyncd
CHROOTSCRIPT

############################################################################
# Configure systemd-networkd
############################################################################

echo "Configuring systemd-networkd for interface $INTERFACE_NAME..."

chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y systemd-networkd systemd-resolved
cat > /etc/systemd/network/10-${INTERFACE_NAME}.network << NETWORK
[Match]
Name=${INTERFACE_NAME}

[Network]
Address=${IPV4_ADDRESS}/${IPV4_NETMASK}
Gateway=${IPV4_GATEWAY}
Address=${IPV6_ADDRESS}/${IPV6_NETMASK}
Gateway=${IPV6_GATEWAY}
$(for dns in $DNS_SERVERS; do echo "DNS=$dns"; done)
NETWORK

systemctl enable systemd-networkd
systemctl enable systemd-resolved
CHROOTSCRIPT

# @TODO Check if required
# # Set multiple DNS servers for the interface
# resolvectl dns "$INTERFACE_NAME" $DNS_SERVERS


# # Set search domains (optional)
# if [ -n "${SEARCH_DOMAINS:-}" ]; then
#     echo "Configuring search domains: $SEARCH_DOMAINS"
#     resolvectl domain "$INTERFACE_NAME" $SEARCH_DOMAINS
# fi

# echo "Enabling systemd-resolved"
# systemctl enable systemd-resolved


############################################################################
# Set the root password
############################################################################

echo "Setting root user password..."

chroot /mnt bash << CHROOTSCRIPT
echo "root:$ROOT_PASSWORD" | chpasswd
CHROOTSCRIPT

############################################################################
# Configure SSH key for root user
############################################################################

echo "Setting up SSH key for root user..."

chroot /mnt bash << CHROOTSCRIPT
mkdir -p /root/.ssh
chmod 700 /root/.ssh

echo "$ROOT_SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

chown -R root:root /root/.ssh
CHROOTSCRIPT

############################################################################
# Install/Configure OpenSSH server
############################################################################

echo "Installing/Configuring OpenSSH server..."
chroot /mnt bash << CHROOTSCRIPT
apt update
apt install -y openssh-server

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

sed -i "s/^#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#UsePAM yes/UsePAM no/" /etc/ssh/sshd_config
sed -i "s/^#PermitEmptyPasswords no/PermitEmptyPasswords no/" /etc/ssh/sshd_config

if [ -n "${ALLOWED_SSH_USERS:-}" ]; then
    echo "AllowUsers $ALLOWED_SSH_USERS" >> /etc/ssh/sshd_config
fi

systemctl enable ssh
CHROOTSCRIPT

############################################################################
# Install additional packages
############################################################################

if [ !  -z "$ADDITIONAL_PACKAGES" ]; then
echo "Installing additional packges"
chroot /mnt bash << CHROOTSCRIPT
DEBIAN_FRONTEND=noninteractive apt install -y $ADDITIONAL_PACKAGES
CHROOTSCRIPT
fi

############################################################################
# Configure GRUB
############################################################################

echo "Configuring GRUB"

chroot /mnt/bash << CHROOTSCRIPT
grub-probe /boot
update-initramfs -c -k all

GRUB_CMDLINE="root=ZFS=rpool/ROOT/debian"

if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE\"|" /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE\"" >> /etc/default/grub
fi

update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy

#!/bin/bash

# Enable error handling
set -e

# Step 1: Prepare ZFS cache directories and files
echo "Creating ZFS cache directory and files..."
mkdir -p /etc/zfs/zfs-list.cache
touch /etc/zfs/zfs-list.cache/bpool
touch /etc/zfs/zfs-list.cache/rpool

# Step 2: Start zed to update the cache
echo "Starting zed to update ZFS cache..."
zed -F &

# Allow zed some time to update the cache
sleep 5

# Step 3: Verify cache content
echo "Verifying ZFS cache content..."
if [[ ! -s /etc/zfs/zfs-list.cache/bpool || ! -s /etc/zfs/zfs-list.cache/rpool ]]; then
  echo "Cache is empty. Forcing cache update..."
  zfs set canmount=on bpool/BOOT/debian
  zfs set canmount=noauto rpool/ROOT/debian
  
  # Wait for zed to update
  sleep 5

  # Re-check cache
  if [[ ! -s /etc/zfs/zfs-list.cache/bpool || ! -s /etc/zfs/zfs-list.cache/rpool ]]; then
    echo "Cache update failed."
    exit 1
  fi
fi

# Step 4: Stop zed
echo "Stopping zed..."
fg >/dev/null 2>&1 || true
killall -q zed || true

# Step 5: Fix paths in cache files to eliminate /mnt
echo "Fixing paths in ZFS cache files..."
sed -Ei "s|/mnt/?|/|" /etc/zfs/zfs-list.cache/*

echo "Filesystem mount ordering for ZFS fixed successfully."
CHROOTSCRIPT


############################################################################
# Unmount filesystem
############################################################################

echo "Unmountig filesystem"

mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | \
    xargs -i{} umount -lf {}
zpool export -a


############################################################################
# Completion
############################################################################

echo "Debian installation completed successfully!"
echo "You can now reboot into the new system. Remember to change the root password after logging in."
