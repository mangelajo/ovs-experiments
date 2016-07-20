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
    sudo ip link set $qvb_name mtu 1450
    sudo ip link set $qvo_name up
    sudo ip link set $qvo_name promisc on
    sudo ip link set $qvo_name mtu 1450
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



while :
do

VM_PORT_IDS=(12111111-2222-3333-4444-555555555551 14111111-2222-3333-4444-555555555551 16111111-2222-3333-4444-555555555551 22111111-2222-3333-4444-555555555551 24111111-2222-3333-4444-555555555551 26111111-2222-3333-4444-555555555551)
DHCP_PORT_IDS=(11111111-2222-3333-4444-555555555551 13111111-2222-3333-4444-555555555551 15111111-2222-3333-4444-555555555551 21111111-2222-3333-4444-555555555551 2311111-2222-3333-4444-555555555551 25111111-2222-3333-4444-555555555551)
for i in "${VM_PORT_IDS[@]}"
do
    _clean_up_vm_port $i ||:
done
for i in "${DHCP_PORT_IDS[@]}"
do
    _clean_up_dhcp_port $i ||:
done

_add_dhcp_port 11111111-2222-3333-4444-555555555551 fa:16:3e:bd:a4:91
_add_vm_port 12111111-2222-3333-4444-555555555551 fa:16:3e:2a:66:c2
_add_dhcp_port 13111111-2222-3333-4444-555555555551 fa:16:3e:bd:a4:93
_add_vm_port 14111111-2222-3333-4444-555555555551 fa:16:3e:2a:66:c4
_add_dhcp_port 15111111-2222-3333-4444-555555555551 fa:16:3e:bd:a4:95
_add_vm_port 16111111-2222-3333-4444-555555555551 fa:16:3e:2a:66:c6

sleep 1
_add_dhcp_port 21111111-2222-3333-4444-555555555551 fa:16:3e:bd:a4:01
_add_vm_port 22111111-2222-3333-4444-555555555551 fa:16:3e:2a:66:d2
_add_dhcp_port 2311111-2222-3333-4444-555555555551 fa:16:3e:bd:a4:03
_add_vm_port 24111111-2222-3333-4444-555555555551 fa:16:3e:2a:66:d4
_add_dhcp_port 25111111-2222-3333-4444-555555555551 fa:16:3e:bd:a4:05
_add_vm_port 26111111-2222-3333-4444-555555555551 fa:16:3e:2a:66:d6

OFPORTS=""
for i in "${VM_PORT_IDS[@]}"
do
    OFPORTS="$OFPORTS $(_find_vm_ofport $i)"
done
for i in "${DHCP_PORT_IDS[@]}"
do
    OFPORTS="$OFPORTS $(_find_dhcp_ofport $i)"
done

sorted=$(echo $OFPORTS | tr " " "\n" | sort)
dedup=$(echo $OFPORTS  | tr " " "\n" | sort | uniq)
if [ "$sorted" = "$dedup" ]; then
    echo $dedup
else
    echo "Duplicate detected!"
    echo $sorted
    echo $dedup
    exit
fi
done

