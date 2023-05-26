#!/usr/bin/bash

# A script to replace grub with systemd-boot in Fedora. This version does not use secure boot.

# This identifier is used in journalctl and systemd-cat. If you want to see the script output
# in the journal use
#
# journalctl -t <value of $IDENTIFIER>
IDENTIFIER=bootctl-conversion

# Option(s) passed to the various calls to dnf.
DNFOPTIONS="-y"

# This checks where the ESP is mounted to
ESP=$(bootctl status -p)

# This is a wrapper around systemd-cat combined with echo for logging purposes.
function log {
	systemd-cat -t $IDENTIFIER echo "$1"
	echo "$1"
}

log "Before running this script make sure your system is fully up to date!"

# The current implementation of systemd-boot with grub on Fedora creates and uses /boot/loader
# to contain kernel images. Remove that, so the installation of systemd-boot later on doesn't
# use that and messes up the rest of the install / configured defaults.
log "Removing the /boot/loader folder and it's contents for a proper systemd-boot installation."
sudo rm -rf /boot/loader

# Installing systemd-boot-unsigned properly.
log "Installing systemd-boot-unsigned properly."

if [[ $(dnf list installed systemd-boot-unsigned 2>/dev/null | wc -l) -eq 0 ]]; then
	log "The systemd-boot-unsigned package is not installed, installing that now."
	sudo dnf install systemd-boot-unsigned $DNFOPTIONS
fi

systemd-cat -t $IDENTIFIER sudo bootctl install

if [[ $? -gt 0 ]]; then
	log "Something went wrong with the installation of systemd-boot-unsigned."
	log "See the full log with 'journalctl -t $IDENTIFIER'."
	log "Exiting now."
	exit 1
fi

# Configure systemd-boot-unsigned with sane defaults.
log "Configuring systemd-boot-unsigned with sane defaults."
cat /proc/cmdline | cut -d ' ' -f 2- | sudo tee /etc/kernel/cmdline
echo 'layout=bls' | sudo tee /etc/kernel/install.conf

# The following disables the classic genration of initramfs's when needed. This is done later
# by /etc/kernel/install.d/90-loaderentry.install
log "Disabling old style initramfs generation."
sudo ln -s /dev/null /etc/kernel/install.d/50-dracut.install

# The following configures dracut to *not* generate a rescue image. If you want/need this
# alter this or comment it.
log "Configuring to not generate a rescue image."
log "If you need a rescue image, remove /etc/kernel/install.d/51-dracut-rescue.install"
log "and take a look at /usr/lib/kernel/install.d/51-dracut-rescue.install"
sudo ln -s /dev/null /etc/kernel/install.d/51-dracut-rescue.install

# This does the heavy lifting of sorts, this configures dracut to generate unified kernel
# images.
log "Configuring dracut to generate unified kernel images."

LOADERENTRY_FILE=/etc/kernel/install.d/90-loaderentry.install
sudo tee $LOADERENTRY_FILE <<"EOT"
#!/usr/bin/bash

