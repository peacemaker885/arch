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
read -p 'Hostname: ' hostname
read -p 'Username: ' user
read -sp 'Password: ' password
echo
read -sp 'repeat Password: ' password2
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
printf "\n$devicelist\n"
read -p "Device to install in: " device

MIRRORLIST_URL="https://www.archlinux.org/mirrorlist/?country=US&protocol=https&use_mirror_status=on"

echo "Updating mirror list"
curl -sL "$MIRRORLIST_URL" | \
    sed -e 's/^#Server/Server/' -e '/^#/d' | \
    tee /etc/pacman.d/mirrorlist

PACKAGES="base linux-lts grub sudo linux-firmware man-db man-pages \
          vi iwd wpa_supplicant dialog openssh dhcpcd \
          exfat-utils zip unzip git polkit reflector"

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
 pacstrap /mnt $PACKAGES
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
 pacstrap /mnt $PACKAGES
 genfstab -t PARTUUID /mnt >> /mnt/etc/fstab
 echo "${hostname}" > /mnt/etc/hostname

 arch-chroot /mnt grub-install $device
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
#if [[ "$hidpi" =~ ^([yY])+$ ]]
#then
#    echo "FONT=latarcyrheb-sun32" | sudo tee /mnt/etc/vconsole.conf
#fi

# Enable networking
arch-chroot /mnt systemctl enable iwd
arch-chroot /mnt mkdir /etc/iwd
echo -e "[General]\nEnableNetworkConfiguration=true" | tee /mnt/etc/iwd/main.conf

# If Dual booting with Windows 10 under MBR
# pacstrap /mmt os-prober 
# arch-chroot /mnt mkdir /mnt/windows
# mount /dev/sda1 /mnt/windows
# arch-chroot /mnt os-prober
# arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

echo "$user:$password" | arch-chroot /mnt chpasswd
echo "root:$password" | arch-chroot /mnt chpasswd
echo "Base install completed.  Please reboot and enjoy!"
