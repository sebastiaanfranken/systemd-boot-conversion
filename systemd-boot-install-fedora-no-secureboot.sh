#!/bin/bash

# A script to replace grub with systemd-boot in Fedora. This version doesn't use secure boot.

# This identifier is used in journalctl and systemd-cat. If you want to see the script output
# in the journal use
#
# journalctl -t <value of $IDENTIFIER>
IDENTIFIER=bootctl-conversion

# These options get passed to DNF. You can add things like
# "-y" here for example. See `man dnf` for available options.
DNFOPTIONS=""

# With this function the output passed gets written into the system journal and output to screen.
function log {
	systemd-cat -t ${IDENTIFIER} echo "$1"
	echo "$1"
}

# Create the /tmp/${IDENTIFIER}/ folder
mkdir -p /tmp/${IDENTIFIER}/

if [[ ${?} -gt 0 ]]; then
	log "Creating the /tmp/${IDENTIFIER}/ folder failed with error code ${?}. Aborting."
	exit 1
fi

log "Before running this script make sure your system is fully up to date!"

# The current implementation of systemd-boot with grub on Fedora creates and uses /boot/loader
# to contain kernel image(s). Remove that, so the installation of systemd-boot later on doesn't
# use that and messes up the rest of the install / configured defaults.
log "Removing the /boot/loader/ folder (and it's contents) for a proper systemd-boot install."
sudo rm -rf /boot/loader/

# Installing systemd-boot properly / fully
log "Installing systemd-boot properly."

if [[ $(dnf list installed systemd-boot-unsigned 2>/dev/null | wc -l) -eq 0 ]]; then
	log "Installing systemd-boot-unsigned package first."
	sudo dnf install systemd-boot-unsigned ${DNFOPTIONS}
fi

sudo bootctl install 2>&1 1>/tmp/${IDENTIFIER}/systemd-boot-install.log
# systemd-cat -t ${IDENTIFIER} sudo bootctl install

if [[ ${?} -gt 0 ]]; then
	log "Something went wrong with the installation of systemd-boot."
	log "Check the log at /tmp/${IDENTIFIER}/systemd-boot-install.log to see what."
	
	exit 1
fi

# Configure systemd-boot with 'sane defaults'
log "Configuring systemd-boot with sane default"
cat /proc/cmdline | cut -d " " -f2- | sudo tee -a /etc/kernel/cmdline
echo "layout=bls" | sudo tee /etc/kernel/install.conf

# Overwrite configs in /usr/lib/kernel/install.d with version (symlinks to /dev/null)
# in /etc/kernel
log "Making sure /usr/lib/kernel/install.d/51-dracut-rescue.install is ignored."
sudo ln -sv /dev/null /etc/kernel/install.d/51-dracut-rescue.install

log "Making sure /usr/lib/kernel/install.d/92-crashkernel.install is ignored."
sudo ln -sv /dev/null /etc/kernel/install.d/92-crashkernel.install

# Create the configuration file to make sure unified (kernel) images are used
log "Creating the configuration file at /etc/kernel/install.d/95-use-unified-images.install that makes sure unified kernel/initramfs images are used."
sudo touch /etc/kernel/install.d/95-use-unified-images.install

cat <<"EOF" > /etc/kernel/install.d/95-use-unified-images.install
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

sed -i "/^initrd/d" "${LOADER_ENTRY}"
sed -i "/^linux/s/linux$/initrd/" "${LOADER_ENTRY}"

if [[ -f "${BOOT_ROOT}/${MACHINE_ID}/${KERNEL_VERSION}/linux" ]]; then
	rm "${BOOT_ROOT}/${MACHINE_ID}/${KERNEL_VERSION}/linux"
fi
EOF

sudo chmod +x /etc/kernel/install.d/95-use-unified-images.install

# Configure dracut to work with systemd-boot and not rely on grub
log "Configuring dracut to work with systemd-boot and not rely on grub."
sudo touch /etc/dracut.conf.d/systemd-boot-modifications.conf
echo <<"EOF" > /etc/dracut.conf.d/systemd-boot-modifications.conf
uefi="yes"
dracut_rescue_image="no"
hostonly="yes"
EOF

# (re)generate kernel images so they get "unified"
log"Generating new kernel images"
for kver in $(dnf list installed kernel | tail -n +2 | awk '{print $2".x86_64"}'); do
	kernel-install -v add ${kver} /lib/modules/${kver}/vmlinuz
done

# Removal of GRUB2
log "Time to remove grub2"
sudo rm -rf /etc/dnf/protected.d/{grub*,shim}.conf
sudo dnf remove grubby grub2* shim*
echo "ignore=grubby grub2* shim*" | sudo tee -a /etc/dnf/dnf.conf

# Time for some cleaning
log "Cleaning up files and folders that are no longer required."
sudo rm -rf /boot/grub2/
sudo rm -rf /boot/config*
sudo rm -rf /boot/initramfs*
sudo rm -rf /boot/symvers*
sudo rm -rf /boot/System.map*
sudo rm -rf /boot/vmlinuz*

# The end!
log "systemd-boot *should* have been fully installed and configured. Reboot your system now and cross your fingers!"
exit 0
