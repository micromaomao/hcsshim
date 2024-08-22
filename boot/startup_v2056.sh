#!/bin/sh

export PATH="/usr/bin:/usr/local/bin:/bin:/root/bin:/sbin:/usr/sbin:/usr/local/sbin"
export HOME="/root"

/bin/vsockexec -o 2056 -e 2056 echo Running startup_v2056.sh
/bin/vsockexec -o 2056 -e 2056 date

/bin/vsockexec -o 2056 -e 2056 echo /init -e 1 /bin/vsockexec -o 2056 -e 109 /bin/gcs -v4 -log-format text -loglevel debug -logfile /tmp/gcs.log
/init -e 1 /bin/vsockexec -o 2056 -e 109 /bin/gcs -v4 -log-format text -loglevel debug -logfile /tmp/gcs.log

/bin/vsockexec -o 2056 -e 2056 echo ls -l /dev/dm*
/bin/vsockexec -o 2056 -e 2056 ls -l /dev/dm*
/bin/vsockexec -o 2056 -e 2056 echo ls -l /dev/mapper
/bin/vsockexec -o 2056 -e 2056 ls -l /dev/mapper
/bin/vsockexec -o 2056 -e 2056 echo ls -l /dev/mapper
/bin/vsockexec -o 2056 -e 2056 ls -l /dev/mapper

#/bin/vsockexec -o 2056 -e 2056 /bin/snp-report

# need init to have run before top shows much
/bin/vsockexec -o 2056 -e 2056 top -n 1

/bin/vsockexec -o 2056 -e 2056 echo tmp
/bin/vsockexec -o 2056 -e 2056 ls -la /tmp


/bin/vsockexec -o 2056 -e 2056 /bin/dmesg -c

# /bin/vsockexec -o 2056 -e 2056 sh -c '
#   for i in $(seq 1 10); do
#     tar -c --exclude '\''dev|proc|sys|mnt|tmp'\'' --exclude proc --exclude sys --exclude mnt --exclude tmp / | tar --list
#     echo 3 > /proc/sys/vm/drop_caches
#   done
# '
exit

/bin/vsockexec -o 2056 -e 2056 sh -c '
  function mount_disks() {
    mount -t tmpfs tmpfs /mnt
    alldisks=$(echo sd{b..z} sda{a..n})
    for disk in $alldisks; do
      echo Waiting for /dev/$disk
      while [ ! -e /dev/$disk ]; do :; done
      mkdir -p /mnt/$disk
      mount -o ro /dev/$disk /mnt/$disk
      echo Mounted /dev/$disk
    done
    sleep 0.5
    for disk in $alldisks; do
      umount /mnt/$disk
      echo Unmounted /mnt/$disk
    done
  }
  mount_disks &
  for i in $(seq 1 10); do
    sha256sum /dev/sda
    dmesg -c
    echo 3 > /proc/sys/vm/drop_caches
  done
  sleep 3
  echo Clean exit
  exit
'
