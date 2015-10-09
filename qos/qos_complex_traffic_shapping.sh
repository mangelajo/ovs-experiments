#!/bin/sh
#          +-----+-------+   veth   +-------------+
# $IF_A --(q) if-a-br   (q)---------| test-br-int +----$IF_B (the vm)     10.10.10.2
#          +-------------+          |             +----$IF_C (another vm) 10.10.10.3
#                                   +-------------+
#


EXT_BR=test-br-ex
INT_BR=test-br-int

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

IF_C=test_interfC
IF_C_2=test_interfC_ns
IP_C=10.10.10.3
NETNS_C=qos-netns-C


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
	ovs-vsctl add-br $EXT_BR
	ovs-vsctl add-br $INT_BR
    	#ovs-vsctl set-fail-mode $EXT_BR secure # no NORMAL forward rule by default


    ip link add $PATCH_PORT_A type veth peer name $PATCH_PORT_B
    ip link set $PATCH_PORT_A up
    ip link set $PATCH_PORT_B up

    ovs-vsctl add-port $EXT_BR $PATCH_PORT_A
    ovs-vsctl add-port $INT_BR $PATCH_PORT_B

    #ovs-vsctl set interface $PATCH_PORT_A type=patch options:peer=$PATCH_PORT_B
    #ovs-vsctl set interface $PATCH_PORT_B type=patch options:peer=$PATCH_PORT_A

    ip link add $IF_A type veth peer name $IF_A_2
    ip link add $IF_B type veth peer name $IF_B_2
    ip link add $IF_C type veth peer name $IF_C_2

    ovs-vsctl add-port $EXT_BR $IF_A
    ovs-vsctl add-port $INT_BR $IF_B
    ovs-vsctl add-port $INT_BR $IF_C

    ip link set $IF_A up
    ip link set $IF_B up
    ip link set $IF_C up

}

create_netns_and_set_interfaces() {

	ip netns add $NETNS_A
	ip netns add $NETNS_B
	ip netns add $NETNS_C
	ip link set $IF_A_2 netns $NETNS_A
	ip link set $IF_B_2 netns $NETNS_B
	ip link set $IF_C_2 netns $NETNS_C

	ip netns exec $NETNS_A ip addr add $IP_A/$NETMASK dev $IF_A_2
	ip netns exec $NETNS_B ip addr add $IP_B/$NETMASK dev $IF_B_2
	ip netns exec $NETNS_C ip addr add $IP_C/$NETMASK dev $IF_C_2

	ip netns exec $NETNS_A ip link set $IF_A_2 up
	ip netns exec $NETNS_B ip link set $IF_B_2 up
	ip netns exec $NETNS_C ip link set $IF_C_2 up
}

start_netservers()
{
	ip netns exec $NETNS_A netserver -D -p 1111 &
	ip netns exec $NETNS_A netserver -D -p 2222 &
	ip netns exec $NETNS_B netserver -D -p 1111 &
	ip netns exec $NETNS_B netserver -D -p 2222 &
	ip netns exec $NETNS_C netserver -D -p 1111 &
	ip netns exec $NETNS_C netserver -D -p 2222 &

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
	ip link del $IF_C || true
	ip link del $PATCH_PORT_A || true
        ip netns del $NETNS_A 2>/dev/null || echo "cleanup: $NETNS_A didn't exist"
        ip netns del $NETNS_B 2>/dev/null || echo "cleanup: $NETNS_B didn't exist"
        ip netns del $NETNS_C 2>/dev/null || echo "cleanup: $NETNS_B didn't exist"
	ovs-vsctl del-br $EXT_BR 2>/dev/null|| echo "cleanup: $EXT_BR didn't exist"
	ovs-vsctl del-br $INT_BR 2>/dev/null|| echo "cleanup: $INT_BR didn't exist"
	ovs-vsctl --all destroy qos || true
	ovs-vsctl --all destroy queue || true
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
        banner "A->B starting $1"
	ip netns exec $NETNS_A netperf -H $IP_B -p 1111 | grep -v MIGRATED 
	ip netns exec $NETNS_A netperf -t TCP_RR -H $IP_B -p 1111 | grep -v MIGRATED
}

