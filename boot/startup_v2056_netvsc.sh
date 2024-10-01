#!/bin/sh

export PATH="/usr/bin:/usr/local/bin:/bin:/root/bin:/sbin:/usr/sbin:/usr/local/sbin"
export HOME="/root"

/bin/vsockexec -o 2056 -e 2056 echo Running startup_v2056.sh
/bin/vsockexec -o 2056 -e 2056 date

echo /init -e 1 /bin/sleep infinity > /dev/kmsg
/init -e 1 /bin/sleep infinity

touch /tmp/dmesg_file
/bin/vsockexec -o 2056 -e 2056 tail -f /tmp/dmesg_file &
touch /tmp/trace_file
/bin/vsockexec -o 2057 -e 2057 tail -f /tmp/trace_file &

sleep 0.1

mount -t tracefs tracefs /sys/kernel/tracing/
pushd /sys/kernel/tracing/
echo 0 > tracing_on
echo 150000 > buffer_size_kb
echo 1 > events/hyperv/enable
echo 1 > events/dev/enable
echo 1 > events/printk/enable
echo 1 > events/netvsc/enable
echo 1 > events/irq_vectors/enable

echo '?*vmbus*' > set_ftrace_filter
echo '?*netvsc*' >> set_ftrace_filter
echo 'vmbus*' >> set_ftrace_filter
echo 'netvsc*' >> set_ftrace_filter
# echo '__sysvec_hyperv_callback' >> set_ftrace_filter
# echo 'sysvec_hyperv_callback' >> set_ftrace_filter
# echo 'net_rx_action' >> set_ftrace_filter
# echo 'hv_ghcb_hypercall' >> set_ftrace_filter
# echo 'hv_ringbuffer_write' >> set_ftrace_filter
# echo 'hv_signal_on_write' >> set_ftrace_filter
# echo 'hv_*' >> set_ftrace_filter
# echo '!hv_isolation_type_en_snp' >> set_ftrace_filter
echo function > current_tracer

# echo '?*vmbus*' > set_graph_function
# echo '?*netvsc*' >> set_graph_function
# echo 'vmbus*' >> set_graph_function
# echo 'netvsc*' >> set_graph_function
# echo '__sysvec_hyperv_callback' >> set_graph_function
# echo 'sysvec_hyperv_callback' >> set_graph_function
# echo 'net_rx_action' >> set_graph_function
# echo 'netvsc_device_add' >> set_graph_function
# echo 5 > /sys/kernel/tracing/max_graph_depth
# echo function_graph > current_tracer

echo 1 > tracing_on

popd

sleep 0.1

kernel_version=`uname -a`
cmdline=`cat /proc/cmdline`
echo "\
---------------------------
$kernel_version
$cmdline
---------------------------
" > /dev/kmsg

function finish_ftrace() {
  echo 0 > /sys/kernel/tracing/tracing_on
  echo "finish_ftrace: sending full ftrace buffer" > /dev/kmsg
  # /bin/vsockexec -o 2057 -e 2057 cat /sys/kernel/tracing/trace
  cat /sys/kernel/tracing/trace >> /tmp/trace_file

  dmesg -c >> /tmp/dmesg_file
}

function net_watch() {
  i=0
  silent=0
  while :; do
    i=$((i+1))
    if [ -e /sys/bus/vmbus/devices/*/net ]; then
      echo 'Network devices found! (i.e. failed to reproduce issue)'
      echo "If the VM doesn't terminate, press x. Then retry the test."
      finish_ftrace
      sleep 2
      exit
    fi
    if [[ $i == 50 ]]; then
      echo '/sys/bus/vmbus/devices/*/net failed to turn up in 5 seconds.'
      echo 'This means we have reproduced the bug.'
      echo 'In 30 seconds, the kernel will print a task hung warning.'
      echo 'Press x to exit afterwards.'
      finish_ftrace
      dmesg -c -w >> /tmp/dmesg_file &
      silent=1
    fi
    if [[ $((i%20)) == 0 && $silent == 0 ]]; then
      echo 'Waiting for /sys/bus/vmbus/devices/*/net to turn up...'
    fi
    sleep 0.1
  done
}

net_watch > /dev/kmsg 2>/dev/kmsg
