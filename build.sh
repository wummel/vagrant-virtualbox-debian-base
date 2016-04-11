#!/bin/bash
#This script will:
#
# 1. download and verify the latest Debian 8 "Jessie" CD image
# 2. ... do some magic to turn it into a vagrant box file
# 3. output debian-jessie-i386.box or debian-jessie-amd64.box
#
# See README.md for more info

### set bash options ###
set -o nounset
set -o errexit
set -o pipefail
# for debugging
#set -o xtrace


### Check dependencies ###

# basic programs
hash curl 2>/dev/null || { echo >&2 "ERROR: curl not found. Aborting."; exit 1; }
hash grep 2>/dev/null || { echo >&2 "ERROR: grep not found. Aborting."; exit 1; }
hash sed 2>/dev/null || { echo >&2 "ERROR: sed not found. Aborting."; exit 1; }
hash cpio 2>/dev/null || { echo >&2 "ERROR: cpio not found. Aborting."; exit 1; }
hash vagrant 2>/dev/null || { echo >&2 "ERROR: vagrant not found. Aborting."; exit 1; }
hash 7z 2>/dev/null || { echo >&2 "ERROR: 7z not found. Aborting."; exit 1; }
# cd image generation program
if hash mkisofs 2>/dev/null; then
  MKISOFS="$(which mkisofs)"
elif hash genisoimage 2>/dev/null; then
  MKISOFS="$(which genisoimage)"
else
  echo >&2 "ERROR: mkisofs or genisoimage not found. Aborting."
  exit 1
fi
# hash check program; prefer sha256 over sha1 over md5
if hash sha256sum 2>/dev/null; then
  HASH_PROG=sha256sum
  HASH_FILE=SHA256SUMS
elif hash sha1sum 2>/dev/null; then
  HASH_PROG=sha1sum
  HASH_FILE=SHA1SUMS
elif hash md5sum 2>/dev/null; then
  HASH_PROG=md5sum
  HASH_FILE=MD5SUMS
else
  echo >&2 "ERROR: sha256sum or sha1sum or md5sum not found. Aborting."
  exit 1
fi
# VirtualBox
hash VBoxManage 2>/dev/null || { echo >&2 "ERROR: VBoxManage not found. Aborting."; exit 1; }
# Guest additions ISO on the host system
VBOX_GUEST_ADDITIONS=/usr/share/virtualbox/VBoxGuestAdditions.iso
if [ ! -f "$VBOX_GUEST_ADDITIONS" ]; then
  echo >&2 "ERROR: VirtualBox guest addition file $VBOX_GUEST_ADDITIONS not found. Aborting."
  exit 1
fi
# Parameter changes from 4.2 to 4.3
if [[ "$(VBoxManage --version)" < 4.3 ]]; then
  PORTCOUNT="--sataportcount 1"
else
  PORTCOUNT="--portcount 1"
fi
# ansible
if [ -n "$ANSIBLE_PLAYBOOK" ]; then
  if ! hash ansible-playbook 2>/dev/null; then
    echo >&2 "ERROR: ansible-playbook not found. Aborting."
    exit 1
  fi
fi


### Configuration ###
BASEDIR=$(dirname $0)

# Default curl options
# --fail: do not output HTML error pages
# --location: follow redirects
# For small downloads (< 10kB) the -sS silent option should also be used
CURL_OPTS="--fail --location"

# Env option: architecture (i386 or amd64)
ARCH=${ARCH:-amd64}
# Env option: Debian CD image mirror; default is http://cdimage.debian.org/debian-cd/
DEBIAN_CDIMAGE=${DEBIAN_CDIMAGE:-cdimage.debian.org}
DEBIAN_CDIMAGE_URL="http://${DEBIAN_CDIMAGE}/debian-cd/"
# Check if the Debian version is set manually (ie. DEBVER="8.4.0")
# or use the current version
if [ -z ${DEBVER+x} ]; then
  # Detect the current Debian version number.
  DEBVER=$(curl $CURL_OPTS -sS ${DEBIAN_CDIMAGE_URL} | grep -E ">[0-9]+\.[0-9]\.[0-9]/<" | sed -r 's/.*>([0-9]+\.[0-9]\.[0-9])\/<.*/\1/')
  echo "Detected Debian version \"$DEBVER\" from $DEBIAN_CDIMAGE_URL"