bidirectional_netperf() { 
	banner "[$1] A->B  and A->C starting"
	ip netns exec $NETNS_A netperf -H $IP_B -p 1111 | grep -v MIGRATED >/tmp/netperf1.txt &
	PID1=$!
	ip netns exec $NETNS_A netperf -H $IP_C -p 1111 | grep -v MIGRATED >/tmp/netperf2.txt &
	PID2=$! 
	
	wait $PID1
	wait $PID2
	echo "\________________ A -> B ___________________/" >> /tmp/netperf1.txt
	echo "\________________ A -> C ___________________/" >> /tmp/netperf2.txt


	paste /tmp/netperf1.txt /tmp/netperf2.txt

#     disabled because it locks & breaks ???
#	banner "A->B  and A->C (UDP) starting $1"
#	ip netns exec $NETNS_A netperf -t UDP_STREAM -H $IP_B -p 1111 &
#	ip netns exec $NETNS_A netperf -t UDP_STREAM -H $IP_C -p 1111 
#	sleep 2 

	banner "[$1] A->B alone starting"
	ip netns exec $NETNS_A netperf -H $IP_B -p 1111 | grep -v MIGRATED 

	banner "[$1] A->C alone starting"
	ip netns exec $NETNS_A netperf -H $IP_C -p 1111 | grep -v MIGRATED

	banner "[$1] B->A starting"
	ip netns exec $NETNS_B netperf -H $IP_A -p 1111 | grep -v MIGRATED


	banner "[$1] B->C starting (in compute node -br-int-)"
	ip netns exec $NETNS_B netperf -H $IP_C -p 1111 | grep -v MIGRATED
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
	basic_netperf "with no QOS set "

}

basic_ratelimit_netperf(){

	pre_test
        ovs-vsctl set interface $IF_B ingress_policing_rate=1000
	ovs-vsctl set interface $IF_B ingress_policing_burst=100

	ovs-vsctl set interface $IF_A ingress_policing_rate=2000
	ovs-vsctl set interface $IF_A ingress_policing_burst=200

	bidirectional_netperf "ingress_policy_rate test (B 1Mbps, A 2Mbps)"

}
patch_port_netperf(){

    pre_test

    # destroy the veth link
    ovs-vsctl del-port $EXT_BR $PATCH_PORT_A
    ovs-vsctl del-port $INT_BR $PATCH_PORT_B

    ip link del $PATCH_PORT_A 

    ovs-vsctl add-port $EXT_BR $PATCH_PORT_A
    ovs-vsctl add-port $INT_BR $PATCH_PORT_B

    ovs-vsctl set interface $PATCH_PORT_A type=patch options:peer=$PATCH_PORT_B
    ovs-vsctl set interface $PATCH_PORT_B type=patch options:peer=$PATCH_PORT_A


    basic_netperf "PATCH PORT check"
}

htb_queue_ratelimit_overhead_netperf(){

    	pre_test
	# egress to port A - before leaving the network
	ovs-vsctl set Port $IF_A qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=$_100Gb queues=0=@q0 -- \
	 		--id=@q0 create Queue other-config:max-rate=$_100Gb 

    	# ingress from port A - just after entering the network
	ovs-vsctl set Port $PATCH_PORT_A qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=$_100Gb queues=0=@q0 -- \
			--id=@q0 create Queue other-config:max-rate=$_100Gb 

     
     IF_A_OFPORT=$(_find_br_ofport $EXT_BR $IF_A)
     PATCH_A_OFPORT=$(_find_br_ofport $EXT_BR $PATCH_PORT_A)

	
     MAC_A=$(_find_ns_if_mac $NETNS_A $IF_A_2)
     MAC_B=$(_find_ns_if_mac $NETNS_B $IF_B_2)
     MAC_C=$(_find_ns_if_mac $NETNS_C $IF_C_2)

     ovs-ofctl add-flow $EXT_BR "dl_dst=$MAC_B actions=enqueue:$PATCH_A_OFPORT:0"


     basic_netperf "HTB (overhead check)"
}

