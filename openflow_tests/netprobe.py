#!/usr/bin/env python
from __future__ import print_function

import argparse
import datetime
import fcntl
import os
import re
import select
import sys
import subprocess
import time
import threading

__version__ = '0.0.2'

INTERFACE_RE = re.compile('\d+: (.+):')
DEFAULT_CHECK_INTERVAL = 1
DEFAULT_INTERFACE_RE = "tap.*|qg-.*|qr-.*"
DEFAULT_TCPDUMP_FILTER = '(arp or rarp) or (udp and (port 67 or port 68))' + \
                         ' or icmp or icmp6'
DEFAULT_OUTPUT_FILE = '/var/log/neutron/netprobe.log'


def _execute(cmd):
    _PIPE = subprocess.PIPE
    obj = subprocess.Popen(cmd, stdin=_PIPE, stdout=_PIPE, close_fds=True,
                           shell=False)
    result = obj.communicate()
    obj.stdin.close()
    (stdout, stderr) = result
    return stdout


def execute(cmd):
    # FIXME: super nasty hack to avoid a deadlock in the above function when
    #        calling ip link, I have spent 4 hours debugging it, enough for
    #        today...
    cmd_str = ' '.join(cmd)
    pid = os.getpid()
    os.system(cmd_str + ' >/tmp/exec_out{}'.format(pid))
    with open('/tmp/exec_out{}'.format(pid), 'r') as f:
        return f.read()


def netns():
    return map(lambda l: l.split('(')[0].strip(), 
	       filter(lambda line: len(line) > 0,
                      execute(['ip', 'netns']).split('\n')))


def _netns_cmd(netns=None):
    if netns:
        return ['ip', 'netns', 'exec', netns]
    else:
        return []


def interfaces(netns=None):
    cmd = _netns_cmd(netns) + ['ip', 'link']
    out = execute(cmd).split('\n')
    not_down = "\n".join(filter(lambda line: line.find(' DOWN ') == -1, out))
    return INTERFACE_RE.findall(not_down)


def _time_now():
    return datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]


def _date_now():
    return datetime.datetime.now().strftime('%Y-%m-%d')


def spawn_tcpdump(interface, netns=None,
                  filters=DEFAULT_TCPDUMP_FILTER):
    cmd = _netns_cmd(netns) + ['tcpdump', '-i', interface, '-n', '-e', '-l']
    cmd += [filters]
    print(' '.join(cmd), file=sys.stderr) 
    tcpdump = subprocess.Popen(cmd, bufsize=0,
                               stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    fd = tcpdump.stdout.fileno()
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    print(_time_now(), interface,
          "started dumping with filter {}".format(filters),
          file=output)
    while True:
        reads, writes, excs = select.select([tcpdump.stdout], [], [])
        try:
            out = reads[0].readline()
        except:
            continue
        if out == '':
            break
        line = out.rstrip()
        chunks = line.split(' ')
        timestamp = chunks[0]
        tcpdump_trace = ' '.join(chunks[1:])
        # FIXME: _date_now + tcpdump_timestamp can be raceful at the
        #        end of the day
        print(_date_now(), timestamp, interface, tcpdump_trace,
              file=output)


def parse_args():
    class MyParser(argparse.ArgumentParser):
        """Class to print verbose help on error."""
        def error(self, message):
            self.print_help()
            sys.stderr.write('\nerror: %s\n' % message)
            sys.exit(2)

    general_description = """
This tool will track system network devices as they appear in a host,
and start tcpdump processes for each of them, while the output of all
the tcpdumps goes in a single openstack-like log.
"""

    general_epilog = ""

    parser = MyParser(description=general_description, version=__version__,
                      epilog=general_epilog, argument_default='',
                      formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument('--netns-re', '-n', dest='netns_regex',
                        help='')
    parser.add_argument('--netdev-re', '-d', dest='netdev_regex',
                        help='', default=DEFAULT_INTERFACE_RE)
    parser.add_argument('--tcpdump-filter', '-t', dest='tcpdump_filter',
                        help='',
                        default=DEFAULT_TCPDUMP_FILTER)
    parser.add_argument('--check-interval', '-i', type=int,
                        default=DEFAULT_CHECK_INTERVAL,
                        dest='check_interval',
                        help='The interval between interface checks')

    parser.add_argument('--output-file', '-o',
                        default=DEFAULT_OUTPUT_FILE,
                        dest='output_file')

    return parser.parse_args()


def create_tcpdump_thread(interface, namespace, tcpdump_filter, thread_name):
    thread = threading.Thread(target=spawn_tcpdump,
                              name=thread_name,
                              kwargs={'interface': interface,
                                      'netns': namespace,
                                      'filters': tcpdump_filter})
    thread.start()
    return thread


def scan_loop(args):
    tracked_ifs = {}
    netns_re = re.compile(args.netns_regex)
    netdev_re = re.compile(args.netdev_regex)
    tcpdump_filter = args.tcpdump_filter
    while True:
        namespaces = filter(netns_re.match, netns()) + [None]
        for namespace in namespaces:
            ifs = filter(netdev_re.match, interfaces(namespace))
            for interface in ifs:
		interface = interface.split('@')[0]
                name = "{} (@ns {})".format(interface, namespace)
                if name not in tracked_ifs:
                    print(_time_now(),
                          "Watching interface {}".format(name),
                          file=output)
                    tracked_ifs[name] = create_tcpdump_thread(interface,
                                                              namespace,
                                                              tcpdump_filter,
                                                              name)
        # tcpdump thread go away when interface is removed
        for thread_name, thread in tracked_ifs.items():
            if not thread.is_alive():
                print(_time_now(),
                      "Interface {} went away".format(thread_name),
                      file=output)
                tracked_ifs.pop(thread_name).join()

        time.sleep(args.check_interval)


def main():
    global output
    args = parse_args()
    if args.output_file == '-':
	output = sys.stdout
    else:
        output = open(args.output_file, 'w', 0)
    scan_loop(args)

if __name__ == '__main__':
    main()
