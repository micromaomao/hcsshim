#!/bin/sh

export PATH="/usr/bin:/usr/local/bin:/bin:/root/bin:/sbin:/usr/sbin:/usr/local/sbin"
export HOME="/root"

mount -t sysfs sysfs /sys/
mount -t tracefs tracefs /sys/kernel/tracing/
pushd /sys/kernel/tracing/
echo 0 > tracing_on
echo 20000 > buffer_size_kb
/bin/vsockexec -o 2056 -e 2056 dmesg -w &
echo 1 > events/hyperv/enable
echo 0 > events/hyperv/hyperv_send_ipi_one/enable
echo 0 > events/hyperv/vmbus_setevent/enable
echo 1 > events/dev/enable
echo 1 > events/printk/enable
echo 1 > events/netvsc/enable

# echo '?*vmbus*' > set_ftrace_filter
# echo '?*netvsc*' >> set_ftrace_filter
# echo 'vmbus*' >> set_ftrace_filter
# echo 'netvsc*' >> set_ftrace_filter
# echo '!hvs_stream_enqueue' >> set_ftrace_filter
# echo '!vmbus_sendpacket' >> set_ftrace_filter
# echo '!hv_ringbuffer_write' >> set_ftrace_filter
# echo '!vmbus_setevent' >> set_ftrace_filter
# echo function > current_tracer

# echo '?*vmbus*' > set_graph_function
# echo '?*netvsc*' >> set_graph_function
# echo 'vmbus*' >> set_graph_function
# echo 'netvsc*' >> set_graph_function
# echo 'hvs_stream_enqueue' > set_graph_notrace
# echo 'vmbus_sendpacket' >> set_graph_notrace
# echo 'hv_ringbuffer_write' >> set_graph_notrace
# echo 'vmbus_setevent' >> set_graph_notrace

echo 'netvsc_device_add' > set_graph_function
echo 3 > /sys/kernel/tracing/max_graph_depth
echo function_graph > current_tracer

# sleep 0.1
/bin/vsockexec -o 2057 -e 2057 cat trace_pipe &
echo 1 > tracing_on
popd

/init -e 1 /bin/vsockexec -o 109 -e 109 /bin/gcs -v4 -log-format json -loglevel debug -scrub-logs