htb_queue_ratelimit_netperf(){
    	pre_test
	# egress to port A - before leaving the network
	ovs-vsctl set Port $IF_A qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=$_10Mb queues=0=@q0,1=@q1 -- \
	 		--id=@q0 create Queue other-config:max-rate=$_10Mb -- \
            		--id=@q1 create Queue other-config:min-rate=2100000 other-config:max-rate=4200000 

    	# ingress from port A - just after entering the network
	ovs-vsctl set Port $PATCH_PORT_A qos=@newqos -- \
	 		--id=@newqos create qos type=linux-htb other-config:max-rate=$_10Mb queues=0=@q0,1=@q1,2=@q2 -- \
			--id=@q0 create Queue other-config:max-rate=$_10Mb -- \
	 		--id=@q1 create Queue other-config:min-rate=7350000 other-config:max-rate=7350000 --\
			--id=@q2 create Queue other-config:min-rate=1050000 other-config:max-rate=9450000
     
     IF_A_OFPORT=$(_find_br_ofport $EXT_BR $IF_A)
     PATCH_A_OFPORT=$(_find_br_ofport $EXT_BR $PATCH_PORT_A)
	
     MAC_A=$(_find_ns_if_mac $NETNS_A $IF_A_2)
     MAC_B=$(_find_ns_if_mac $NETNS_B $IF_B_2)
     MAC_C=$(_find_ns_if_mac $NETNS_C $IF_C_2)

     ovs-ofctl add-flow $EXT_BR "dl_dst=$MAC_B actions=enqueue:$PATCH_A_OFPORT:1"
     ovs-ofctl add-flow $EXT_BR "dl_dst=$MAC_C actions=enqueue:$PATCH_A_OFPORT:2"


     ovs-ofctl add-flow $EXT_BR "dl_src=$MAC_B actions=enqueue:$IF_A_OFPORT:1" 
     ovs-ofctl add-flow $EXT_BR "dl_src=$MAC_C actions=enqueue:$IF_A_OFPORT:1" 

     bidirectional_netperf "HTB queue test -openvswitch-"
}


htb_tc_ratelimit_netperf(){
	pre_test
	# http://lartc.org/howto/lartc.cookbook.ultimate-tc.html (15.8.3)
	# egress VMs -> outside world
        tc qdisc add dev $PATCH_PORT_B root handle 1: htb default 255 
	tc class add dev $PATCH_PORT_B parent 1: classid 1:1 htb rate 10000kbit burst 100kbit
	tc class add dev $PATCH_PORT_B parent 1:1 classid 1:10 htb rate 7000kbit ceil 7000kbit burst 700kbit cburst 700kbit
	tc class add dev $PATCH_PORT_B parent 1:1 classid 1:20 htb rate 1000kbit ceil 9000kbit burst 1000kbit cburst 900kbit
	tc class add dev $PATCH_PORT_B parent 1:1 classid 1:255 htb rate 1kbit ceil 10000kbit burst 0kbit cburst 1000kbit

	tc filter add dev $PATCH_PORT_B parent 1: prio 1 u32 match ip src $IP_B/32 flowid 1:10
	#tc filter add dev $PATCH_PORT_B parent 1: prio 1 u32 match ip src $IP_C/32 flowid 1:20
  
	# ingress outside world -> VMs
	tc qdisc add dev $PATCH_PORT_A root handle 1: htb default 255 
	tc class add dev $PATCH_PORT_A parent 1: classid 1:1 htb rate 10000kbit burst 1000k
	tc class add dev $PATCH_PORT_A parent 1:1 classid 1:10 htb rate 7000kbit ceil 7000kbit burst 700kbit cburst 700kbit
	tc class add dev $PATCH_PORT_A parent 1:1 classid 1:20 htb rate 1000kbit ceil 9000kbit burst 100kbit cburst 900kbit
	tc class add dev $PATCH_PORT_A parent 1:1 classid 1:255 htb rate 1kbit ceil 10000kbit burst 0kbit cburst 1000kbit

	tc filter add dev $PATCH_PORT_A parent 1: prio 1 u32 match ip dst $IP_B/32 flowid 1:10
	#tc filter add dev $PATCH_PORT_A parent 1: prio 1 u32 match ip dst $IP_C/32 flowid 1:20
  
	bidirectional_netperf "HTB queue test -tc on veths-"
}
	

set -e

# MAIN SEQUENCE

prerequisites
#bare_netperf
#basic_ratelimit_netperf
#patch_port_netperf
#htb_queue_ratelimit_overhead_netperf
#htb_queue_ratelimit_netperf
htb_tc_ratelimit_netperf

kill_netservers 2>/dev/null 1>/dev/null
#cleanup
