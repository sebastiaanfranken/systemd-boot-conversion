#!/bin/bash

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
	systemd-cat -t $IDENTIFIER echo "$1"
	echo "$1"
}

if [[ $(lsmod | grep nvidia -c) -gt 0 ]]; then
	log "The nvidia driver is detected on this system. Aborting converting this system to"
	log "use systemd-boot with secure boot, since the nvidia driver is known to cause breakages."
	exit 0
fi

log "Before running this script make sure your system is fully up to date!"

# Installation of components for sbctl
log "Installing components that sbctl requires."
sudo dnf install asciidoc golang --setopt=install_weak_deps=False $DNFOPTIONS

# Getting the source. The VERSION variable should be updated if a new release
# is pushed to Github
VERSION=0.11
cd /tmp
curl -L https://github.com/Foxboron/sbctl/releases/download/$VERSION/sbctl-$VERSION.tar.gz | tar -zxvf -
cd sbctl-$VERSION
make
sudo make install

# Creating and enrolling secure boot keys
log "Creating and enrolling secure boot keys."
sudo sbctl create-keys
sudo sbctl enroll-keys

# Should the enroll-keys step fail you can manually export the newly created key and import it into your UEFI
# by hand. To export it run the following:
#
# sudo openssl x509 -in /usr/share/secureboot/keys/db/db.pem -outform DER -out /boot/efi/EFI/fedora/DB.cer
#
# Reboot into your UEFI after that and import the "DB.cer" file
# After that `sudo sbctl statsu` should return info about the key, setup mode and secure boot status.

log "Removing /boot/loader folder (and contents) for a proper systemd-boot install"
sudo rm -rf /boot/loader/

# Installing systemd-boot properly
log "Installing systemd-boot fully."

if [[ $(dnf list installed systemd-boot 2>/dev/null | wc -l) -eq 0 ]]; then
	log "Installing systemd-boot package first."
	sudo dnf install systemd-boot $DNFOPTIONS
fi

systemd-cat -t $IDENTIFIER sudo bootctl install

if [[ $? -gt 0 ]]; then
	log "Something went wrong with the installation of systemd-boot."
	log "See the full log with 'journalctl -t $IDENTIFIER'."
	log "Exiting now."
	exit 1
fi

log "Signing the systemd-boot EFI files with the secure boot key."
sudo sbctl sign /boot/efi/EFI/systemd/systemd-bootx64.efi
sudo sbctl sign /boot/efi/EFI/BOOT/BOOTX64.EFI

log "Configuring systemd-boot"
sudo dnf install sbsigntools $DNFOPTIONS
sudo mkdir -p /etc/systemd/system/systemd-boot-update.service.d/

sudo tee /etc/systemd/system/systemd-boot-update.service.d <<EOT
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sbverify --cert /usr/share/secureboot/keys/db/db.pem /boot/efi/EFI/systemd/systemd-bootx64.efi || sbctl sign /boot/efi/EFI/systemd/systemd-bootx64.efi'
ExecStart=/bin/sh -c 'sbverify --cert /usr/share/secureboot/keys/db/db.pem /boot/efi/EFI/BOOT/BOOTX64.EFI || sbctl sign /boot/efi/EFI/BOOT/BOOTX64.efi'
EOT

sudo systemctl daemon-reload

log "Configuring systemd-boot with sane defaults."
cat /proc/cmdline | cut -d " " -f2- | sudo tee /etc/kernel/cmdline
echo "layout=bls" | sudo tee /etc/kernel/install.conf
sudo ln -s /dev/null /etc/kernel/install.d/51-dracut-rescue.install
sudo ln -s /dev/null /etc/kernel/install.d/92-crashkernel.install

sudo tee /etc/kernel/install.d/95-use-signed-images.install <<"EOT"
#!/bin/bash

COMMAND="$1"
KERNEL_VERSION="$2"
ENTRY_DIR_ABS="$3"

if ! [[ ${COMMAND} == add ]]; then
	exit 1
fi

MACHINE_ID="${KERNEL_INSTALL_MACHINE_ID}"
BOOT_ROOT="${KERNEL_INSTALL_BOOT_ROOT}"

if [[ -f /etc/kernel/tries ]]; then
	read -r TRIES < /etc/kernel/tries
	if ! [[ "${TRIES}" =~ ^[0-9]+$ ]]; then
		echo "/etc/kernel/tries does not contain an integer." >&2
		exit 1
	fi
	
	LOADER_ENTRY="${BOOT_ROOT}/loader/entries/${MACHINE_ID}-${KERNEL_VERSION}+${TRIES}.conf"
else
	LOADER_ENTRY="${BOOT_ROOT}/loader/entries/${MACHINE_ID}-${KERNEL_VERSION}.conf"
fi

sed -i "^/initrd/d" "${LOADER_ENTRY}"
sed -i "^/linux/s/linux$/initrd/" "${LOADER_ENTRY}"

if [[ -f "${BOOT_ROOT}/${MACHINE_ID}/${KERNEL_VERSION}/linux" ]]; then
	rm "${BOOT_ROOT}/${MACHINE_ID}/${KERNEL_VERSION}/linux"
fi
EOT

sudo chmod +x /etc/kernel/install.d/95-use-signed-images.install

# Configure dracut
log "Configuring dracut."
sudo tee /etc/dracut.conf.d/local-modificatiions.conf <<EOT
uefi="yes"
uefi_secureboot_cert="/usr/share/secureboot/keys/db/db.pem"
uefi_secureboot_key="/usr/share/secureboot/keys/db/db.key"
dracut_rescue_image="no"
hostonly="yes"
EOT

# Removal of grubby, grub2* and shim*
log "Removing grubby, grub2* and shim*"
log "Make very sure nothing else gets removed!"
sudo rm /etc/dnf/protected.d/{grub*,shim}.conf
# This call to DNF does *not* get the DNFOPTIONS passed since
# removing them without user confirmation is a bad idea.
sudo dnf remove grubby grub2* shim*
echo "ignore=grubby grub2* shim*" | sudo tee -a /etc/dnf/dnf.conf

# Generate new (signed) kernel images
log "Generating new unified kernel images"
for kver in $(dnf list installed kernel | tail -n +2 | awk '{print $2".x86_64"}'); do
	systemd-cat -t $IDENTIFIER sudo kernel-install -v add $kver /usr/lib/modules/$kver/vmlinuz
done

# Cleanup of stuff
log "Cleaning up stuff"
sudo rm -rf /boot/grub2/
sudo rm -rf /boot/config*
sudo rm -rf /boot/initramfs*
sudo rm -rf /boot/symvers*
sudo rm -rf /boot/System.map*
sudo rm -rf /boot/vmlinuz*

# The end!
log "systemd-boot should have been installed fully and cofigured. Reboot your system now and cross your fingers!"
exit 0

