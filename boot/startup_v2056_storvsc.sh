#!/bin/sh

export PATH="/usr/bin:/usr/local/bin:/bin:/root/bin:/sbin:/usr/sbin:/usr/local/sbin"
export HOME="/root"

/bin/vsockexec -o 2056 -e 2056 echo Running startup_v2056.sh
/bin/vsockexec -o 2056 -e 2056 date

echo /init -e 1 /bin/sleep infinity > /dev/kmsg
/init -e 1 /bin/sleep infinity

/bin/vsockexec -o 2056 -e 2056 /bin/dmesg -w &

sleep 0.1

kernel_version=`uname -a`
cmdline=`cat /proc/cmdline`
echo "\
---------------------------
$kernel_version
$cmdline
---------------------------
" > /dev/kmsg

function net_watch() {
  i=0
  silent=0
  while :; do
    i=$((i+1))
    if [ -e /sys/bus/vmbus/devices/*/net ]; then
      echo 'Network devices found! (i.e. failed to reproduce issue)'
      echo "If the VM doesn't terminate, press x. Then retry the test."
      sleep 2
      exit
    fi
    if [[ $i == 50 ]]; then
      echo '/sys/bus/vmbus/devices/*/net failed to turn up in 5 seconds.'
      echo 'This means we have reproduced the bug.'
      echo 'In 30 seconds, the kernel will print a task hung warning.'
      echo 'Press x to exit afterwards.'
      silent=1
    fi
    if [[ $((i%20)) == 0 && $silent == 0 ]]; then
      echo 'Waiting for /sys/bus/vmbus/devices/*/net to turn up...'
    fi
    sleep 0.1
  done
}

net_watch > /dev/kmsg 2>/dev/kmsg