COMMAND="$1"
KERNEL_VERSION="$2"
ENTRY_DIR_ABS="$3"
KERNEL_IMAGE="$4"
INITRD_OPTIONS_START="$5"
MACHINE_ID=$KERNEL_INSTALL_MACHINE_ID
BOOT_ROOT=${ENTRY_DIR_ABS%/$MACHINE_ID/$KERNEL_VERSION}
BOOT_MNT=$(stat -c %m $BOOT_ROOT)
ENTRY_DIR=${ENTRY_DIR_ABS#$BOOT_MNT}

if [[ $COMMAND == remove ]]; then
	if [[ -f /etc/kernel/tries ]]; then
		rm -f "$BOOT_ROOT/loader/entries/$MACHINE_ID-$KEREL_VERSION+"*".conf"
		rm -f "$BOOT_ROOT/EFI/Linux/$KERNEL_VERSION-$MACHINE_ID+"*".efi"
	else
		rm -f "$BOOT_ROOT/loader/entries/$MACHINE_ID-$KERNEL_VERSION.conf"
		rm -f "$BOOT_ROOT/EFI/Linux/$KERNEL_VERSION-$MACHINE_ID+"*".efi"
	fi
	
	rpm -e --noscripts kernel-core-$KERNEL_VERSION

	exit 0
fi

if ! [[ $COMMAND == add ]]; then
	exit 1
fi

if ! [[ $KERNEL_IMAGE ]]; then
	exit 1
fi

if [[ -f /etc/os-release ]]; then
	. /etc/os-release
elif [[ -f /usr/lib/os-release ]]; then
	. /usr/lib/os-release
fi

if ! [[ $PRETTY_NAME ]]; then
	PRETTY_NAME="Linux $KERNEL_VERSION"
fi

if [[ -f /etc/kernel/cmdline ]]; then
	read -r -d '' -a BOOT_OPTIONS < /etc/kernel/cmdline
elif [[ -f /usr/lib/kernel/cmdline ]]; then
	read -r -d '' -a BOOT_OPTIONS < /usr/lib/kernel/cmdline
else
	declare -a BOOT_OPTIONS
	read -r -d '' -a line < /proc/cmdline
	
	for i in "${line[@]}"; do
		[[ "${i#initrd=*}" != "$i" ]] && continue
		[[ "${i#BOOT_IMAGE=*}" != "$i" ]] && continue
		BOOT_OPTIONS+=("$i")
	done
fi

if [[ -f /etc/kernel/tries ]]; then
	read -r TRIES < /etc/kernel/tries
	
	if ! [[ "$TRIES" =~ ^[0-9]+$ ]]; then
		echo "/etc/kernel/tries does not contain an integer." >&2
		exit 1
	fi
	LOADER_ENTRY="$BOOT_ROOT/EFI/Linux/$KERNEL_VERSION-$MACHINE_ID+$TRIES.efi"
else
	LOADER_ENTRY="$BOOT_ROOT/EFI/Linux/$KERNEL_VERSION-$MACHINE_ID.efi"
fi

mkdir -p "${LOADER_ENTRY%/*}" || {
	echo "Could not create loader entry directory '${LOADER_ENTRY%/*}'." >&2
	exit 1
}

{
	unset noimageifnotneeded
	
	for ((i=0; i < "${#BOOT_OPTIONS[@]}"; i++)); do
		if [[ ${#BOOT_OPTIONS[$i]} == root\=PARTUUID\=* ]]; then
			noimageifnotneeded="yes"
			break
		fi
	done
	
	dracut --kernel-cmdline "${BOOT_OPTIONS[*]}" -f ${noimageifnotneeded:+--noimageifnotneeded} --uefi "$LOADER_ENTRY" "$KERNEL_VERSION"
}
exit 0
EOT

sudo chmod +x $LOADERENTRY_FILE

# The following configures dracut to not use the crashkernel stuff. If you want/need this
# alter this or comment it.
log "Configuring to ignore crashkernel configurations."
sudo ln -s /dev/null /etc/kernel/install.d/92-crashkernel.install

# Configure dracut to work with systemd-boot and let it's do it's UKI magic.
log "Configuring dracut to work with systemd-boot-unsigned and work with unified kernel images."
DRACUT_EXTRA_CONF_FILE=/etc/dracut.conf.d/systemd-boot-unsigned-modifications.conf
sudo touch $DRACUT_EXTRA_CONF_FILE
sudo tee $DRACUT_EXTRA_CONF_FILE <<EOT
uefi="yes"
hostonly="yes"
dracut_rescue_image="no"
EOT

if [[ $(dnf list installed binutils 2>/dev/null | wc -l) -eq 0 ]]; then
	log "Installing binutils before regenerating kernel images, as dracut need that."
	sudo dnf install binutils $DNFOPTIONS
fi

# Update systemd-boot on demand
DNFPLUGIN=python3-dnf-plugin-post-transaction-actions
if [[ $(dnf list installed $DNFPLUGIN 2>/dev/null | wc -l) -eq 0 ]]; then
	sudo dnf install $DNFPLUGIN $DNFOPTIONS
fi

SYSTEMD_UDEV_FILE=/etc/dnf/plugins/post-transaction-actions.d/systemd-udev.action
if ! [[ -f $SYSTEMD_UDEV_FILE ]]; then
	echo "systemd-udev:in:bootctl update" | tee $SYSTEMD_UDEV_FILE
fi

# Finally remove grub2 and it's required stuff
log "Cleaning up/removing grub2 and it's partners."
sudo rm -f /etc/dnf/protected.d/{grub*,shim}.conf
sudo dnf remove grubby grub2* shim
echo "ignore=grubby grub2* shim" | sudo tee -a /etc/dnf/dnf.conf

# Regenerate kernel images
LASTKVER=0
for kver in $(dnf list installed kernel | tail -n +2 | awk '{print $2".x86_64"}'); do
	sudo kernel-install add $kver /usr/lib/modules/$kver/vmlinuz
	LASTKVER=$kver
done

# Rescue kernel generation
log "Creating a rescue kernel image"

if [[ -f /etc/kernel/cmdline ]]; then
	read -r -d '' -a BOOT_OPTIONS < /etc/kernel/cmdline
elif [[ -f /usr/lib/kernel/cmdline ]]; then
	read -r -d '' -a BOOT_OPTIONS < /usr/lib/kernel/cmdline
else
	declare -a BOOT_OPTIONS
	read -r -d '' -a line < /proc/cmdline
	for i in "${line[@]}"; do
		[[ "${i#initrd=*}" != "$i" ]] && continue
		BOOT_OPTIONS+=("$i")
	done
fi

read -r MACHINE_ID < /etc/machine-id
LOADER_ENTRY="$ESP/EFI/Linux/0-rescue-$MACHINE_ID.efi"
systemd-cat -t $IDENTIFIER dracut --kernel-cmdline "${BOOT_OPTIONS[*]}" -f --no-hostonly -a "rescue" --uefi "$LOADER_ENTRY" "$LASTKVER"

# Time to clean up files and folders that are no longer required.
log "Cleaning up files and folders that are no longer required."
sudo rm -rf /boot/grub2/
sudo rm -rf /boot/config*
sudo rm -rf /boot/initramfs*
sudo rm -rf /boot/symvers*
sudo rm -rf /boot/System.map*
sudo rm -rf /boot/vmlinuz*

echo -e "\n"

# The end!
log "systemd-boot-unsigned *should* have been fully installed and properly configured."
log "Reboot your system now to check, and cross your fingers."
exit 0
