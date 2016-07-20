#!/bin/bash

_add_dhcp_port() {
    # simulate dhcp port creation
    port_id=$1
    port_mac=$2
    port_name="tap${port_id:0:11}"
    ns_name="ns-$port_id"
    sudo ip netns add $ns_name
    sudo ovs-vsctl --timeout=120 -- --if-exists del-port $port_name -- add-port br-int $port_name -- set Interface $port_name external-ids:iface-id=$port_id external-ids:iface-status=active external-ids:attached-mac=$port_mac type=internal
    sudo ip link set $port_name address $port_mac
    sudo ip link set $port_name netns $ns_name
    sudo ip netns exec $ns_name ip link set $port_name mtu 1450
    sudo ip netns exec $ns_name ip link set $port_name up
}

_add_vm_port() {
    # simulate vm port creation
    port_id=$1
    port_mac=$2
    br_name="qbr${port_id:0:11}"
    qvo_name="qvo${port_id:0:11}"
    qvb_name="qvb${port_id:0:11}"
    sudo brctl addbr $br_name
    sudo brctl setfd $br_name 0
    sudo brctl stp $br_name off
    sudo ip link add $qvb_name type veth peer name $qvo_name
    sudo ip link set $qvb_name up
    sudo ip link set $qvb_name promisc on
#    sudo ip link set $qvb_name mtu 1450
    sudo ip link set $qvo_name up
    sudo ip link set $qvo_name promisc on
#    sudo ip link set $qvo_name mtu 1450
    sudo ip link set $br_name up
    sudo brctl addif $br_name $qvb_name
    sudo ovs-vsctl -- --if-exists del-port $qvo_name -- add-port br-int $qvo_name -- set Interface $qvo_name external-ids:iface-id=$port_id external-ids:iface-status=active external-ids:attached-mac=$port_mac external-ids:vm-uuid=388c2414-71be-4ad4-aeeb-c74ae28d984c
    sudo ip link set $qvo_name mtu 1450
}

_clean_up_dhcp_port() {
    port_id=$1
    port_name="tap${port_id:0:11}"
    ns_name="ns-$port_id"
    sudo ovs-vsctl --if-exists del-port $port_name
    sudo ip netns del $ns_name
}

_clean_up_vm_port() {
    port_id=$1
    br_name="qbr${port_id:0:11}"
    qvo_name="qvo${port_id:0:11}"
    qvb_name="qvb${port_id:0:11}"
    sudo ovs-vsctl --if-exists del-port $qvo_name
    sudo brctl delif $br_name $qvb_name
    sudo ip link set $br_name down
    sudo brctl delbr $br_name
    sudo ip link del $qvb_name
}

_find_br_ofport() {
  sudo ovs-ofctl show $1 | grep $2 | cut -d\( -f 1 | awk '{print $1}'
}

_find_vm_ofport() {
    port_id=$1
    qvo_name="qvo${port_id:0:11}"
    _find_br_ofport br-int $qvo_name
}

_find_dhcp_ofport(){
    port_id=$1
    port_name="tap${port_id:0:11}"
    _find_br_ofport br-int $port_name
}

set -e
set -x
INPUT_FILE=$1
INPUT_FILE=${INPUT_FILE:-port_list.csv}
IFS=,

while :
do

	while read port_id port_mac port_type
	do
	   if [[ "$port_type" == "VM" ]]; then
	      _clean_up_vm_port $port_id ||:
	   else
	      _clean_up_dhcp_port $port_id ||:  
	   fi

	done < $INPUT_FILE

	while read port_id port_mac port_type
	do
	   if [[ "$port_type" == "VM" ]]; then
		_add_vm_port $port_id $port_mac
	   else
		_add_dhcp_port $port_id $port_mac
	   fi
	done < $INPUT_FILE 


	sleep 5

	OFPORTS=""
	while read port_id port_mac port_type
	do
	   if [[ "$port_type" == "VM" ]]; then
		OFPORTS="$OFPORTS $(_find_vm_ofport $port_id)"
	   else
		OFPORTS="$OFPORTS $(_find_dhcp_ofport $port_id)"
	   fi
	done < $INPUT_FILE

	sorted=$(echo $OFPORTS | tr " " "\n" | sort)
	dedup=$(echo $OFPORTS  | tr " " "\n" | sort | uniq)
	if [ "$sorted" = "$dedup" ]; then
	    echo $dedup
	else
	    killall hammer_ovs_ports.sh ||:

	    echo "Duplicate detected!"
	    echo $sorted
	    echo $dedup
	    exit
	fi
done