else
  echo "Using Debian version \"$DEBVER\""
fi
BOX="debian-jessie-${ARCH}"
ISO_FILE="debian-${DEBVER}-${ARCH}-netinst.iso"
ISO_BASEURL="${DEBIAN_CDIMAGE_URL}${DEBVER}/${ARCH}/iso-cd"
ISO_URL="${ISO_BASEURL}/${ISO_FILE}"
# GPG verification key for signed hash file from https://www.debian.org/CD/verify
# note: the key is hardcoded, this might change in the future
GPG_KEY="DF9B 9C49 EAA9 2984 3258  9D76 DA87 E80D 6294 BE9B"
# Map Debian architecture to VirtualBox OS type
if [ "$ARCH" = "amd64" ]; then
  VBOX_OSTYPE=Debian_64
else
  VBOX_OSTYPE=Debian
fi
# Env option: Use headless mode or GUI
VM_GUI="${VM_GUI:-}"
if [ "x${VM_GUI}" == "xyes" ] || [ "x${VM_GUI}" == "x1" ]; then
  STARTVM="VBoxManage startvm ${BOX}"
else
  STARTVM="VBoxManage startvm ${BOX} --type headless"
fi
STOPVM="VBoxManage controlvm ${BOX} poweroff"
# flag if the .vdi file should be compacted
COMPACTVDI=0


# Env option: local SSH pubkey
SSHKEY="${SSHKEY:-}"

# Env option: optionally run ansible playbook
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-}"
# Env option: local SSH port for ansible
ANSIBLE_SSHPORT="${ANSIBLE_SSHPORT:-2222}"
# local SSH user for ansible
ANSIBLE_USER="deploy"

# location, location, location
FOLDER_BASE=$(pwd)
FOLDER_ISO="${FOLDER_BASE}/iso"
FOLDER_BUILD="${FOLDER_BASE}/build"
FOLDER_VBOX="${FOLDER_BASE}/vbox"
FOLDER_ISO_CUSTOM="${FOLDER_BUILD}/iso/custom"
FOLDER_ISO_INITRD="${FOLDER_BUILD}/iso/initrd"

# Env option: Use custom preseed.cfg or default
DEFAULT_PRESEED="${BASEDIR}/preseed.cfg"
PRESEED="${PRESEED:-"$DEFAULT_PRESEED"}"

# Env option: Use custom late_command.sh or default
DEFAULT_LATE_CMD="${BASEDIR}/late_command.sh"
LATE_CMD="${LATE_CMD:-"$DEFAULT_LATE_CMD"}"

### helper functions ###
function cleanup {
  if [ -d "${FOLDER_BUILD}" ]; then
    echo "Cleaning build directory ..."
    chmod -R u+w "${FOLDER_BUILD}"
    rm -rf "${FOLDER_BUILD}"
  fi
}

trap 'cleanup' EXIT

### main function ###

# start with a clean slate
if VBoxManage list runningvms | grep "${BOX}" >/dev/null 2>&1; then
  echo "Stopping VM ..."
  ${STOPVM}
fi
if VBoxManage showvminfo "${BOX}" >/dev/null 2>&1; then
  echo "Unregistering VM ..."
  VBoxManage unregistervm "${BOX}" --delete
fi
if [ -f host.ini ]; then
  rm host.ini
fi
cleanup
if [ -f "${FOLDER_ISO}/custom.iso" ]; then
  echo "Removing custom iso ..."
  rm "${FOLDER_ISO}/custom.iso"
fi
if [ -f "${FOLDER_BASE}/${BOX}.box" ]; then
  echo "Removing old ${BOX}.box" ...
  rm "${FOLDER_BASE}/${BOX}.box"
fi

# Setting things back up again
mkdir -p "${FOLDER_ISO}"
mkdir -p "${FOLDER_BUILD}"
mkdir -p "${FOLDER_VBOX}"
mkdir -p "${FOLDER_ISO_CUSTOM}"
mkdir -p "${FOLDER_ISO_INITRD}"

ISO_FILENAME="${FOLDER_ISO}/${ISO_FILE}"
HASH_FILENAME="${FOLDER_ISO}/${HASH_FILE}"
HASHSIGN_FILE="${HASH_FILE}.sign"
HASHSIGN_FILENAME="${FOLDER_ISO}/${HASHSIGN_FILE}"
INITRD_FILENAME="${FOLDER_ISO}/initrd.gz"

