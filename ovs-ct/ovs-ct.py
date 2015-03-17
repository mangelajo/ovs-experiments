import argparse
import os
import subprocess

NETMASK = 24
SINGLE_HOST = -1
MODE_IPTABLES = 'iptables'
MODE_OPENFLOW = 'openflow'
DEFAULT_NIC = 'eth0:1'

# globals for the run method
check_calls = True
debug = False

def run(*args, **kwargs):
    global check_calls
    global debug
    if debug:
        print "run: ", args[0]
    kwargs['shell'] = True
    if check_calls:
        return subprocess.check_call(*args, **kwargs)
    else:
        return subprocess.call(*args, **kwargs)

class Firewall(object):
    def __init__(self, endpoint, rules):
        pass

    def setup(self):
        pass

class OpenFlowFirewall(Firewall):
    pass

class IptablesFirewall(Firewall):
    pass

class EndPoint(object):
    def __init__(self, ovs_bridge, ip_addr, port_prefix=None, netns=None,
                 linux_bridge=None):
        self.ovs_bridge = ovs_bridge
        self.ip_addr = ip_addr
        self.netns = netns
        self.linux_bridge = linux_bridge

        if netns:
            self.veth_br = "%s-br" % port_prefix
            self.veth_ns = "%s-ns" % port_prefix
            self.ip_port = self.veth_ns
            if self.linux_bridge:
                self.veth_ovs = "%s-ovs" % port_prefix
                self.veth_lbr = "%s-lbr" % port_prefix
                self.ovs_port = self.veth_ovs
            else:
                self.ovs_port = self.veth_br
        else:
            self.ovs_port = port_prefix
            self.ip_port = port_prefix

    def _create_veth_pair(self, veth_a, veth_b):
        run("ip link add %s type veth peer name %s" % (veth_a, veth_b))

    def _if_up(self, interface, netns=None):
        if netns:
            run("ip netns exec %s ip link set %s up" % (netns, interface))
        else:
            run("ip link set %s up" % interface)

    def _del_veth(self, veth):
        run("ip link del %s type veth" % veth)

    def provision(self):
        run("ovs-vsctl add-br %s" % self.ovs_bridge)
        netns_exec = ""
        if self.netns:
            run("ip netns add %s" % self.netns)
            self._create_veth_pair(self.veth_br, self.veth_ns)
            run("ip link set %s netns %s" % (self.veth_ns, self.netns))
            netns_exec = "ip netns exec %s " % self.netns
            if self.linux_bridge:
                run("brctl addbr %s" % self.linux_bridge)
                self._create_veth_pair(self.veth_ovs, self.veth_lbr)
                # add the 'instance' side
                run("brctl addif %s %s" % (self.linux_bridge, self.veth_br))
                # add the ovs side
                run("brctl addif %s %s" % (self.linux_bridge, self.veth_lbr))
                self._if_up(self.veth_br)
                self._if_up(self.veth_lbr)

            run("ovs-vsctl add-port %s %s" % (self.ovs_bridge, self.ovs_port))

        else:
            run("ovs-vsctl -- add-port %(bridge)s %(port)s "
                "-- set Interface %(port)s type=internal" % (
                    {'bridge': self.ovs_bridge,
                     'port': self.ovs_port}))
        run(netns_exec + "ip addr add %s/%d dev %s" % (
            self.ip_addr, NETMASK, self.ip_port))
        self._if_up(self.ovs_port)
        self._if_up(self.ip_port, self.netns)

    def cleanup(self):
        run("ovs-vsctl del-port %s %s" % (self.ovs_bridge, self.ovs_port))
        if self.netns:
            run("ip link del %s" % self.ovs_port)
            run("ip netns del %s" % self.netns)
            if self.linux_bridge:
                # this also deletes the two extra veths
                run("brctl delbr %s" % self.linux_bridge)

        run("ovs-vsctl del-br %s" % self.ovs_bridge)


class Patch(object):
    def __init__(self, ep1, ep2):
        self.patch_port1 = "int-patch-1"
        self.patch_port2 = "int-patch-2"
        self.ep1 = ep1
        self.ep2 = ep2

    def provision(self):
        self._patch_port(self.ep1, self.patch_port1, self.patch_port2)
        self._patch_port(self.ep2, self.patch_port2, self.patch_port1)

    def _patch_port(self, endpoint, patch_port, peer_port):
        data = {"bridge": endpoint.ovs_bridge,
                "patch_port": patch_port,
                "peer_port": peer_port}

        run("ovs-vsctl -- add-port %(bridge)s %(patch_port)s"
            " -- set Interface %(patch_port)s type=patch"
            " -- set Interface %(patch_port)s options:peer=%(peer_port)s"
            % data)

    def cleanup(self):
        run("ovs-vsctl del-port %s %s" % (self.ep1.ovs_bridge,
                                          self.patch_port1))
        run("ovs-vsctl del-port %s %s" % (self.ep2.ovs_bridge,
                                          self.patch_port2))


def create_configuration(host=SINGLE_HOST, mode=MODE_IPTABLES):
    provision_list = []
    cleanup_list = []
    ep = []

    if mode == MODE_IPTABLES:
        ep.append(EndPoint("bridge1", "169.254.10.1", "test-port1",
                           "port1-ns", "lbr1"))
        ep.append(EndPoint("bridge2", "169.254.10.2", "test-port2",
                           "port2-ns", "lbr2"))

    elif mode == MODE_OPENFLOW:
        if host == SINGLE_HOST:
            port_ns = ["port1-ns", "port2-ns"]
        else:
            port_ns = [None, None]

        ep.append(EndPoint("bridge1", "169.254.10.1", "test-port1",
                           port_ns[0]))
        ep.append(EndPoint("bridge2", "169.254.10.2", "test-port2",
                           port_ns[1]))

    if host == SINGLE_HOST:
        patch = Patch(ep[0], ep[1])
        provision_list = [ep[0],ep[1], patch]
        cleanup_list = [patch, ep[0], ep[1]]
    else:
        provision_list = [ep[host]]
        cleanup_list = [ep[host]]

    return provision_list, cleanup_list


def test(provision_list, cleanup_list):
    print "testing provision-----"
    for item in provision_list:
        item.provision()

    print "testing cleanup-----"
    for item in cleanup_list:
        item.cleanup()


def do_argparse():
    parser = argparse.ArgumentParser(description='OVS CT OF vs Iptables neutron testing')
    parser.add_argument('command', help='What to do: test, setup, cleanup')
    parser.add_argument('--host', type=int, help="Host 0 or 1 for testing "
                        "(single host if not specified)",
                        default=SINGLE_HOST, choices=xrange(0, 2))
    parser.add_argument('--nic', type=str, default=DEFAULT_NIC,
                        help="NIC to connect as wired connection when not"
                             "testing on single host")
    parser.add_argument('--mode', type=str, required=True,
                        choices=[MODE_OPENFLOW, MODE_IPTABLES])
    parser.add_argument('--debug', default=False,
                        action='store_true')
    return parser.parse_args()


def main():
    global debug
    global check_calls
    args = do_argparse()
    provision_order, cleanup_order = create_configuration(
        args.host, args.mode)
    debug = args.debug
    if args.command == 'test':
        debug = True
        test(provision_order, cleanup_order)
    elif args.command == 'setup':
        for item in provision_order:
            item.provision()
    elif args.command == 'cleanup':
        check_calls = False
        for item in cleanup_order:
            item.cleanup()

if __name__ == "__main__":
    main()
