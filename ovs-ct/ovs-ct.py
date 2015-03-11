import os
import subprocess

MULTI_HOST = os.environ.get('MULTI_HOST', False)
NETMASK=24

def run(*args, **kwargs):
    print "run: ", args[0]
    kwargs['shell'] = True
    return subprocess.check_call(*args, **kwargs)

class Firewall(object):
    def __init__(self, endpoint, rules):
        pass

    def setup(self)
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

        #TODO(mangelajo): still missing the linux bridge piece
        if netns:
            self.veth_ovs = "%s-ovs" % port_prefix
            self.ovs_port = self.veth_ovs
            self.veth_ns = "%s-ns" % port_prefix
            self.ip_port = self.veth_ns
        else:
            self.ovs_port = port_prefix
            self.ip_port = port_prefix

    def provision(self):

        #TODO(mangelajo): still missing the linux bridge piece
        run("ovs-vsctl add-br %s" % self.ovs_bridge)
        netns_exec = ""
        if self.netns:
            run("ip netns add %s" % self.netns)
            run("ip link add %s type veth peer name %s" % (self.veth_ovs,
                                                           self.veth_ns))
            run("ip link set %s netns %s" % (self.veth_ns, self.netns))
            netns_exec = "ip netns exec %s " % self.netns
            run("ovs-vsctl add-port %s %s" % (self.ovs_bridge, self.ovs_port))
        else:
            run("ovs-vsctl -- add-port %(bridge)s %(port)s "
                "-- set Interface %(port)s type=internal" % (
                    {'bridge': self.ovs_bridge,
                     'port': self.ovs_port}))
        run(netns_exec + "ip addr add %s/%d dev %s" % (
            self.ip_addr, NETMASK, self.ip_port))

    def cleanup(self):
        run("ovs-vsctl del-port %s %s" % (self.ovs_bridge, self.ovs_port))
        if self.netns:
            run("ip link del %s" % self.ovs_port)
            run("ip netns del %s" % self.netns)
        run("ovs-vsctl del-br %s" % self.ovs_bridge)



print "----with-namespaces------"
ep1 = EndPoint("bridge1", "169.254.10.1", "test-port1", "port1-ns")
ep1.provision()
ep1.cleanup()

print "----without-namespaces-----"
ep2 = EndPoint("bridge2", "169.254.10.2", "test-port2")
ep2.provision()
ep2.cleanup()


