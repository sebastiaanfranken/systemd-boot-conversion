#!/usr/bin/bash

# A script to replace grub with systemd-boot in Fedora. This version does not use secure-boot,
# and is rewritten to make sure of dnf5 features and to be a test script for the kernel generation
# bug(s) in dracut.

# This identifier is used in journalctl and systemd-cat. If you want to see the script output in the
# journal use:
#
# journalctl -t <value of $IDENTIFIER>
IDENTIFIER=bootctl-conversion

# These options get passed to DNF. You can add all options here that DNF accepts, see `man dnf`.
DNFOPTIONS="-y"

# The mountpoint of your ESP
ESP=$(bootctl -p)

# The source of the ESP
ESPSOURCE=$(findmnt -o source -n "$ESP")

# With this function the output passed gets written to the system journal and to the screen.
function log {
	systemd-cat -t $IDENTIFIER echo "$1"
	echo "$1"
}

log "Before running this script make sure your system is fully updated!"

# Remove grub2, grubby, and shim first.
log "Removing grub2, grubby, and shim pacakges."
sudo rm -f /etc/dnf/protected.d/{grub*,shim}.conf
sudo dnf remove grubby grub2* shim $DNFOPTIONS

# Make sure objcopy is installed (provided by binutils), since that's needed for kernel generation
# with dracut.
dnf list installed binutils || {
	sudo dnf install binutils $DNFOPTIONS
}

# Unmount the ESP
sudo umount "$ESP"

# The current implementation of systemd-boot with grub on Fedora creates and uses the /boot/loader
# folder to contain kernel image(s) and more. Remove that now.
#
# Actually, since the ESP is no longer mounted just remove everything from /boot.
log "Cleaning up /boot"
sudo rm -rf /boot/*

# Create the folder /boot/efi since we just removed that and remount the ESP to it.
log "Recreating the /boot/efi folder and mounting the ESP back to it."
sudo mkdir -p /boot/efi && sudo mount "$ESPSOURCE" /boot/efi

# Make sure systemd-boot-unsigned is installed. If it is, install the boot code.
dnf list installed systemd-boot-unsigned || {
	sudo dnf install systemd-boot-unsigned $DNFOPTIONS
}

systemd-cat -t $IDENTIFIER sudo bootctl install || {
	log "Something went wrong during the installation of the systemd-boot bootcode."
	log "Check the journal to see what."
	exit 1
}

# Configure systemd-boot / kernel-install
log "Configuring systemd-boot / kernel-install"

if ! [[ -f /etc/kernel/install.conf ]]; then
	sudo touch /etc/kernel/install.conf
else
	sudo cp /etc/kernel/install.conf /etc/kernel/install.conf.original
fi

echo "layout=bls" | sudo tee -a /etc/kernel/install.conf

# Time to regenerate the kernel image(s) so they get rebuilt and put into their right
# location on the ESP. This used to be done with a call to kernel-install, but a simple
# reinstallation of `kenel-core` does the same job.
# The only caveat here is that the system *has to be* fully updated, otherwise DNF5 will
# throw a fit.
log "Reinstalling / regenerating kernel images"
sudo dnf reinstall kernel-core $DNFOPTIONS || {
	log "Something went wrong during the reinstallation of the kernel-core package."
	log "Check the DNF output for more info."
	exit 1
}

# If all went well this script has done it's job, time to exit and reboot
log "systemd-boot should have been fully configured and installed."
log "Reboot your system now and cross your fingers."

exit 0