# download the installation disk
if [ ! -e "${ISO_FILENAME}" ]; then
  echo "Downloading ${ISO_URL} ..."
  curl $CURL_OPTS --output "${ISO_FILENAME}" "${ISO_URL}"
fi

echo "Verifying ${ISO_FILE} ..."
# make sure download is right...
# fetch hash and signature file
ISO_HASHURL="${ISO_BASEURL}/${HASH_FILE}"
ISO_HASHSIGNURL="${ISO_HASHURL}.sign"
if [ ! -e "${HASH_FILENAME}" ]; then
  echo "Downloading ${ISO_HASHURL} ..."
  curl $CURL_OPTS -sS --output "${HASH_FILENAME}" "${ISO_HASHURL}"
fi
# check signature if gpg is available
if hash gpg 2>/dev/null; then
  echo "Downloading ${ISO_HASHSIGNURL} ..."
  curl $CURL_OPTS -sS --output "${HASHSIGN_FILENAME}" "${ISO_HASHSIGNURL}"
  echo "Get GPG key with fingerprint ${GPG_KEY} ..."
  gpg --keyserver hkp://keyring.debian.org --recv-keys "${GPG_KEY}"
  echo "Verify GPG key ..."
  gpg --verify "${HASHSIGN_FILENAME}" "${HASH_FILENAME}"
  rm -f "${HASHSIGN_FILENAME}"
else
  echo "WARN: gpg binary not found - skipping signature check"
fi
ISO_HASH="$(cat "${HASH_FILENAME}" | grep " $ISO_FILE" | cut -f1 -d" ")"
ISO_HASH_CALCULATED=$($HASH_PROG "${ISO_FILENAME}" | cut -d ' ' -f 1)
if [ "${ISO_HASH_CALCULATED}" != "${ISO_HASH}" ]; then
  echo >&2 "ERROR: hash from $HASH_PROG does not match. Got ${ISO_HASH_CALCULATED} instead of ${ISO_HASH}. Aborting."
  exit 1
fi

# customize it
echo "Creating Custom ISO"
if [ ! -e "${FOLDER_ISO}/custom.iso" ]; then

  echo "Using 7zip"
  if ! 7z x "${ISO_FILENAME}" -o"${FOLDER_ISO_CUSTOM}"; then
    # If that didn't work, you have to update p7zip
    echo "Error with extracting the ISO file with your version of p7zip. Try updating to the latest version."
    exit 1
  fi

  # backup initrd.gz
  echo "Backing up current init.rd ..."
  FOLDER_INSTALL=$(ls -1 -d "${FOLDER_ISO_CUSTOM}/install."* | sed 's/^.*\///')
  chmod u+w "${FOLDER_ISO_CUSTOM}/${FOLDER_INSTALL}" "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/${FOLDER_INSTALL}/initrd.gz"
  cp -r "${FOLDER_ISO_CUSTOM}/${FOLDER_INSTALL}/"* "${FOLDER_ISO_CUSTOM}/install/"
  mv "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

  # stick in our new initrd.gz
  echo "Installing new initrd.gz ..."
  cd "${FOLDER_ISO_INITRD}"
  if [ "$OSTYPE" = "msys" ]; then
    gunzip -c "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org" | cpio -i --make-directories || true
  else
    gunzip -c "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org" | cpio -id || true
  fi
  cd "${FOLDER_BASE}"
  if [ "${PRESEED}" != "${DEFAULT_PRESEED}" ] ; then
    echo "Using custom preseed file ${PRESEED}"
  fi
  cp "${PRESEED}" "${FOLDER_ISO_INITRD}/preseed.cfg"
  cd "${FOLDER_ISO_INITRD}"
  find . | cpio --create --format='newc' | gzip  > "${FOLDER_ISO_CUSTOM}/install/initrd.gz"

  # clean up permissions
  echo "Cleaning up Permissions ..."
  chmod u-w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

  # replace isolinux configuration
  echo "Replacing isolinux config ..."
  cd "${FOLDER_BASE}"
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux" "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  rm "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  cp ${BASEDIR}/isolinux.cfg "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.bin"

  # add late_command script
  echo "Add late_command script ..."
  chmod u+w "${FOLDER_ISO_CUSTOM}"
  cp "${LATE_CMD}" "${FOLDER_ISO_CUSTOM}/late_command.sh"

  # add local ssh key
  if [ -n "${SSHKEY}" ]; then
    cp "${SSHKEY}" "${FOLDER_ISO_CUSTOM}/sshkey.pub"
  else
    curl $CURL_OPTS -sS --output "${FOLDER_ISO_CUSTOM}/sshkey.pub" "https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub"
  fi

  # Add sudo config file
  cp "${BASEDIR}/user.sudo" "${FOLDER_ISO_CUSTOM}/user.sudo"

  echo "Running mkisofs ..."
  "$MKISOFS" -r -V "Custom Debian $DEBVER $ARCH CD" \
    -cache-inodes -quiet \
    -J -l -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -o "${FOLDER_ISO}/custom.iso" "${FOLDER_ISO_CUSTOM}"
