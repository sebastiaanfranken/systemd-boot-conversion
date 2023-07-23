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

# The current implementation of systemd-boot with grub on Fedora creates and uses /boot/loader
# to contain kernel image(s). Remove that, so the installation of systemd-boot later on doesn't
# use that and messes up the rest of the install / configured defaults.
log "Removing the /boot/loader/ folder (and it's contents) for a proper systemd-boot install."
sudo rm -rf /boot/loader/

# Installing systemd-boot properly / fully
log "Installing systemd-boot properly."

if [[ $(dnf list installed systemd-boot-unsigned 2>/dev/null | wc -l) -eq 0 ]]; then
	log "Installing systemd-boot-unsigned package first."
	sudo dnf install systemd-boot-unsigned "$DNFOPTIONS"
fi

systemd-cat -t ${IDENTIFIER} sudo bootctl install || {
	log "Something went wrong with the installation of systemd-boot."
	log "Check the log with journalctl to see what."
	exit 1
}

# Configure systemd-boot with 'sane defaults'
log "Configuring systemd-boot with sane defaults"

if [[ -f /etc/kernel/cmdline ]]; then
	log "Backing up the original /etc/kernel/cmdline file to /etc/kernel/cmdline.original"
	sudo cp /etc/kernel/cmdline /etc/kernel/cmdline.original
fi

cut -d " " -f2- /proc/cmdline | sudo tee /etc/kernel/cmdline

if [[ -f /etc/kernel/install.conf ]]; then
	log "Backing up the original /etc/kernel/install.conf file to /etc/kernel/install.conf.original"
	sudo cp /etc/kernel/install.conf /etc/kernel/install.conf.original
fi

echo "layout=bls" | sudo tee /etc/kernel/install.conf

# Overwrite configs in /usr/lib/kernel/install.d with version (symlinks to /dev/null)
# in /etc/kernel
log "Making sure /usr/lib/kernel/install.d/51-dracut-rescue.install is ignored."
sudo ln -sv /dev/null /etc/kernel/install.d/51-dracut-rescue.install

log "Making sure /usr/lib/kernel/install.d/92-crashkernel.install is ignored."
sudo ln -sv /dev/null /etc/kernel/install.d/92-crashkernel.install

# Create the configuration file to make sure unified (kernel) images are used
log "Creating the configuration file at /etc/kernel/install.d/95-use-unified-images.install that makes sure unified kernel/initramfs images are used."
LOADERENTRY_FILE="/etc/kernel/install.d/95-use-unified-images.install"
sudo tee $LOADERENTRY_FILE << "EOF"
#!/usr/bin/bash

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

sudo chmod +x $LOADERENTRY_FILE

# Configure dracut to work with systemd-boot and not rely on grub
log "Configuring dracut to work with systemd-boot and not rely on grub."
DRACUT_EXTRA_CONF_FILE="/etc/dracut.conf.d/systemd-boot-modifications.conf"
sudo tee $DRACUT_EXTRA_CONF_FILE << EOF
uefi="yes"
dracut_rescue_image="no"
hostonly="yes"
EOF

# Update systemd-boot on demand.
DNFPLUGIN=python3-dnf-plugin-post-transaction-actions
if [[ $(dnf list installed $DNFPLUGIN 2>/dev/null | wc -l) -eq 0 ]]; then
	sudo dnf install $DNFPLUGIN $DNFOPTIONS
fi

SYSTEMD_UDEV_FILE="/etc/dnf/plugins/post-transaction-actions.d/systemd-udev.action"
if ! [[ -f $SYSTEMD_UDEV_FILE ]]; then
	echo "systemd-udev:in:bootctl update" | tee $SYSTEMD_UDEV_FILE
fi

# (re)generate kernel images so they get "unified"
log"Generating new kernel images"
for kver in $(dnf list installed kernel | tail -n +2 | awk '{print $2".x86_64"}'); do
	sudo kernel-install -v add "$kver" "/usr/lib/modules/$kver/vmlinu"
done

# Removal of GRUB2
log "Time to remove grub2"
sudo rm -rf /etc/dnf/protected.d/{grub*,shim}.conf
sudo dnf remove grubby grub2* shim*

if [[ -f /etc/dnf/dnf.conf ]]; then
	sudo cp /etc/dnf/dnf.conf /etc/dnf/dnf.conf.original
fi

echo "ignore=grubby grub2* shim*" | sudo tee -a /etc/dnf/dnf.conf

# Time for some cleaning
log "Cleaning up files and folders that are no longer required."
sudo rm -rf /boot/grub2/
sudo rm -rf /boot/config*
sudo rm -rf /boot/initramfs*
sudo rm -rf /boot/symvers*
sudo rm -rf /boot/System.map*
sudo rm -rf /boot/vmlinuz*

echo -e "\n"

# The end!
log "systemd-boot *should* have been fully installed and configured. Reboot your system now and cross your fingers!"
exit 0
