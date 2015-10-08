#!/bin/sh
QOS_BR=qos-test-br

IF_A=test_interfA
IF_A_2=test_interfA_ns
IP_A=10.10.10.1
NETNS_A=qos-netns-A

IF_B=test_interfB
IF_B_2=test_interfB_ns
IP_B=10.10.10.2
NETNS_B=qos-netns-B

NETMASK=24


create_bridge_and_interfaces() {
	ovs-vsctl add-br $QOS_BR
	ip link add $IF_A type veth peer name $IF_A_2
	ip link add $IF_B type veth peer name $IF_B_2
	
	ovs-vsctl add-port $QOS_BR $IF_A
	ovs-vsctl add-port $QOS_BR $IF_B
    
    ip link set $IF_A up
    ip link set $IF_B up 
}

create_netns_and_set_interfaces() {

	ip netns add $NETNS_A
	ip netns add $NETNS_B
	ip link set $IF_A_2 netns $NETNS_A
	ip link set $IF_B_2 netns $NETNS_B
	ip netns exec $NETNS_A ip addr add $IP_A/$NETMASK dev $IF_A_2
	ip netns exec $NETNS_B ip addr add $IP_B/$NETMASK dev $IF_B_2
	
	ip netns exec $NETNS_A ip link set $IF_A_2 up
	ip netns exec $NETNS_B ip link set $IF_B_2 up
	#ip netns exec $NETNS_A ping -c 2 $IP_B
}

start_netservers()
{
	ip netns exec $NETNS_A netserver -D -p 1111 &
	ip netns exec $NETNS_A netserver -D -p 2222 &
	ip netns exec $NETNS_B netserver -D -p 1111 &
	ip netns exec $NETNS_B netserver -D -p 2222 &
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
	ovs-vsctl del-port $QOS_BR $IF_A || true
	ovs-vsctl del-port $QOS_BR $IF_B || true
	ip link del $IF_A || true
	ip link del $IF_B || true
    ip netns del $NETNS_A 2>/dev/null || echo "cleanup: $NETNS_A didn't exist"
    ip netns del $NETNS_B 2>/dev/null || echo "cleanup: $NETNS_B didn't exist"
	ovs-vsctl del-br $QOS_BR 2>/dev/null|| echo "cleanup: $QOS_TEST_BR didn't exist"
	ovs-vsctl --all destroy qos || true
	ovs-vsctl --all destroy queue || true
}

pre_test_base()
{
	banner "Clean up and set the test environment"
	cleanup
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


bidirectional_netperf() { 
	banner "A->B starting $1"
	ip netns exec $NETNS_A netperf -H $IP_B -p 1111

	banner "B->A starting $1"
	ip netns exec $NETNS_B netperf -H $IP_A -p 1111
}

banner()
{
	echo ""
	echo ------------------------------------------------------------------------
	echo -   $1
	echo ------------------------------------------------------------------------
}

bare_netperf() {

	pre_test
	banner "A->B starting netperf with no QOS set "
	ip netns exec $NETNS_A netperf -H $IP_B -p 1111

}

basic_ratelimit_netperf(){

	pre_test
    ovs-vsctl set interface $IF_B ingress_policing_rate=1000
	ovs-vsctl set interface $IF_B ingress_policing_burst=100

	ovs-vsctl set interface $IF_A ingress_policing_rate=2000
	ovs-vsctl set interface $IF_A ingress_policing_burst=200


	bidirectional_netperf "ingress_policy_rate test (B 1Mbps, A 2Mbps)"

}

htb_queue_ratelimit_netperf(){

	pre_test
	ovs-vsctl set Port $IF_A qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=2000000 queues=0=@q0 -- \
	 		--id=@q0 create Queue other-config:min-rate=2000000 other-config:max-rate=2000000

	ovs-vsctl set Port $IF_B qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=3000000 queues=0=@q0 -- \
	 		--id=@q0 create Queue other-config:min-rate=3000000 other-config:max-rate=3000000

	bidirectional_netperf "HTB queue test (3Mbps B, 2Mbps A)"

}


set -e

# MAIN SEQUENCE

prerequisites
bare_netperf
basic_ratelimit_netperf
htb_queue_ratelimit_netperf
kill_netservers
cleanup
