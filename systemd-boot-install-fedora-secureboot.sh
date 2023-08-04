#!/usr/bin/bash

# A script to replace grub with systemd-boot in Fedora. This version does use secure boot,
# and is rewritten to make use of DNF5 features and to be a test script for the kernel generation
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

if [[ $(lsmod | grep -c nvidia) -gt 0 ]]; then
	log "The nvidia driver is detected on this system. Aborting converting this system"
	log "to use systemd-boot with secure boot, since the nvidia driver is known to have"
	log "issues. For more info (and how to remedy this), see https://rpmfusion.org/Howto/Secure%20Boot"
	exit 0
fi

log "Before running this script make sure your system is fully updated!"

# Install the stuff sbctl needs
sudo dnf install asciidoc golang --setopt=install_weak_deps=False $DNFOPTIONS

# Get the source for sbctl from GitHub
VERSION=0.11
cd /tmp/ || {
	log "Could not switch directory to /tmp. Exiting."
	exit 1
}

curl -L https://github.com/Foxboron/sbctl/releases/download/$VERSION/sbctl-$VERSION.tar.gz | tar -zxvf -
cd sbctl-$VERSION || {
	log "Could not switch to the sbctl directory. Exiting."
	exit 1
}

systemd-cat -t $IDENTIFIER make
systemd-cat -t $IDENTIFIER sudo make install

# Create and enroll the secure boot key(s)
log "Creating and enrolling secure boot keys"
systemd-cat -t $IDENTIFIER sudo sbctl create-keys
systemd-cat -t $IDENTIFIER sudo sbctl enroll-keys || {

	# If the enrolling fails you can manually export the key(s) and import them into the UEFI
	# yourself. To export the key(s) run the following command:
	#
	# sudo openssl x509 -in /usr/share/secureboot/keys/db/db.pem -outform DER -out /boot/efi/EFI/db.cer
	#
	# After that, reboot into your machines firmware interface (with `sudo systemctl reboot --firmware-setup`)
	# and mannually add the db.cer key file into your UEFI. For specifics on how to do that, see the motherboard
	# guide from your motherboard OEM / vendor.
	# Once the key has been imported and you have rebooted `sudo sbctl status` should show info about the key,
	# setup mode and secure boot status.

	log "Something went wrong with enrolling the keys."
	log "Check the journalctl output to see what. Exiting."
	exit 1
}

# Remove grub2, grubby, and shim first.
log "Removing grub2, grubby, and shim packages."
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
sudo mkdir -p /boot/efi && sudo mouunt "$ESPSOURCE" /boot/efi

# Reset the ESP variable to reflect the new situation
ESP=$(bootctl -p)

# Make sure systemd-boot-unsigned is installed. If it is, install the boot code.
dnf list installed systemd-boot-unsigned || {
	sudo dnf install systemd-boot-unsigned $DNFOPTIONS
}

# Install the systemd-boot boot code
systemd-cat -t $IDENTIFIER sudo bootctl install || {
	log "Something went wrong during the installation of the systemd-boot bootcode."
	log "Check the journal to see what."
	exit 1
}

# Sign the systemd-boot files
sudo sbctl sign "$ESP/EFI/systemd/systemd-bootx64.efi"
sudo sbctl sign "$ESP/EFI/BOOT/BOOTX64.EFI"

# Configure systemd-boot / kernel-install
log "Configuring systemd-boot / kernel-install"

if ! [[ -f /etc/kernel/install.conf ]]; then
	sudo touch /etc/kernel/install.conf
else
	sudo cp /etc/kernel/install.conf /etc/kernel/install.conf.original
fi

echo "layout=bls" | sudo tee /etc/kernel/install.conf

sudo dnf install sbsigntools $DNFOPTIONS
sudo mkdir -p /etc/systemd/system/systemd-boot-update.service.d
sudo tee /etc/systemd/system/systemd-boot-update.service.d/override.conf << EOT
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sbverify --cert /usr/share/secureboot/keys/db/db.pem "$ESP/EFI/systemd-bootx64.efi" || sbctl sign "$ESP/EFI/systemd-bootx64.efi"'
ExecStart=/bin/sh -c 'sbverify --cert /usr/share/secureboot/keys/db/db.pem "$ESP/EFI/BOOT/BOOTX64.EFI" || sbctl sign "$ESP/EFI/BOOT/BOOTX64.EFI"'
EOT

sudo systemctl daemon-reload

# Configure dracut to use the keys to sign the kernel and initramfs
log "Configuring dracut."
sudo tee /etc/dracut.conf.d/systemd-boot-signed.conf <<EOT
uefi="yes"
uefi_secureboot_cert="/usr/share/secureboot/keys/db/db.pem"
uefi_secureboot_key="/usr/share/secureboot/keys/db/db.key"
EOT

# Time to regenerate the kernel image(s) so they get rebuilt and signed and put into their ight
# location on the ESP. This used to be done with a call to kernel-install, but a simple
# reinstallation of `kernel-core` does the same job.
# The only caveat here is that the system *has to be* fully updated, otherwise DNF5 will
# throw a fit.
log "Reinstalling / regenerating / signing kernel image(s)"
systemd-cat -t $IDENTIFIER sudo dnf reinstall kernel-core $DNFOPTIONS || {
	log "Something went wrong during the reinstallation of the kernel-core package."
	log "Check the DNF output for more info."
	exit 1
}

# If all went well this script has done it's job, time to exit and reboot
log "systemd-boot should not have been fully configured and installed."
log "Reboot your system now and cross your fingers."

exit 0