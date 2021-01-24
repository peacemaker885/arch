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
          exfat-utils zip unzip git polkit reflector lvm2"

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
  mkpart primary ext2 129Mib 329MiB \
  mkpart primary ext4 329MiB 100%

 # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1
 # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
 part_efi="$(ls ${device}* | grep -E "^${device}p?1$")"
 part_boot="$(ls ${device}* | grep -E "^${device}p?2$")"
 part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

 wipefs "${part_efi}"
 wipefs "${part_boot}"
 wipefs "${part_root}"

 mkfs.vfat -F32 "${part_efi}"
 mkfs.ext2 "${part_boot}"
 cryptsetup -c aes-xts-plain64 -y --use-random luksFormat ${part_root}
 cryptsetup luksOpen ${part_root} luks

 pvcreate /dev/mapper/luks
 vgcreate vg0 /dev/mapper/luks
 lvcreate --size ${swap_size} vg0 --name swap
 lvcreate -l +100%FREE vg0 --name root

 mkfs.ext4 /dev/mapper/vg0-root
 mkswap /dev/mapper/vg0-swap

 # Mount the new system 
 mount /dev/mapper/vg0-root /mnt # /mnt is the installed system
 swapon /dev/mapper/vg0-swap # Not needed but a good thing to test
 mkdir /mnt/boot
 mount ${part_boot} /mnt/boot
 mkdir /mnt/boot/efi
 mount ${part_efi} /mnt/boot/efi

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
  mkpart primary ext4 1GB 100%

 # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
 # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
 part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
 part_enc="$(ls ${device}* | grep -E "^${device}p?2$")"

 wipefs "${part_boot}"
 wipefs "${part_enc}"

 mkfs.ext4  ${part_boot}
 cryptsetup -c aes-xts-plain64 -y --use-random luksFormat ${part_enc}
 cryptsetup luksOpen ${part_enc} luks

 pvcreate /dev/mapper/luks
 vgcreate vg0 /dev/mapper/luks
 lvcreate --size ${swap_size} vg0 --name swap
 lvcreate -l +100%FREE vg0 --name root

 mkfs.ext4 /dev/mapper/vg0-root
 mkswap /dev/mapper/vg0-swap

 swapon /dev/mapper/vg0-swap
 mount /dev/mapper/vg0-root /mnt
 mkdir /mnt/boot
 mount ${part_boot} /mnt/boot

 # Install packages
 pacstrap /mnt $PACKAGES
 genfstab -pU /mnt >> /mnt/etc/fstab
 echo ${hostname} > /mnt/etc/hostname

 arch-chroot /mnt grub-install $device
 GRUB_CMD="GRUB_CMDLINE_LINUX=\"cryptdevice=$part_enc:luks:allow-discards\""
 arch-chroot /mnt sed -i "s|^GRUB_CMDLINE_LINUX=.*|$GRUB_CMD|" /etc/default/grub
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
MODULES_CMD="MODULES=(ext4)"
sed -i "s|^MODULES=.*|$MODULES_CMD|" /mnt/etc/mkinitcpio.conf
HOOKS_CMD="HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)"
sed -i "s|HOOKS=.*|$HOOKS_CMD|" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux-lts

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
