#!/usr/bin/bash

# A script to replace grub with systemd-boot in Fedora. This version doesn't use secure boot.

# This identifier is used in journalctl and systemd-cat. If you want to see the script output
# in the journal use
#
# journalctl -t <value of $IDENTIFIER>
IDENTIFIER=bootctl-conversion

# These options get passed to DNF. You can add things like
# "-y" here for example. See `man dnf` for available options.
DNFOPTIONS="-y"

# With this function the output passed gets written into the system journal and output to screen.
function log {
	systemd-cat -t ${IDENTIFIER} echo "$1"
	echo "$1"
}

log "Before running this script make sure your system is fully up to date!"

log "Ensure everything needed is present."
log "Check presence of bootctl..."

which bootctl || {
	log "FAILED. bootctl seems to be not installed!"
	exit 1
}

# Make sure the Systemd-Boot EFI-loader is present,
# which bootctl will attempt to copy to the ESP-partition on installation
log "Check if systemd-boot EFI loader is installed"
SYSTEMD_BOOT_EFI_LOADER="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
if ! [[ -f $SYSTEMD_BOOT_EFI_LOADER ]]; then
	log "FAILED. Checking if systemd-boot-unsigned is installed..."

	dnf list --installed systemd-boot-unsigned || {
		log "systemd-boot-unsigned is not installed. Trying to install..."
		dnf install systemd-boot-unsigned $DNFOPTIONS
	}

	if ! [[ -f $SYSTEMD_BOOT_EFI_LOADER ]]; then
		log "Failed to aquire Systemd-Boot EFI-loader. Exiting..."
		exit 1
	fi
fi

# Make sure objcopy is installed (provided by binutils), since that's needed for kernel generation
# with dracut.
log "Check if objcopy is installed..."
which objcopy || {
	log "objcopy missing. Attempting to install binutils which should provide it..."
	dnf install binutils $DNFOPTIONS

	which objcopy || {
		log "Failed to aquire objcopy. Out of options. Exiting..."
		exit 1
	}
}

# The current implementation of systemd-boot with grub on Fedora creates and uses /boot/loader
# to contain kernel image(s). Remove that, so the installation of systemd-boot later on doesn't
# use that and messes up the rest of the install / configured defaults.
log "Removing the /boot/loader/ folder (and it's contents) for a proper systemd-boot install."
rm -rf /boot/loader/

# Configure systemd-boot with 'sane defaults'
if ! [[ -f /etc/kernel/cmdline ]]; then
	log "Configuring systemd-boot with sane defaults"
	cut -d " " -f2- /proc/cmdline | tee /etc/kernel/cmdline
fi

if [[ -f /etc/kernel/install.conf ]]; then
	log "Backing up the original /etc/kernel/install.conf file to /etc/kernel/install.conf.original"
	cp /etc/kernel/install.conf /etc/kernel/install.conf.original
fi

echo "layout=bls" | tee /etc/kernel/install.conf

# Overwrite configs in /usr/lib/kernel/install.d with version (symlinks to /dev/null)
# in /etc/kernel
log "Making sure /usr/lib/kernel/install.d/20-grubby.install is ignored."
ln -sv /dev/null /etc/kernel/install.d/20-grubby.install

# Update systemd-boot on demand.
DNFPLUGIN=python3-dnf-plugin-post-transaction-actions
if [[ $(dnf list installed $DNFPLUGIN 2>/dev/null | wc -l) -eq 0 ]]; then
	dnf install $DNFPLUGIN $DNFOPTIONS
fi

SYSTEMD_UDEV_FILE="/etc/dnf/plugins/post-transaction-actions.d/systemd-udev.action"
if ! [[ -f $SYSTEMD_UDEV_FILE ]]; then
	echo "systemd-udev:in:bootctl update" | tee $SYSTEMD_UDEV_FILE
fi

# installing Systemd-Boot bootloader to ESP partition
log "Installing Systemd-Boot to ESP"
bootctl install || {
	log "Failed to install new bootloader to ESP. Exitting..."
	exit 1
}

# Removal of GRUB2
log "Time to remove grub2"
rm -rf /etc/dnf/protected.d/{grub*,shim}.conf
dnf remove $DNFOPTIONS grubby "grub2*" "shim*"

if [[ -f /etc/dnf/dnf.conf ]]; then
	cp /etc/dnf/dnf.conf /etc/dnf/dnf.conf.original
fi

echo "ignore=grubby grub2* shim*" | tee -a /etc/dnf/dnf.conf

# Time for some cleaning
log "Cleaning up files and folders that are no longer required."
rm -rf /boot/config*
rm -rf /boot/extlinux
rm -rf /boot/grub2/
rm -rf /boot/initramfs*
rm -rf /boot/symvers*
rm -rf /boot/System.map*
rm -rf /boot/vmlinuz*

# (re)generate kernel images so they get "unified"
log"Generating new kernel images"
for kver in $(dnf list installed kernel | tail -n +2 | awk '{print $2".x86_64"}'); do
	kernel-install -v add "$kver" "/usr/lib/modules/$kver/vmlinuz"
done

echo -e "\n"

# The end!
log "systemd-boot *should* have been fully installed and configured. Reboot your system now and cross your fingers!"
exit 0
