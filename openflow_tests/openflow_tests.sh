#!/bin/sh
#
#	    $EXT_BR                   $INT_BR
#          +------------+  patch   +--------------+
# $IF_A ---+ if-a-br   (A)--------(B)test-br-int  +----$IF_B    10.10.10.2
#          +------------+          |              +----$IF_D    10.10.10.4
#                                  +------+-------+
#				  	  |
#					$IF_C (another vm/monitor) 
#						untagged: 10.10.10.3
#						vlan 1: patch port outgoing traffic (monitoring)
#					        vlan 2: IF_B port outgoing traffic (monitoring)	
#					        vlan 3: IF_D port outgoing traffic (monitoring)


EXT_BR=test-br-ex
INT_BR=test-br-int

PATCH_PORT_A=patchEXT
PATCH_PORT_B=patchINT

IF_A=test_interfA
IF_A_2=test_interfA_ns
IP_A=10.10.10.1
NETNS_A=test-netns-a

IF_B=test_interfB
IF_B_2=test_interfB_ns
IP_B=10.10.10.2
NETNS_B=test-netns-b

IF_C=test_monC
IF_C_2=test_monC_ns
IP_C=10.10.10.3
NETNS_C=test-monitor

IF_D=tetst_interfD
IF_D_2=test_interfD_ns
IP_D=10.10.10.4
NETNS_D=test-netns-d

NETMASK=24

