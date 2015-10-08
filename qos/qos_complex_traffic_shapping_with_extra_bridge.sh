#!/bin/sh
#          +-------------+
#          | qos-a-br    | <-- used to gain control over the ingress path
#          +----(q)------+
#                | (veth)
#          +-----+-------+   patch  +-------------+
# $IF_A --(q) if-a-br    |----------| test-br-int |----$IF_B (the vm)
#          +-------------+          +-------------+
#
#


EXT_BR=test-br-ex
INT_BR=test-br-int
QOS_BR=br-ex-qos

QOS_PORT_A_OUT=qosA-out
QOS_PORT_A_IN=qosA-in

QOS_PORT_B_OUT=qosB-out
QOS_PORT_B_IN=qosB-in

PATCH_PORT_A=patchA-B
PATCH_PORT_B=patchB-A

IF_A=test_interfA
IF_A_2=test_interfA_ns
IP_A=10.10.10.1
NETNS_A=qos-netns-A

IF_B=test_interfB
IF_B_2=test_interfB_ns
IP_B=10.10.10.2
NETNS_B=qos-netns-B

NETMASK=24

_find_br_ofport() {
ovs-ofctl show $1 | grep $2 | cut -d\( -f 1 | awk '{print $1}'
}

create_bridge_and_interfaces() {
	ovs-vsctl add-br $EXT_BR
	ovs-vsctl add-br $INT_BR
    ovs-vsctl add-br $QOS_BR
    ovs-vsctl set-fail-mode $QOS_BR secure # no NORMAL forward rule by default
    ovs-vsctl set-fail-mode $EXT_BR secure # no NORMAL forward rule by default
    ovs-vsctl add-port $EXT_BR $PATCH_PORT_A
    ovs-vsctl set interface $PATCH_PORT_A type=patch
    ovs-vsctl set interface $PATCH_PORT_A options:peer=$PATCH_PORT_B

    ovs-vsctl add-port $INT_BR $PATCH_PORT_B
    ovs-vsctl set interface $PATCH_PORT_B type=patch
    ovs-vsctl set interface $PATCH_PORT_B options:peer=$PATCH_PORT_A

   # two veths, one goes from ext bridge to qos, the other
   # one moves traffic from QoS bridge to ext bridge again.

    ip link add $QOS_PORT_A_OUT type veth peer name $QOS_PORT_A_IN
    ip link add $QOS_PORT_B_OUT type veth peer name $QOS_PORT_B_IN

    ovs-vsctl add-port $EXT_BR $QOS_PORT_A_OUT
    ovs-vsctl add-port $QOS_BR $QOS_PORT_A_IN
    ovs-vsctl add-port $QOS_BR $QOS_PORT_B_OUT
    ovs-vsctl add-port $EXT_BR $QOS_PORT_B_IN
    ip link set $QOS_PORT_A_OUT up
    ip link set $QOS_PORT_A_IN up
    ip link set $QOS_PORT_B_OUT up
    ip link set $QOS_PORT_B_IN up

    ip link add $IF_A type veth peer name $IF_A_2
    ip link add $IF_B type veth peer name $IF_B_2

    ovs-vsctl add-port $EXT_BR $IF_A
    ovs-vsctl add-port $INT_BR $IF_B

    ip link set $IF_A up
    ip link set $IF_B up

    # outgoing traffic br-int -> ext
    PATCH_A_OFPORT=$(_find_br_ofport $EXT_BR $PATCH_PORT_A)
    IF_A_OFPORT=$(_find_br_ofport $EXT_BR $IF_A)
    ovs-ofctl add-flow $EXT_BR "in_port=$PATCH_A_OFPORT actions=output:$IF_A_OFPORT"

    # incoming traffic before QoS ingress
    QOS_A_OUT_OFPORT=$(_find_br_ofport $EXT_BR $QOS_PORT_A_OUT)
    ovs-ofctl add-flow $EXT_BR "in_port=$IF_A_OFPORT actions=output:$QOS_A_OUT_OFPORT"

    # incoming traffic, after QoS ingress
    QOS_B_IN_OFPORT=$(_find_br_ofport $EXT_BR $QOS_PORT_B_IN)
    ovs-ofctl add-flow $EXT_BR "in_port=$QOS_B_IN_OFPORT actions=output:$PATCH_A_OFPORT"

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
	ovs-vsctl del-port $EXT_BR $IF_A || true
	ovs-vsctl del-port $INT_BR $IF_B || true
	ip link del $IF_A || true
	ip link del $IF_B || true
	ip link del $QOS_PORT_A_OUT || true
        ip link del $QOS_PORT_A_IN || true
        ip link del $QOS_PORT_B_OUT || true
        ip link del $QOS_PORT_B_IN || true
        ip netns del $NETNS_A 2>/dev/null || echo "cleanup: $NETNS_A didn't exist"
        ip netns del $NETNS_B 2>/dev/null || echo "cleanup: $NETNS_B didn't exist"
	ovs-vsctl del-br $EXT_BR 2>/dev/null|| echo "cleanup: $EXT_BR didn't exist"
	ovs-vsctl del-br $INT_BR 2>/dev/null|| echo "cleanup: $INT_BR didn't exist"
	ovs-vsctl del-br $QOS_BR 2>/dev/null|| echo "cleanup: $QOS_BR didn't exist"
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
	# egress to port A - before leaving the network
	ovs-vsctl set Port $IF_A qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=10000000000 queues=0=@q0,1=@q1 -- \
	 		--id=@q0 create Queue other-config:max-rate=10000000000 -- \
            		--id=@q1 create Queue other-config:min-rate=2000000 other-config:max-rate=4000000 --

    	# ingress from port A - just after entering the network
	ovs-vsctl set Port $QOS_PORT_B_OUT qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=3000000 queues=0=@q0 -- \
	 		--id=@q0 create Queue other-config:min-rate=3000000 other-config:max-rate=3000000


     
     QOS_A_IN_OFPORT=$(_find_br_ofport $QOS_BR $QOS_PORT_A_IN)
     QOS_B_OUT_OFPORT=$(_find_br_ofport $QOS_BR $QOS_PORT_B_OUT)
     ovs-ofctl add-flow br-ex-qos "in_port=$QOS_A_IN_OFPORT actions=enqueue:$QOS_B_OUT_OFPORT:1"

	bidirectional_netperf "HTB queue test (3Mbps B, 2Mbps A)"

}


set -e

# MAIN SEQUENCE

prerequisites
#bare_netperf
#basic_ratelimit_netperf
htb_queue_ratelimit_netperf
kill_netservers
#cleanup
