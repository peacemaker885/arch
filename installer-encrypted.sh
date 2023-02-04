#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:

func_standard () {
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

         pvcreate "${part_root}"
         vgcreate vg0 "${part_root}"
         lvcreate --size ${swap_size} vg0 --name swap 
         lvcreate -l +100%FREE vg0 --name root

         mkswap /dev/vg0/swap
         mkfs.ext4  /dev/vg0/root

	 # Mount the new filesystem
         swapon /dev/vg0/swap
         mount /dev/vg0/root /mnt
         mkdir /mnt/boot
         mount "${part_boot}" /mnt/boot
         mkdir /mnt/boot/efi
         mount ${part_efi} /mnt/boot/efi


	 # Install basic system
	 pacstrap /mnt $PACKAGES
 	 pacstrap /mnt grub-efi-x86_64 efibootmgr lvm2
	 genfstab -t PARTUUID /mnt >> /mnt/etc/fstab

	else
	 # MBR
	 swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
	 swap_end=$(( $swap_size + 130 + 1 ))MiB

	 parted --script "${device}" -- mklabel msdos \
	  mkpart primary ext4 1Mib 1GB \
	  set 1 boot on \
          mkpart primary ext4 1GB 100%

	 # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
	 # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
	 part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
	 part_root="$(ls ${device}* | grep -E "^${device}p?2$")"

	 wipefs "${part_boot}"
	 wipefs "${part_root}"

	 pvcreate "${part_root}"
	 vgcreate vg0 "${part_root}"
	 lvcreate --size ${swap_size} vg0 --name swap 
         lvcreate -l +100%FREE vg0 --name root

         mkfs.ext4  "${part_boot}"
         mkswap /dev/vg0/swap
	 mkfs.ext4  /dev/vg0/root

	 swapon /dev/vg0/swap
	 mount /dev/vg0/root /mnt
	 mkdir /mnt/boot
	 mount "${part_boot}" /mnt/boot

	 # Install packages
	 pacstrap /mnt $PACKAGES
  	 pacstrap /mnt grub lvm2
	 genfstab -t PARTUUID /mnt >> /mnt/etc/fstab

        fi

        echo ${hostname} > /mnt/etc/hostname

	# install grub
        arch-chroot /mnt grub-install $device
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

	#read -n 1 -s -r -p "Processing Modules. Please press any key to continue..."
        MODULES_CMD="MODULES=(ext4)"
        sed -i "s|^MODULES=.*|$MODULES_CMD|" /mnt/etc/mkinitcpio.conf
        HOOKS_CMD="HOOKS=(base udev autodetect keyboard keymap consolefont modconf block lvm2 filesystems fsck)"
        sed -i "s|HOOKS=.*|$HOOKS_CMD|" /mnt/etc/mkinitcpio.conf
        arch-chroot /mnt mkinitcpio -p linux-lts
 
}

func_encrypted () {
	### Setup the disk and partitions ###     
	echo Partitioning Disk                                     
	# UEFI                                                                                                                
	if [ -d /sys/firmware/efi ]; then                                                                                     
 	 #read -n 1 -s -r -p "UEFI system found. Press any key to continue"
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
	 mount /dev/mapper/vg0-root /mnt # 
	 swapon /dev/mapper/vg0-swap 
	 mkdir /mnt/boot
	 mount ${part_boot} /mnt/boot
	 mkdir /mnt/boot/efi
	 mount ${part_efi} /mnt/boot/efi

	 #read -n 1 -s -r -p "Press any key to continue"

	 # Install basic system
	 pacstrap /mnt $PACKAGES
	 pacstrap /mnt grub-efi-x86_64 efibootmgr lvm2
	 genfstab -t PARTUUID /mnt >> /mnt/etc/fstab

	else
	 # MBR
	 #read -n 1 -s -r -p "BIOS system found.  Press any key to continue\n"
	 swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
	 swap_end=$(( $swap_size + 129 + 1 ))MiB

	 parted --script "${device}" -- mklabel msdos \
	  mkpart primary ext4 1Mib 1GB \
	  set 1 boot on \
	  mkpart primary ext4 1GB 100%

	 # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
	 # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
	 part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
	 part_root="$(ls ${device}* | grep -E "^${device}p?2$")"

	 wipefs "${part_boot}"
	 wipefs "${part_root}"

	 mkfs.ext4  ${part_boot}
	 cryptsetup -c aes-xts-plain64 -y --use-random luksFormat ${part_root}
	 cryptsetup luksOpen ${part_root} luks

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
	 pacstrap /mnt grub lvm2
	 genfstab -pU /mnt >> /mnt/etc/fstab
	 echo ${hostname} > /mnt/etc/hostname

	fi

	#read -n 1 -s -r -p "Processing GRUB. Please press any key to continue..."
	arch-chroot /mnt grub-install $device
 	GRUB_CMD="GRUB_CMDLINE_LINUX=\"cryptdevice=$part_root:luks:allow-discards\""
 	arch-chroot /mnt sed -i "s|^GRUB_CMDLINE_LINUX=.*|$GRUB_CMD|" /etc/default/grub
 	arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

	#read -n 1 -s -r -p "Processing Modules. Please press any key to continue..."
	MODULES_CMD="MODULES=(ext4)"
	sed -i "s|^MODULES=.*|$MODULES_CMD|" /mnt/etc/mkinitcpio.conf
	HOOKS_CMD="HOOKS=(base udev autodetect keyboard keymap consolefont modconf block encrypt lvm2 filesystems fsck)"
	sed -i "s|HOOKS=.*|$HOOKS_CMD|" /mnt/etc/mkinitcpio.conf
	arch-chroot /mnt mkinitcpio -p linux-lts

}

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

echo "Updating mirror list"
reflector --verbose --country 'United States' --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

# echo "Updating mirror list"
# curl -sL "$MIRRORLIST_URL" | \
#    sed -e 's/^#Server/Server/' -e '/^#/d' | \
#    tee /etc/pacman.d/mirrorlist

PACKAGES="base linux-lts sudo linux-firmware man-db man-pages \
          vi rsync iwd dialog openssh dhcpcd \
          exfat-utils zip unzip git polkit reflector inetutils bind-tools"

timedatectl set-ntp true
read -p "Is this a (r)egular install or (e)ncrypted install? (r/e): " type
case $type in 
	r)
		func_standard
	;;
	e)
		func_encrypted
	;;
esac

# Hostname
echo "${hostname}" > /mnt/etc/hostname

# Grant all to wheel members
arch-chroot /mnt sed -i s/\#\ \%wheel\ ALL=\(ALL:ALL\)\ ALL/\%wheel\ ALL=\(ALL:ALL\)\ ALL/g /etc/sudoers
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

echo "$user:$password" | arch-chroot /mnt chpasswd
echo "root:$password" | arch-chroot /mnt chpasswd
echo "Base install completed.  Please reboot and enjoy!"

