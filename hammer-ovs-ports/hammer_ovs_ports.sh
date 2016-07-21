#!/bin/bash

_check_ofport_repeats() {
	TAIL=/tmp/$$.out
	tail --lines 500 /var/log/openvswitch/ovs-vswitchd.log | grep " on port " > $TAIL
	uniq_count=$(cat $TAIL | awk '{ print $8 }' | sort | uniq | wc --lines)
	sort_count=$(cat $TAIL | awk '{ print $8 }' | sort | wc --lines)

	if [[ "_$uniq_count" != "_$sort_count" ]]; then
		cat $TAIL | awk '{ print $8 }' | sort > "${TAIL}_sort"
		cat "${TAIL}_sort" | uniq > "${TAIL}_uniq"
		echo "ERROR: ofport repeats found ( ${uniq_count} == ${sort_count} )"
		diff "${TAIL}_sort" "${TAIL}_uniq"
		exit 1
	else
		echo "No ofport repeats, everything fine ( ${uniq_count} == ${sort_count} )"
	fi
}

_add_dhcp_port() {
    # simulate dhcp port creation
    port_id=$1
    port_mac=$2
    port_name="tap${port_id:0:11}"
    ns_name="ns-$port_id"
    ip netns add $ns_name
    WAIT=--no-wait
    ovs-vsctl --timeout=120 -- --if-exists del-port $port_name -- $WAIT add-port br-int $port_name -- set Interface $port_name external-ids:iface-id=$port_id external-ids:iface-status=active external-ids:attached-mac=$port_mac type=internal
    ip link set $port_name address $port_mac
    ip link set $port_name netns $ns_name
    ip netns exec $ns_name ip link set $port_name mtu 1450
    ip netns exec $ns_name ip link set $port_name up
}

_add_vm_port() {
    # simulate vm port creation
    port_id=$1
    port_mac=$2
    br_name="qbr${port_id:0:11}"
    qvo_name="qvo${port_id:0:11}"
    qvb_name="qvb${port_id:0:11}"
#    brctl addbr $br_name
#    brctl setfd $br_name 0
#    brctl stp $br_name off
    ip link add $qvb_name type veth peer name $qvo_name
#    ip link set $qvb_name up
#    ip link set $qvb_name promisc on
#    ip link set $qvb_name mtu 1450
#    ip link set $qvo_name up
#    ip link set $qvo_name promisc on
#    ip link set $qvo_name mtu 1450
#    ip link set $br_name up
#    brctl addif $br_name $qvb_name
    ovs-vsctl -- --if-exists del-port $qvo_name -- add-port br-int $qvo_name -- set Interface $qvo_name external-ids:iface-id=$port_id external-ids:iface-status=active external-ids:attached-mac=$port_mac external-ids:vm-uuid=388c2414-71be-4ad4-aeeb-c74ae28d984c
    ip link set $qvo_name mtu 1450
}

_clean_up_dhcp_port() {
    port_id=$1
    port_name="tap${port_id:0:11}"
    ns_name="ns-$port_id"
    ovs-vsctl --if-exists del-port $port_name
    ip netns del $ns_name
}

_clean_up_vm_port() {
    port_id=$1
    br_name="qbr${port_id:0:11}"
    qvo_name="qvo${port_id:0:11}"
    qvb_name="qvb${port_id:0:11}"
    ovs-vsctl --if-exists del-port $qvo_name
#    brctl delif $br_name $qvb_name
#    ip link set $br_name down
#    brctl delbr $br_name
    ip link del $qvb_name
}

_find_br_ofport() {
  ovs-ofctl show $1 | grep $2 | cut -d\( -f 1 | awk '{print $1}'
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
INPUT_FILE=$1
INPUT_FILE=${INPUT_FILE:-port_list.csv}
IFS=,

ovs-appctl vlog/set file:info

while :
do

	while read port_id port_mac port_type
	do
   	   echo cleaning up $port_type id:$port_id mac:$port_mac
	   if [[ "$port_type" == "VM" ]]; then
	      _clean_up_vm_port $port_id ||:
	   else
	      _clean_up_dhcp_port $port_id ||:  
	   fi

	done < $INPUT_FILE

	while read port_id port_mac port_type
	do
   	   echo adding $port_type id:$port_id mac:$port_mac
	   if [[ "$port_type" == "VM" ]]; then
		_add_vm_port $port_id $port_mac
	   else
		_add_dhcp_port $port_id $port_mac
	   fi
	   _check_ofport_repeats
	done < $INPUT_FILE 


done

