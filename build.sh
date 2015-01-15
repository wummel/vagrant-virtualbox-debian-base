#!/bin/bash

# make sure we have dependencies
hash vagrant 2>/dev/null || { echo >&2 "ERROR: vagrant not found.  Aborting."; exit 1; }
hash VBoxManage 2>/dev/null || { echo >&2 "ERROR: VBoxManage not found.  Aborting."; exit 1; }
hash 7z 2>/dev/null || { echo >&2 "ERROR: 7z not found. Aborting."; exit 1; }

VBOX_VERSION="$(VBoxManage --version)"

if hash mkisofs 2>/dev/null; then
  MKISOFS="$(which mkisofs)"
elif hash genisoimage 2>/dev/null; then
  MKISOFS="$(which genisoimage)"
else
  echo >&2 "ERROR: mkisofs or genisoimage not found.  Aborting."
  exit 1
fi

set -o nounset
set -o errexit
set -o pipefail
#set -o xtrace

# Configurations
BASEDIR=$(dirname $0)

# Env option: architecture
ARCH=${ARCH:-amd64}
# Env option: Debian CD image mirror
DEBIAN_CDIMAGE=${DEBIAN_CDIMAGE:-cdimage.debian.org}

DEBVER="7.8.0"
BOX="debian-wheezy-${ARCH}"
ISO_FILE="debian-${DEBVER}-${ARCH}-netinst.iso"
ISO_URL="http://${DEBIAN_CDIMAGE}/debian-cd/${DEBVER}/${ARCH}/iso-cd/${ISO_FILE}"
if [ "$ARCH" = "amd64" ]; then
  ISO_MD5="a91fba5001cf0fbccb44a7ae38c63b6e"
  VBOX_OSTYPE=Debian_64
else
  ISO_MD5="0d2f88d23a9d5945f5bc0276830c7d2c"
  VBOX_OSTYPE=Debian
fi

# Env option: local SSH pubkey
SSHKEY="${SSHKEY:-}"

# Env option: optionally run ansible playbook
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-}"
if [ -n "$ANSIBLE_PLAYBOOK" ]; then
  hash ansible-playbook 2>/dev/null || { echo >&2 "ERROR: ansible-playbook not found. Aborting."; exit 1; }
fi
# Env option: local SSH port for ansible
ANSIBLE_SSHPORT="${ANSIBLE_SSHPORT:-2222}"
# local SSH user for ansible
ANSIBLE_USER="deploy"
# Guest additions ISO on the host system
VBOX_GUEST_ADDITIONS=/usr/share/virtualbox/VBoxGuestAdditions.iso

# location, location, location
FOLDER_BASE=$(pwd)
FOLDER_ISO="${FOLDER_BASE}/iso"
FOLDER_BUILD="${FOLDER_BASE}/build"
FOLDER_VBOX="${FOLDER_BUILD}/vbox"
FOLDER_ISO_CUSTOM="${FOLDER_BUILD}/iso/custom"
FOLDER_ISO_INITRD="${FOLDER_BUILD}/iso/initrd"

# Env option: Use headless mode or GUI
VM_GUI="${VM_GUI:-}"
if [ "x${VM_GUI}" == "xyes" ] || [ "x${VM_GUI}" == "x1" ]; then
  STARTVM="VBoxManage startvm ${BOX}"
else
  STARTVM="VBoxManage startvm ${BOX} --type headless"
fi
STOPVM="VBoxManage controlvm ${BOX} poweroff"

# Env option: Use custom preseed.cfg or default
DEFAULT_PRESEED="${BASEDIR}/preseed.cfg"
PRESEED="${PRESEED:-"$DEFAULT_PRESEED"}"

# Env option: Use custom late_command.sh or default
DEFAULT_LATE_CMD="${BASEDIR}/late_command.sh"
LATE_CMD="${LATE_CMD:-"$DEFAULT_LATE_CMD"}"

# Parameter changes from 4.2 to 4.3
if [[ "$VBOX_VERSION" < 4.3 ]]; then
  PORTCOUNT="--sataportcount 1"
else
  PORTCOUNT="--portcount 1"
fi

if [ "$OSTYPE" = "linux-gnu" ]; then
  MD5="md5sum"
elif [ "$OSTYPE" = "msys" ]; then
  MD5="md5 -l"
else
  MD5="md5 -q"
fi

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
if [ -d "${FOLDER_BUILD}" ]; then
  echo "Cleaning build directory ..."
  chmod -R u+w "${FOLDER_BUILD}"
  rm -rf "${FOLDER_BUILD}"
fi
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
INITRD_FILENAME="${FOLDER_ISO}/initrd.gz"

# download the installation disk if you haven't already or it is corrupted somehow
echo "Downloading ${ISO_FILE} ..."
if [ ! -e "${ISO_FILENAME}" ]; then
  curl --output "${ISO_FILENAME}" -L "${ISO_URL}"
fi

# make sure download is right...
ISO_HASH=$($MD5 "${ISO_FILENAME}" | cut -d ' ' -f 1)
if [ "${ISO_MD5}" != "${ISO_HASH}" ]; then
  echo "ERROR: MD5 does not match. Got ${ISO_HASH} instead of ${ISO_MD5}. Aborting."
  exit 1
fi

# customize it
echo "Creating Custom ISO"
if [ ! -e "${FOLDER_ISO}/custom.iso" ]; then

  echo "Using 7zip"
  7z x "${ISO_FILENAME}" -o"${FOLDER_ISO_CUSTOM}"

  # If that didn't work, you have to update p7zip
  if [ ! -e $FOLDER_ISO_CUSTOM ]; then
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
    curl --output "${FOLDER_ISO_CUSTOM}/sshkey.pub" "https://raw.github.com/mitchellh/vagrant/master/keys/vagrant.pub"
  fi

  # Add sudo config file
  cp "${BASEDIR}/user.sudo" "${FOLDER_ISO_CUSTOM}/user.sudo"

  echo "Running mkisofs ..."
  "$MKISOFS" -r -V "Custom Debian Install CD" \
    -cache-inodes -quiet \
    -J -l -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -o "${FOLDER_ISO}/custom.iso" "${FOLDER_ISO_CUSTOM}"
fi

echo "Creating VM Box..."
# create virtual machine
if ! VBoxManage showvminfo "${BOX}" >/dev/null 2>/dev/null; then
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

  VBoxManage modifyvm "${BOX}" \
    --natpf1 delete ssh

  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium emptydrive
fi

echo "Compacting the .vdi ..."
VBoxManage modifyhd "${FOLDER_VBOX}/${BOX}/${BOX}.vdi" --compact

echo "Building Vagrant Box ..."
vagrant package --base "${BOX}" --output "${BOX}.box"

# references:
# http://blog.ericwhite.ca/articles/2009/11/unattended-debian-lenny-install/
# http://docs-v1.vagrantup.com/v1/docs/base_boxes.html
# http://www.debian.org/releases/stable/example-preseed.txt
