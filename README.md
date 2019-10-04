## About

This script will:

 1. download and verify the latest `Debian 10 "buster"` CD image
 2. ... do some magic to turn it into a vagrant box file
 3. output `debian-buster-i386.box` or `debian-buster-amd64.box`

## Requirements

 * Oracle VM VirtualBox >= 4.3
 * Vagrant
 * mkisofs for generating a custom Debian CD image
 * 7zip for unpacking the Debian CD image
 * one of md5sum, sha1sum or sha256sum for Debian CD image hash check
 * recommended: gpg to verify the Debian CD image

## Configuration

Set the password hash of the `deploy` user in preseed.cfg.

    $ python3 -c 'import crypt; print(crypt.crypt("mypassword", crypt.mksalt(crypt.METHOD_SHA512)))'

Copy-paste the printed crypt(3) hash into preseed.cfg at the following line:

      d-i passwd/user-password-crypted password [crypt(3) hash]

Optional: see Environment Variables below for more configuration

## Usage on OSX

    ./build.sh

This should do everything you need. If you don't have `mkisofs` or `p7zip`, install [homebrew](http://mxcl.github.com/homebrew/), then:

    brew install cdrtools
    brew install p7zip

To add `debian-buster-amd64.box` with name `debian-buster` into vagrant:

    vagrant box add "debian-buster" debian-buster-amd64.box

## Usage on Linux

    ./build.sh

This should do everything you need. If you don't have `mkisofs` or `p7zip`:

    sudo apt-get install genisoimage
    sudo apt-get install p7zip-full

To add `debian-buster-amd64.box` with name `debian-buster` into vagrant:

    vagrant box add "debian-buster" debian-buster-amd64.box

## Usage on Windows (under cygwin/git shell)

    ./build.sh

Tested under Windows 7 with this tools:

 * [cpio](http://gnuwin32.sourceforge.net/packages/cpio.htm)
 * [md5](http://www.fourmilab.ch/md5/)
 * [7zip](http://www.7-zip.org/)
 * [mkisofs](http://sourceforge.net/projects/cdrtoolswin/)

## Environment variables

You can affect the default behaviour of the script using environment variables:

    VAR=value ./build.sh

The following variables are supported:

* `ARCH` - Architecture to build. Either `i386` or `amd64`. Default is `amd64`.

* `DEBIAN_CDIMAGE` - Domain to download the Debian installer from. Default is `cdimage.debian.org`. Example: `ftp.de.debian.org`.

* `PRESEED` - Path to custom preseed file. May be useful when if you need some customizations for your private base box (user name, passwords etc.).

* `LATE_CMD` - Path to custom late_command.sh. May be useful when if you need some customizations for your private base box (user name, passwords etc.).

* `VM_GUI` - If set to `yes` or `1`, disables headless mode for vm. May be useful for debugging installer.

* `SSHKEY` - Path to custom public SSH key file to be copied into the installer CDROM at `/sshkey.pub`. Can be used by late_command.sh. Example: `~/.ssh/id_rsa.pub`.

* `ANSIBLE_PLAYBOOK` - Optional ansible playbook to run.

* `ANSIBLE_SSHPORT` - Optional the SSH port for ansible. Default is `2222`.



### Notes

When the ansible playbook has errors, login to the running machine with
`ssh -p ${ANSIBLE_SSHPORT} deploy@localhost` for inspection or debugging.

This script is based on original Carl's [repo](https://github.com/cal/vagrant-ubuntu-precise-64) and with some tweaks to be Debian compatible.
