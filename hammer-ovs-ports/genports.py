#!/usr/bin/python
from __future__ import print_function
import random
import sys
import uuid


NUM=1000

def rand_mac():
    return "fa:16:3e:%02x:%02x:%02x" % (
	random.randint(0x00, 0xff),
	random.randint(0x00, 0xff),
	random.randint(0x00, 0xff))

for i in range(NUM):
    port_uuid = uuid.uuid4()
    port_mac = rand_mac()
    if i%2 == 0:
	port_type = 'VM'
    else:
	port_type = 'DHCP'

    print(str(port_uuid) + "," + port_mac +"," + port_type)
    	
