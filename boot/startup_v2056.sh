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
echo 1 > events/hyperv/enable
echo 1 > events/dev/enable
echo 1 > events/printk/enable
echo 1 > events/netvsc/enable
echo 1 > events/irq_vectors/enable
echo 1 > events/syscalls/enable

echo '?*vmbus*' > set_ftrace_filter
echo '?*netvsc*' >> set_ftrace_filter
echo 'vmbus*' >> set_ftrace_filter
echo 'netvsc*' >> set_ftrace_filter
echo '__sysvec_hyperv_callback' >> set_ftrace_filter
echo 'sysvec_hyperv_callback' >> set_ftrace_filter
echo 'net_rx_action' >> set_ftrace_filter
echo 'hv_ghcb_hypercall' >> set_ftrace_filter
echo 'hv_ringbuffer_write' >> set_ftrace_filter
echo 'hv_signal_on_write' >> set_ftrace_filter
echo 'hv_*' >> set_ftrace_filter
echo '!hv_isolation_type_en_snp' >> set_ftrace_filter
echo 'sev_*' >> set_ftrace_filter
echo '?*sev*' >> set_ftrace_filter
echo 'tick*' >> set_ftrace_filter
echo 'clockevents*' >> set_ftrace_filter
echo 'irq_work*' >> set_ftrace_filter
echo 'hrtimer*' >> set_ftrace_filter
echo function > current_tracer

# echo '?*vmbus*' > set_graph_function
# echo '?*netvsc*' >> set_graph_function
# echo 'vmbus*' >> set_graph_function
# echo 'netvsc*' >> set_graph_function
# echo '__sysvec_hyperv_callback' >> set_graph_function
# echo 'sysvec_hyperv_callback' >> set_graph_function
# echo 'net_rx_action' >> set_graph_function
# echo 'netvsc_device_add' >> set_graph_function
# echo '_printk' > set_graph_notrace
# echo 'vprintk' >> set_graph_notrace
# echo 'serial8250_console_putchar' >> set_graph_notrace
# echo 5 > /sys/kernel/tracing/max_graph_depth
# echo function_graph > current_tracer

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