_find_br_ofport() {
ovs-ofctl show $1 | grep $2 | cut -d\( -f 1 | awk '{print $1}'
}

_find_ns_if_mac() {
ip netns exec $1 ip link show $2 |  tail --lines 1 | cut -d' ' -f 6
}

create_bridge_and_interfaces() {
	ovs-vsctl add-br $EXT_BR
	ovs-vsctl add-br $INT_BR
   	ovs-vsctl set-fail-mode $EXT_BR secure # no NORMAL forward rule by default
   	ovs-vsctl set-fail-mode $INT_BR secure # no NORMAL forward rule by default


    if [ "${USE_VETH_PATCH}_" != "y_" ]; then
        ovs-vsctl add-port $EXT_BR $PATCH_PORT_A
        ovs-vsctl add-port $INT_BR $PATCH_PORT_B
        ovs-vsctl set interface $PATCH_PORT_A type=patch options:peer=$PATCH_PORT_B
        ovs-vsctl set interface $PATCH_PORT_B type=patch options:peer=$PATCH_PORT_A
    else
        ip link add $PATCH_PORT_A type veth peer name $PATCH_PORT_B
        ip link set $PATCH_PORT_A up
        ip link set $PATCH_PORT_B up
        ovs-vsctl add-port $EXT_BR $PATCH_PORT_A
        ovs-vsctl add-port $INT_BR $PATCH_PORT_B
    fi

    ip link add $IF_A type veth peer name $IF_A_2
    ip link add $IF_B type veth peer name $IF_B_2
    ip link add $IF_C type veth peer name $IF_C_2
    ip link add $IF_D type veth peer name $IF_D_2

    ovs-vsctl add-port $EXT_BR $IF_A
    ovs-vsctl add-port $INT_BR $IF_B
    ovs-vsctl add-port $INT_BR $IF_C
    ovs-vsctl add-port $INT_BR $IF_D

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

cleanup() {
	ovs-vsctl del-port $EXT_BR $IF_A || true
	ovs-vsctl del-port $INT_BR $IF_B || true
	ip link del $IF_A || true
	ip link del $IF_B || true
	ip link del $IF_C || true
	ip link del $IF_D || true

	#	ip link del $PATCH_PORT_A || true

    	ip netns del $NETNS_A 2>/dev/null || echo "cleanup: $NETNS_A didn't exist"
    	ip netns del $NETNS_B 2>/dev/null || echo "cleanup: $NETNS_B didn't exist"
    	ip netns del $NETNS_C 2>/dev/null || echo "cleanup: $NETNS_C didn't exist"
    	ip netns del $NETNS_D 2>/dev/null || echo "cleanup: $NETNS_D didn't exist"

	ovs-vsctl del-br $EXT_BR 2>/dev/null|| echo "cleanup: $EXT_BR didn't exist"
	ovs-vsctl del-br $INT_BR 2>/dev/null|| echo "cleanup: $INT_BR didn't exist"
}


setup_test_flows() {

	
     PATCH_BR_INT_OFPORT=$(_find_br_ofport $INT_BR $PATCH_PORT_B)
     IF_B_OFPORT=$(_find_br_ofport $INT_BR $IF_B)
     IF_D_OFPORT=$(_find_br_ofport $INT_BR $IF_D)
     MONITOR_OFPORT=$(_find_br_ofport $INT_BR $IF_C)

     MAC_A=$(_find_ns_if_mac $NETNS_A $IF_A_2)
     MAC_B=$(_find_ns_if_mac $NETNS_B $IF_B_2)
     MAC_C=$(_find_ns_if_mac $NETNS_C $IF_C_2)

     ovs-ofctl del-flows $EXT_BR
     ovs-ofctl del-flows $INT_BR

     ovs-ofctl add-flow $EXT_BR "table=0, action=NORMAL"

     # Monitoring flows 
     # (PATCH PORT -> vlan1 on MONITOR_PORT C)
     ovs-ofctl -O OpenFlow13 add-flow $INT_BR "table=0, priority=100, in_port=${PATCH_BR_INT_OFPORT}, action=push_vlan:0x8100,set_field:4097->vlan_vid,output:${MONITOR_OFPORT},pop_vlan,resubmit(,1)"
     # (PORT B -> vlan2 on MONITOR_PORT C)
     ovs-ofctl -O OpenFlow13 add-flow $INT_BR "table=0, priority=100, in_port=${IF_B_OFPORT}, action=push_vlan:0x8100,set_field:4098->vlan_vid,output:${MONITOR_OFPORT},pop_vlan,resubmit(,1)"
     # (PORT D -> vlan3 on MONITOR_PORT C)
     ovs-ofctl -O OpenFlow13 add-flow $INT_BR "table=0, priority=100, in_port=${IF_D_OFPORT}, action=push_vlan:0x8100,set_field:4099->vlan_vid,output:${MONITOR_OFPORT},pop_vlan,resubmit(,1)"
     # default jump to next table
     ovs-ofctl add-flow $INT_BR "table=0, priority=0, action=resubmit(,1)"

     # filter icmp responses from PORTB (still should be monitored as the monitor is pre-filter)
     ovs-ofctl add-flow $INT_BR "table=1, priority=100, in_port=${IF_B_OFPORT}, icmp, action=drop" # icmp from port B is dropped
     # normal to handle the traffic
     ovs-ofctl add-flow $INT_BR "table=1, priority=70, action=NORMAL"
}

run_traces() {

	echo "======================================================================"
	echo "				TRACES					    "
	echo "======================================================================"

     	MAC_B=$(_find_ns_if_mac $NETNS_B $IF_B_2)
        IF_A_OFPORT=$(_find_br_ofport $EXT_BR $IF_A)

	set -x
	ovs-appctl dpif/show

	ovs-ofctl dump-flows $EXT_BR
	ovs-ofctl dump-flows $INT_BR

	ovs-appctl ofproto/trace test-br-ex in_port=$IF_A_OFPORT,dl_dst=$MAC_B

	set +x
}

run_test() {
	echo "======================================================================"
	echo "				 TESTS"
	echo "======================================================================"
	sleep 10 # let ICMPv6 discoveries get to an end..
	# snoop on the IF_C (monitor port)
	./netprobe.py --netdev-re "test_monC.*_ns" -o - --tcpdump-filter "not icmp6" &
	netprobe_pid=$!
	sleep 2
	echo ""
	echo " * PING A->B"
	echo ""
        ip netns exec $NETNS_A ping $IP_B -c 4 || true
	echo ""
	echo " * PING A->D"
	echo ""
        ip netns exec $NETNS_A ping $IP_D -c 4 || true
	echo "=================================================================="
	kill -TERM $netprobe_pid
	killall tcpdump

}


##########################################################################
# MAIN
##########################################################################



# do we want only flows?
if [ "x$1" != "xonlyflows" ]; then
	cleanup

	set -e
	if [ "x$1" == "xcleanup" ]; then
		exit 0
	fi
	create_bridge_and_interfaces
	create_netns_and_set_interfaces
fi

setup_test_flows
run_traces
run_test