fi

if ! VBoxManage showvminfo "${BOX}" >/dev/null 2>&1; then
  # create virtual machine
  echo "Creating VM Box ${BOX}..."
  VBoxManage createvm \
    --name "${BOX}" \
    --ostype "${VBOX_OSTYPE}" \
    --register \
    --basefolder "${FOLDER_VBOX}"

  VBoxManage modifyvm "${BOX}" \
    --memory 360 \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --vram 12 \
    --pae off \
    --rtcuseutc on

  VBoxManage storagectl "${BOX}" \
    --name "IDE Controller" \
    --add ide \
    --controller PIIX4 \
    --hostiocache on

  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "${FOLDER_ISO}/custom.iso"

  VBoxManage storagectl "${BOX}" \
    --name "SATA Controller" \
    --add sata \
    --controller IntelAhci \
    $PORTCOUNT \
    --hostiocache off

  VBoxManage createhd \
    --filename "${FOLDER_VBOX}/${BOX}/${BOX}.vdi" \
    --size 40960

  VBoxManage storageattach "${BOX}" \
    --storagectl "SATA Controller" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "${FOLDER_VBOX}/${BOX}/${BOX}.vdi"

  ${STARTVM}

  echo -n "Waiting for installer to finish "
  while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
    sleep 20
    echo -n "."
  done
  echo ""

  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium emptydrive

  # compact virtual disk of newly created VM
  COMPACTVDI=1
fi

if [ -n "${ANSIBLE_PLAYBOOK}" ]; then
  # Run an ansible playbook
  echo "127.0.0.1:${ANSIBLE_SSHPORT}" > host.ini

  # if ansible has errors, login to the runnig box with:
  # ssh -p ${ANSIBLE_SSHPORT} ${ANSIBLE_USER}@localhost
  # and inspect the machine.
  # See above for definitions of ANSIBLE_SSHPORT and ANSIBLE_USER.
  VBoxManage modifyvm "${BOX}" \
    --natpf1 "ssh,tcp,,${ANSIBLE_SSHPORT},,22"

  # mount VBox Guest Additions to allow install or upgrade with ansible
  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "${VBOX_GUEST_ADDITIONS}"

  ${STARTVM}
  echo "Waiting for VM ssh server "
  while ! ansible all -i host.ini -m ping --user ${ANSIBLE_USER} >/dev/null 2>&1; do
    sleep 1
    echo -n "."
  done
  echo ""
  echo "Running Ansible Playbook ..."
  ansible-playbook -i host.ini "${ANSIBLE_PLAYBOOK}"

  echo "Stopping VM ..."
  ${STOPVM}

  # remove the above added NAT rule
  VBoxManage modifyvm "${BOX}" \
    --natpf1 delete ssh

  # eject the guest addition DVD
  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium emptydrive

  # compact virtual disk of modified VM
  COMPACTVDI=1
fi

if [ "$COMPACTVDI" = "1" ]; then
  echo "Compacting the .vdi ..."
  VBoxManage modifyhd "${FOLDER_VBOX}/${BOX}/${BOX}.vdi" --compact
fi

echo "Building Vagrant Box ..."
vagrant package --base "${BOX}" --output "${BOX}.box"

# references:
# http://blog.ericwhite.ca/articles/2009/11/unattended-debian-lenny-install/
# http://docs-v1.vagrantup.com/v1/docs/base_boxes.html
# http://www.debian.org/releases/stable/example-preseed.txt
