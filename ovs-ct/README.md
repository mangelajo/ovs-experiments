# Purpose
The purpose of this test is determine if an OVS+CT solution will
be faster than the OVS+LB+iptables solution.

# Architecture composition

## OVS+LB+iptables
```
(remote-port)<-->[(remote-veth) in ns-remote]
    | tag:1
ovs/br-int
    | tag:1
(filt-port)<---->(lb-filtport)
                       |
                   qbr-test (linux bridge)
                       |
                 (tap-port) <-- iptables+ipset rules
                       |
              [(filtered-veth) in ns-filtered]
```
## OVS+CT
```
(remote-port)<-->[(remote-veth) in ns-remote]
    | tag:1
ovs/br-int (OpenFlow rules)
    | tag:1
(filt-port)<---->[(filtered-veth) in ns-filtered]
```
# Conditions to be benchmarked
1. Initial connection establishment time
2. Max throughput on the same CPU

And how those are impacted by two variables:
* Number of filtering rules
* Number of security group IPs
