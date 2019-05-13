#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# check internet connection
ping -c1 -q 8.8.8.8
status=$?
case $status in
    0)
        echo "Internet connection is available. Will now install";
    ;;
    1)
        echo "Network unreachable or host not responding to pings. Please check interet connection.";
	exit
    ;;
    2)
        echo "No route to host or other error. Please check internet connection";
	exit
    ;;
esac

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0) || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

hidpi=$(dialog --stdout --inputbox "HIDPI Screen? (Y/N)" 0 0) || exit 1
clear

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installtion disk" 0 0 0 ${devicelist}) || exit 1
clear

MIRRORLIST_URL="https://www.archlinux.org/mirrorlist/?country=US&protocol=https&use_mirror_status=on"

pacman -Sy --noconfirm pacman-contrib

echo "Updating mirror list"
curl -s "$MIRRORLIST_URL" | \
    sed -e 's/^#Server/Server/' -e '/^#/d' | \
    rankmirrors -n 5 - > /etc/pacman.d/mirrorlist

### Set up logging ###
#exec 1> >(tee "stdout.log")
#exec 2> >(tee "stderr.log")

timedatectl set-ntp true

### Setup the disk and partitions ###
echo Partitioning Disk
# UEFI
if [ -d /sys/firmware/efi ]; then
 swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
 swap_end=$(( $swap_size + 129 + 1 ))MiB

 parted --script "${device}" -- mklabel gpt \
  mkpart ESP fat32 1Mib 129MiB \
  set 1 boot on \
  mkpart primary linux-swap 129MiB ${swap_end} \
  mkpart primary ext4 ${swap_end} 100%

 # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1
 # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
 part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
 part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
 part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

 wipefs "${part_boot}"
 wipefs "${part_swap}"
 wipefs "${part_root}"

 mkfs.vfat -F32 "${part_boot}"
 mkswap "${part_swap}"
 mkfs.f2fs -f "${part_root}"

 swapon "${part_swap}"
 mount "${part_root}" /mnt
 mkdir /mnt/boot
 mount "${part_boot}" /mnt/boot
 
 # Install basic system
 pacstrap /mnt base linux-lts sudo
 genfstab -t PARTUUID /mnt >> /mnt/etc/fstab

 # Install bootloader
 arch-chroot /mnt bootctl install

cat <<EOF > /mnt/boot/loader/loader.conf
default arch
EOF

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux-lts
initrd   /initramfs-linux-lts.img
options  root=PARTUUID=$(blkid -s PARTUUID -o value "$part_root") rw
EOF

else
 # MBR
 swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
 swap_end=$(( $swap_size + 129 + 1 ))MiB

 parted --script "${device}" -- mklabel msdos \
  mkpart primary ext4 1Mib 1GB \
  set 1 boot on \
  mkpart primary linux-swap 1GB ${swap_end} \
  mkpart primary ext4 ${swap_end} 100%

 # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
 # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
 part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
 part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
 part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

 wipefs "${part_boot}"
 wipefs "${part_swap}"
 wipefs "${part_root}"

 mkfs.ext4  "${part_boot}"
 mkswap "${part_swap}"
 mkfs.ext4 "${part_root}"

 swapon "${part_swap}"
 mount "${part_root}" /mnt
 mkdir /mnt/boot
 mount "${part_boot}" /mnt/boot

 # Install packages
 pacstrap /mnt base linux-lts grub sudo
 genfstab -t PARTUUID /mnt >> /mnt/etc/fstab
 echo "${hostname}" > /mnt/etc/hostname

 arch-chroot /mnt grub-install /dev/sda
 arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

fi

# Hostname
echo "${hostname}" > /mnt/etc/hostname

# Grant all to wheel members
arch-chroot /mnt sed -i s/\#\ %wheel\ ALL=\(ALL\)\ ALL/\%wheel\ ALL=\(ALL\)\ ALL/g /etc/sudoers
arch-chroot /mnt useradd -m $user -G wheel -s /bin/bash

# Settings
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
arch-chroot /mnt sed -i s/\#en_US.UTF-8\ UTF-8/en_US.UTF-8\ UTF-8/g /etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt ln -sf /usr/share/zoneinfo/US/Pacific /etc/localtime
arch-chroot /mnt hwclock --systohc

# Make console more readable after install if HIDPI screen
if [[ "$hidpi" =~ ^([yY])+$ ]]
then
    echo "FONT=latarcyrheb-sun32" | sudo tee /mnt/etc/vconsole.conf
fi

# Install some stuff. Note this installs the LTS kernel
pacstrap /mnt wireless_tools wpa_supplicant dhcp iw dialog sudo openssh exfat-utils zip unzip powertop git polkit
arch-chroot /mnt pacman -R linux --noconfirm
arch-chroot /mnt systemctl enable dhcpcd

# If Dual booting with Windows 10 under MBR
# pacstrap /mmt os-prober 
# arch-chroot /mnt mkdir /mnt/windows
# mount /dev/sda1 /mnt/windows
# arch-chroot /mnt os-prober
# arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt
