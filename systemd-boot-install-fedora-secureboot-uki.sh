#!/usr/bin/bash

# This identifier is used in journalctl and systemd-cat. If you want to see the script output
# in the journal use 
#
# journalctl -t <value of $IDENTIFIER>
IDENTIFIER=bootctl-conversion

# These options get passed to DNF. You can add things like "-y" here for example. See `man dnf`
# for available options.
DNFOPTIONS="-y"

# This checks where the ESP is mounted to
ESP=$(bootctl status -p)

# This function handles logging to the journal and the screen. See the stuff about $IDENTIFIER
# further up to see/understand how you can get the output later on.
function log {
	systemd-cat -t $IDENTIFIER echo "$1"
	echo "$1"
}

# If the nvidia driver (from RPMFusion / nvidia themselves) is detected/in use on this system stop
# execution of the script here since that is *known* to not work.
#
# A possible "fix" would be to include the nvidia kernel module(s) into the UKI image so it gets signed
# as a whole. That could be done with something like this:
#
# if [[ $(lsmod | grep -c nvidia) -gt 0 ]]; then
# 	 log "The nvidia driver is detected on this system. Attempting to include it in the UKI"
# 	 log "image so it gets signed with the rest of the kernel."
#	 log "This is not tested, so tread carefully."
#	 MODS="$(lsmod | awk '{print $1}' | grep nvidia | tr '\n' ' ')"
#	 sudo tee /etc/dracut.conf.d/nvidia-signed-modules.conf <<"EOT"
#	 add_drivers+=" $MODS "
# 	 EOT
# fi

if [[ $(lsmod | grep nvidia -c) -gt 0 ]]; then
	log "The nvidia driver is detected on this system. Aborting converting this system to"
	log "a UKI powered one with secure boot, since the nvidia driver is known to cause"
	log "breakages."
	exit 0
fi

log "Before running this script make sure your system is fully up to date!"

# Make sure both git-core and tar are installed before going further, since the script needs 'm both
# and I assumed this was run on a Fedora Workstation install, which has them by default, but that is
# not always the case.
sudo dnf install git-core tar $DNFOPTIONS

# Before doing anything else install the components that sbctl (https://github.com/Foxboron/sbctl)
# requires to install, since it's not (yet?) in the Fedora repos.
log "Installing components that sbctl requires."
sudo dnf install asciidoc golang --setopt=install_weak_deps=False $DNFOPTIONS

# Getting the source for sbctl. The VERSION variable should be updated if a new release of it is
# pushed to GitHub.
VERSION=0.11
cd /tmp
curl -L https://github.com/Foxboron/sbctl/releases/download/$VERSION/sbctl-$VERSION.tar.gz | tar -zxvf-
cd sbctl-$VERSION
make
sudo make install

# After that's built and installed create and enroll (new) secure boot keys.
log "Creating and enrolling (new) secure boot keys."
systemd-cat -t $IDENTIFIER sudo sbctl create-keys
systemd-cat -t $IDENTIFIER sudo sbctl enroll-keys

# If the creating and/or enrolling keys fails this need to be seen by the user before the script
# continues and fails later on. `sbctl` does a good job of telling what went wrong and where.
if [[ $? -gt 0 ]]; then
	log "Something went wrong with creating or enrolling secure boot keys with sbctl."
	log "See the full log with 'journalctl -t $IDENTIFIER'."
	log "Exiting now."
	exit 1
fi

# Should the enroll-keys step fail you can manually export the newly created keys
# and import them into your UEFI by hand with this:
#
# sudo openssl x509 -in /usr/share/secureboot/keys/db/db.pem -outform DER -out /boot/efi/EFI/fedora/DB.cer
#
# Reboot into your firmware/UEFI after that (you can use `sudo systemctl reboot --firmware-setup`) and import
# the "DB.cer" file.
#
# Reboot after that, and `sudo sbctl status` should return info about the key, setup mode, and secure boot status.

# The /boot/loader folder is created/used by Fedora by default, but it's not needed (anymore/yet), so remove it.
log "Removing the /boot/loader folder and it's contents for a proper systemd-boot install."
sudo rm -rf /boot/loader/

# Install systemd-boot properly.
log "Installing systemd-boot fully."

if [[ $(dnf list installed systemd-boot 2>/dev/null | wc -l) -eq 0 ]]; then
	log "Installing the systemd-boot package first."
	sudo dnf install systemd-boot $DNFOPTIONS
fi

# Now time to do some real work
# TODO: check if this way works to get the output into the journal.
systemd-cat -t $IDENTIFIER sudo bootctl install 

if [[ $? -gt 0 ]]; then
	log "Something went wrong with the installation of systemd-boot."
	log "See the full log with 'journalct -t $IDENTIFIER'."
	log "Exiting now."
	exit 1
fi

# Sign the systemd-boot EFI files with the secure boot key created above.
log "Signing the systemd-boot EFI files."
sudo sbctl sign $ESP/EFI/systemd/systemd-bootx64.efi
sudo sbctl sign $ESP/EFI/BOOT/BOOTX64.EFI

log "Configuring systemd-boot"
sudo dnf install sbsigntools $DNFOPTIONS
sudo mkdir -p /etc/systend/system/systemd-boot-update.service.d/
sudo tee /etc/systemd/system/systemd-boot-update.service.d/override.conf <<EOT
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sbverify --cert /usr/share/secureboot/keys/db/db.pem $ESP/EFI/systemd/systemd-bootx64.efi || sbctl sign $ESP/EFI/systemd/systemd-bootx64.efi'
ExecStart=/bin/sh -c 'sbverify --cert /usr/share/secureboot/keys/db/db.pem $ESP/EFI/BOOT/BOOTX64.EFI || sbctl sign $ESP/EFI/BOOT/BOOTX64.EFI'
EOT

sudo systemctl daemon-reload

log "Configuring systemd-boot with sane defaults."
cat /proc/cmdline | cut -d " " -f2- | sudo tee /etc/kernel/cmdline
echo "layout=bls" | sudo tee /etc/kernel/install.conf
sudo ln -s /dev/null /etc/kernel/install.d/50-dracut.install
sudo ln -s /dev/null /etc/kernel/install.d/51-dracut-rescue.install
sudo ln -s /dev/null /etc/kernel/install.d/92-crashkernel.install

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
		rm -f "$BOOT_ROOT/loader/entries/$MACHINE_ID-$KERNEL_VERSION+"*".conf"
		rm -f "$BOOT_ROOT/EFI/Linux/$KERNEL_VERSION-$MACHINE_ID+"*".efi"
	else
		rm -f "$BOOT_ROOT/loader/entries/$MACHINE_ID-$KERNEL_VERSION.conf"
		rm -f "$BOOT_ROOT/EFI/Linux/$KERNEL_VERSION-$MACHINE_ID.efi"
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
	echo "Could not create laoder entry directory '${LOADER_ENTRY%/*}'." >&2
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

log "Configuring dracut"
sudo tee /etc/dracut.conf.d/systemd-boot-modifications.conf <<EOT
uefi="yes"
uefi_secureboot_cert="/usr/share/secureboot/keys/db/db.pem"
uefi_secureboot_key="/usr/share/secureboot/keys/db/db.key"
dracut_rescue_image="no"
hostonly="yes"
EOT

# Remove grubby, grub2* and shim* pacakges from the system
log "Removing grubby, grub2*, and shim* packages"
log "Make sure that nothing else important gets removed!"
sudo rm /etc/dnf/protected.d/{grub*,shim}.conf

# This call to DNF does *not* get the DNFOPTIONS passed since removing them without user confirmation
# is a bad idea.
sudo dnf remove grubby grub2* shim*

if [[ $? -eq 0 ]]; then
	echo "ignore=grubby grub2* shim*" | sudo tee -a /etc/dnf/dnf.conf
	sudo rm -rf /boot/grub2/
fi

# Clean up stuff
log "Cleaning up folders from /boot that are no longer required."
sudo rm -rf /boot/config*
sudo rm -rf /boot/initramfs*
sudo rm -rf /boot/symvers*
sudo rm -rf /boot/System.map*
sudo rm -rf /boot/vmlinuz*

# Generate new (signed) kernel images
log "(Re)generating new kernel images"
LASTKVER=0
for kver in $(dnf list installed kernel | tail -n +2 | awk '{print $2".x86_64"}'); do
	sudo kernel-install -v add $kver /usr/lib/modules/$kver/vmlinuz
	LASTKVER=$kver
done

# Generate a rescue image.
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

echo -e "\n"

# The end
log "systemd-boot should have been installed and fully configured. Reboot your machine now and see if that's the case."
exit 0
