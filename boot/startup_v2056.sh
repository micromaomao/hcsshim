#!/bin/sh

export PATH="/usr/bin:/usr/local/bin:/bin:/root/bin:/sbin:/usr/sbin:/usr/local/sbin"
export HOME="/root"

/bin/vsockexec -o 2056 -e 2056 echo Running startup_v2056.sh
/bin/vsockexec -o 2056 -e 2056 date

echo /init -e 1 /bin/sleep infinity > /dev/kmsg
/init -e 1 /bin/sleep infinity

/bin/vsockexec -o 2056 -e 2056 /bin/dmesg -w &

sleep 0.1

mount -t tracefs tracefs /sys/kernel/tracing/
pushd /sys/kernel/tracing/
echo 0 > tracing_on
echo 150000 > buffer_size_kb

echo 1 > tracing_on

# /bin/vsockexec -o 2057 -e 2057 cat trace_pipe &

popd

sleep 0.1

# /bin/busybox getty 115200 ttyS0 vt102 > /dev/kmsg 2>/dev/kmsg

function exec_loop() {
  count=0
  exec_cmd=$@
  while :; do
    $exec_cmd 2>/dev/null
    count=$((count+1))
    if [[ $((count%10000)) == 0 ]]; then
      echo "$count $exec_cmd runs" > /dev/kmsg
    fi
  done
}

kernel_version=`uname -a`
cmdline=`cat /proc/cmdline`
echo "\
-----------------------
$kernel_version
$cmdline
-----------------------
" > /dev/kmsg

echo "\
If no serial console is connected and the kernel crashes, you will only see \"Connection closed\" and maybe the VM terminates.
Enter \"x\" in the uvmtester.exe window to exit.
" > /dev/kmsg

cd /busybox-musl
exec_loop ./busybox ls loooooooooooooooooooooooooooooooooooooooonnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnggggggggggggggggggggg
# exec_loop segfault-generator
