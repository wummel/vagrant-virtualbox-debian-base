#!/bin/bash

BASEDIR=$(dirname "$0")
DEPLOY_USER=deploy

# public ssh key for vagrant user
mkdir -m 0700 "/home/$DEPLOY_USER/.ssh"
cp "${BASEDIR}/sshkey.pub" "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 0600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"

# install sudo config
cp "${BASEDIR}/user.sudo" "/etc/sudoers.d/${DEPLOY_USER}"
chmod 0440 "/etc/sudoers.d/${DEPLOY_USER}"
chown root:root "/etc/sudoers.d/${DEPLOY_USER}"

# display grub timeout and login promt after boot
sed -i \
  -e "s/quiet splash//" \
  -e "s/GRUB_TIMEOUT=[0-9]/GRUB_TIMEOUT=0/" \
  /etc/default/grub
update-grub

# clean up
apt-get clean
