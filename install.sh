#!/bin/bash

# =================================================================
# EXAMEN : Administration Avancée Linux
# Script d'installation Arch Linux sur une VM
# =================================================================

set -e  # Arrêt en cas d'erreur

# --- Variables ---
DISK="/dev/sda"
TIMEZONE="Europe/Paris"
HOSTNAME="arch"
USER_FILS="fils"
USER_PAPA="papa"
PASSWORD="azerty123"

echo "===== Début de l'installation  ====="

# 0. Nettoyage initial
umount -R /mnt 2>/dev/null || true
vgchange -an 2>/dev/null || true
cryptsetup close cryptlvm 2>/dev/null || true

# 1. Partitionnement GPT (UEFI)
echo "[1/10] Partitionnement du disque..."
parted ${DISK} --script mklabel gpt
parted ${DISK} --script mkpart ESP fat32 1MiB 513MiB
parted ${DISK} --script set 1 esp on
parted ${DISK} --script mkpart primary 513MiB 100%

BOOT_PART="${DISK}1"
LVM_PART="${DISK}2"

# 2. Chiffrement LUKS
echo "[2/10] Initialisation LUKS..."
echo -n "${PASSWORD}" | cryptsetup luksFormat ${LVM_PART} -
echo -n "${PASSWORD}" | cryptsetup open ${LVM_PART} cryptlvm -

# 3. Configuration LVM (80G)
echo "[3/10] Configuration des Volumes Logiques (LVM)..."
pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm

# Découpage 
lvcreate -L 25G vg0 -n root              # Système
lvcreate -L 15G vg0 -n home              # Utilisateurs
lvcreate -L 15G vg0 -n virtualbox        # Volume dédié VirtualBox
lvcreate -L 5G  vg0 -n shared            # Dossier partagé "Memes"
lvcreate -L 10G vg0 -n encrypted_manual  # Le volume 10G pour Papa

# 4. Formatage
echo "[4/10] Formatage des systèmes de fichiers..."
mkfs.fat -F32 ${BOOT_PART}
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/virtualbox
mkfs.ext4 /dev/vg0/shared

# Configuration LUKS sur le volume manuel 
echo -n "${PASSWORD}" | cryptsetup luksFormat /dev/vg0/encrypted_manual -

# 5. Montage
echo "[5/10] Montage des partitions..."
mount /dev/vg0/root /mnt
mkdir -p /mnt/{boot,home,var/lib/virtualbox,home/partage_familial}

mount ${BOOT_PART} /mnt/boot
mount /dev/vg0/home /mnt/home
mount /dev/vg0/virtualbox /mnt/var/lib/virtualbox
mount /dev/vg0/shared /mnt/home/partage_familial

# 6. Installation 
echo "[6/10] Installation des paquets..."
pacstrap /mnt base linux linux-firmware lvm2 cryptsetup sudo networkmanager \
             gcc make gdb xorg-server xorg-xinit i3-wm i3status dmenu xterm \
             firefox virtualbox virtualbox-host-modules-arch htop git vim

# 7. Génération du FSTAB
genfstab -U /mnt >> /mnt/etc/fstab

# 8. Configuration interne 
echo "[8/10] Configuration du système ..."
LUKS_UUID=$(blkid -s UUID -o value ${LVM_PART})

arch-chroot /mnt /bin/bash <<EOF
# Localisation & Langue
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "KEYMAP=fr" > /etc/vconsole.conf

# Réseau
echo "${HOSTNAME}" > /etc/hostname

# Initramfs avec LUKS et LVM
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect keyboard keymap modconf block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader GRUB
pacman -S --noconfirm grub efibootmgr
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:cryptlvm root=/dev/vg0/root\"|" /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Création des comptes
groupadd family_share
useradd -m -G wheel,vboxusers,family_share -s /bin/bash ${USER_PAPA}
useradd -m -G family_share -s /bin/bash ${USER_FILS}

echo "${USER_PAPA}:${PASSWORD}" | chpasswd
echo "${USER_FILS}:${PASSWORD}" | chpasswd
echo "root:${PASSWORD}" | chpasswd

# Configuration Sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Droits sur le dossier partagé (5G)
chown :family_share /home/partage_familial
chmod 770 /home/partage_familial

# Activation Services
systemctl enable NetworkManager
EOF

# 9. Config i3 pour le pere
echo "[9/10] Configuration i3..."
arch-chroot /mnt /bin/bash <<EOF
mkdir -p /home/${USER_PAPA}/.config/i3
cat > /home/${USER_PAPA}/.config/i3/config <<I3CONF
set \$mod Mod4
font pango:monospace 10
bindsym \$mod+Return exec xterm
bindsym \$mod+d exec dmenu_run
bindsym \$mod+Shift+q kill
bar {
    status_command i3status
    position top
}
I3CONF
echo "exec i3" > /home/${USER_PAPA}/.xinitrc
chown -R ${USER_PAPA}:${USER_PAPA} /home/${USER_PAPA}
EOF

echo "[10/10] Installation terminée redémarrez avec 'reboot'."
