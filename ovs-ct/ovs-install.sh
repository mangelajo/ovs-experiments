#!/bin/sh
set -e
set -x
OVS_GIT=https://github.com/justinpettit/ovs.git
OVS_BRANCH=conntrack

# openvswitch specifics
sudo yum -y install openssl-devel libtool rpm-build gcc g++ kernel-headers kernel-devel
git clone $OVS_GIT ovs || echo already cloned
cd ovs
git checkout -b $OVS_BRANCH || echo can\'t checkout branch

# create dist files
./boot.sh
./configure --prefix=/usr
rm -rf openvswitch*.tar.gz
make dist
mkdir -p ~/rpmbuild/SOURCES
cp openvswitch-*.tar.gz $HOME/rpmbuild/SOURCES

sudo setenforce 0
sudo sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
sudo service openvswitch stop || echo couldn\'t stop

# build userland
rm -rf build
mkdir build
cd build
tar xvfz ../*tar.gz
cd openvswitch-*
rpmbuild -bb --without check rhel/openvswitch-fedora.spec
sudo yum install -y /home/centos/rpmbuild/RPMS/x86_64/openvswitch* || \
  sudo yum install -y /home/centos/rpmbuild/RPMS/x86_64/openvswitch*

# build kernel
sudo sed -i 's/enabled=0/enabled=1/g' /etc/yum.repos.d/CentOS-Sources.repo
yumdownloader --source kernel
rpm -i --force kernel*.rpm
export KVERSION=$(uname -r)
rpmbuild -bb rhel/openvswitch-kmod-fedora.spec -D "kversion $KVERSION"
sudo yum install -y /home/centos/rpmbuild/RPMS/x86_64/openvswitch-kmod* || \
  sudo yum install -y /home/centos/rpmbuild/RPMS/x86_64/openvswitch-kmod*

sudo rmmod openvswitch || echo ok
sudo modprobe nf_conntrack
sudo insmod /lib/modules/$KVERSION/kernel/extra/openvswitch/openvswitch.ko
