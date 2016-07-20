#!/bin/sh
#                        +-------------+
# 10.10.10.1 $IF_A-(int)-+test-br-int  +-(veth)--$IF_C    10.10.10.3
# 10.10.10.2 $IF_B-(int)-+             +-(veth)--$IF_D    10.10.10.4
#                        +-------------+
#


INT_BR=test-br-int

IF_A=ia_ns
IF_A_2=ia_ns
IP_A=10.10.10.1
NETNS_A=test-netns-A

IF_B=ib_ns
IF_B_2=ib_ns
IP_B=10.10.10.2
NETNS_B=test-netns-B

IF_C=test_interfC
IF_C_2=ic_ns
IP_C=10.10.10.3
NETNS_C=test-netns-C

IF_D=test_interfD
IF_D_2=id_ns
IP_D=10.10.10.4
NETNS_C=test-netns-C

NETMASK=24

# speed constants (bps)

 _10Mb=10000000
_100Mb=100000000
  _1Gb=1000000000
 _10Gb=10000000000
_100Gb=100000000000

_find_br_ofport() {
ovs-ofctl show $1 | grep $2 | cut -d\( -f 1 | awk '{print $1}'
}

_find_ns_if_mac() {
ip netns exec $1 ip link show $2 |  tail --lines 1 | cut -d' ' -f 6
}

create_bridge_and_interfaces() {
	ovs-vsctl add-br $INT_BR

    ip link add $IF_C type veth peer name $IF_C_2
    ip link add $IF_D type veth peer name $IF_D_2

    ovs-vsctl add-port $INT_BR $IF_C
    ovs-vsctl add-port $INT_BR $IF_D

    ovs-vsctl --timeout=120 -- --if-exists del-port $IF_A -- add-port \
                   $INT_BR $IF_A -- set Interface $IF_A type=internal

    ovs-vsctl --timeout=120 -- --if-exists del-port $IF_B -- add-port \
                   $INT_BR $IF_A -- set Interface $IF_B type=internal


    ip link set $IF_A up
    ip link set $IF_B up
    ip link set $IF_C up
    ip link set $IF_D up

}

create_netns_and_set_interfaces() {

	ip netns add $NETNS_A
	ip netns add $NETNS_B
	ip netns add $NETNS_C
	ip netns add $NETNS_D

	ip link set $IF_A_2 netns $NETNS_A
	ip link set $IF_B_2 netns $NETNS_B
	ip link set $IF_C_2 netns $NETNS_C
	ip link set $IF_D_2 netns $NETNS_D

	ip netns exec $NETNS_A ip addr add $IP_A/$NETMASK dev $IF_A_2
	ip netns exec $NETNS_B ip addr add $IP_B/$NETMASK dev $IF_B_2
	ip netns exec $NETNS_C ip addr add $IP_C/$NETMASK dev $IF_C_2
	ip netns exec $NETNS_D ip addr add $IP_D/$NETMASK dev $IF_D_2

	ip netns exec $NETNS_A ip link set $IF_A_2 up
	ip netns exec $NETNS_B ip link set $IF_B_2 up
	ip netns exec $NETNS_C ip link set $IF_C_2 up
	ip netns exec $NETNS_D ip link set $IF_D_2 up
}

start_netservers()
{
	ip netns exec $NETNS_B netserver -D -p 1111 &
	ip netns exec $NETNS_D netserver -D -p 1111 &

	sleep 2
}

kill_netservers()
{
	killall -9 netserver 2&>1 > /dev/null || echo "no netservers running"
}


prerequisites() {
	#sudo yum install netperf -y  #:(
	which netperf >/dev/null && return 0

	cd /tmp
	wget -c ftp://ftp.netperf.org/netperf/netperf-2.7.0.tar.bz2
	tar xvfj netperf-2.7.0.tar.bz2
	cd netperf-2.7.0
	./configure --prefix=/usr
	make install
}

cleanup() {
	kill_netservers
	ovs-vsctl del-port $INT_BR $IF_A || true
	ovs-vsctl del-port $INT_BR $IF_B || true
	ovs-vsctl del-port $INT_BR $IF_C || true
	ovs-vsctl del-port $INT_BR $IF_D || true
	ip link del $IF_A || true
	ip link del $IF_B || true
	ip link del $IF_C || true
	ip link del $IF_D || true
    ip netns del $NETNS_A 2>/dev/null || echo "cleanup: $NETNS_A didn't exist"
    ip netns del $NETNS_B 2>/dev/null || echo "cleanup: $NETNS_B didn't exist"
    ip netns del $NETNS_C 2>/dev/null || echo "cleanup: $NETNS_C didn't exist"
    ip netns del $NETNS_D 2>/dev/null || echo "cleanup: $NETNS_D didn't exist"
	ovs-vsctl del-br $INT_BR 2>/dev/null|| echo "cleanup: $INT_BR didn't exist"
}

pre_test_base()
{
	banner "Clean up and set the test environment"
	cleanup 2>/dev/null
	create_bridge_and_interfaces
}
pre_test_netns()
{
	create_netns_and_set_interfaces
	start_netservers
}

pre_test() {
	pre_test_base
	pre_test_netns
}

basic_netperf() {
    banner "A->B starting $1 (this is with veths)"
	ip netns exec $NETNS_A netperf -H $IP_B -p 1111 | grep -v MIGRATED 
	ip netns exec $NETNS_A netperf -t TCP_RR -H $IP_B -p 1111 | grep -v MIGRATED
    banner "C->D starting $1 (this is with patch ports)"
	ip netns exec $NETNS_C netperf -H $IP_D -p 1111 | grep -v MIGRATED 
	ip netns exec $NETNS_C netperf -t TCP_RR -H $IP_D -p 1111 | grep -v MIGRATED
}

banner()
{
	echo ""
	echo ------------------------------------------------------------------------
	echo -   $1
	echo ------------------------------------------------------------------------
}


set -e
set -x
# MAIN SEQUENCE

prerequisites
pre_test_base
pre_test_netns

basic_netperf
kill_netservers 2>/dev/null 1>/dev/null
cleanup
