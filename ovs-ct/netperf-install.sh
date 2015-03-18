#!/bin/sh

#sudo yum install netperf -y  #:(
which netperf >/dev/null && exit 0

cd /tmp
curl ftp://ftp.netperf.org/netperf/netperf-2.6.0.tar.bz2 >netperf-2.6.0.tar.bz2
tar xvfj netperf-2.6.0.tar.bz2
cd netperf-2.6.0
./configure --prefix=/usr
make -j4
sudo make install
