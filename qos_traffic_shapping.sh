#!/bin/sh
QOS_BR=qos-test-br

IF_A=test_interf0
IP_A=10.10.10.1
NETNS_A=qos-netns-A

IF_B=test_interf1
IP_B=10.10.10.2
NETNS_B=qos-netns-B

NETMASK=24


create_bridge_and_interfaces() {

	ovs-vsctl add-br $QOS_BR
	ovs-vsctl -- --may-exist add-port $QOS_BR $IF_A -- set Interface $IF_A type=internal
	ovs-vsctl -- --may-exist add-port $QOS_BR $IF_B -- set Interface $IF_B type=internal
}

create_netns_and_set_interfaces() {

	ip netns add $NETNS_A
	ip netns add $NETNS_B
	ip link set $IF_A netns $NETNS_A
	ip link set $IF_B netns $NETNS_B
	ip netns exec $NETNS_A ip addr add $IP_A/$NETMASK dev $IF_A
	ip netns exec $NETNS_B ip addr add $IP_B/$NETMASK dev $IF_B
	
	ip netns exec $NETNS_A ip link set $IF_A up
	ip netns exec $NETNS_B ip link set $IF_B up
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
	killall -9 netserver || echo "no netservers running"
}

banner()
{
	echo ""
	echo ------------------------------------------------------------------------
	echo -   $1
	echo ------------------------------------------------------------------------
}

bare_netperf() {

	pre_test_base
	pre_test_netns
	banner "A->B starting netperf with no QOS set "
	ip netns exec $NETNS_A netperf -H $IP_B -p 1111

}

basic_ratelimit_netperf(){

	pre_test_base
    ovs-vsctl set interface $IF_B ingress_policing_rate=1000
	ovs-vsctl set interface $IF_B ingress_policing_burst=100
	ovs-vsctl set interface $IF_A ingress_policing_rate=1000
	ovs-vsctl set interface $IF_A ingress_policing_burst=100
	pre_test_netns
	banner "A->B starting ingress_policy_rate test 1Mbps"

	ip netns exec $NETNS_A netperf -H $IP_B -p 1111
}

htb_queue_ratelimit_netperf(){

	pre_test_base
	ovs-vsctl set Port $IF_A qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=1000000 queues=0=@q0 -- \
	 		--id=@q0 create Queue other-config:min-rate=1000000 other-config:max-rate=1000000


	pre_test_netns
	banner "A->B starting HTB queue test 1Mbps"

	ip netns exec $NETNS_A netperf -H $IP_B -p 1111
}




prerequisites() {
	#sudo yum install netperf -y  #:(
	which netperf >/dev/null && return 0

	cd /tmp
	wget -c ftp://ftp.netperf.org/netperf/netperf-2.6.0.tar.bz2
	tar xvfj netperf-2.6.0.tar.bz2
	cd netperf-2.6.0
	./configure --prefix=/usr
	make install
}

cleanup() {
	kill_netservers
    ip netns del $NETNS_A 2>/dev/null || echo "cleanup: $NETNS_A didn't exist"
    ip netns del $NETNS_B 2>/dev/null || echo "cleanup: $NETNS_B didn't exist"
	ovs-vsctl del-br $QOS_BR 2>/dev/null|| echo "cleanup: $QOS_TEST_BR didn't exist"
	ovs-vsctl --all destroy qos
	ovs-vsctl --all destroy queue
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

set -e


prerequisites
bare_netperf
basic_ratelimit_netperf
htb_queue_ratelimit_netperf
kill_netservers
