#!/bin/bash

set -eux

log_dir=/var/vcap/sys/log/nginx
job_dir=/var/vcap/jobs/nginx
run_dir=/var/vcap/run/nginx
cfg_dir=$job_dir/config
bin_dir=$job_dir/bin
pid_file=$run_dir/nginx.pid

mkdir -p \
    $bin_dir \
    $cfg_dir \
    $job_dir \
    $log_dir \
    $run_dir \
    $run_dir/ext \
    $run_dir/logs

cp $cfg_dir/nginx.conf $run_dir
touch "# this is an auto generated do not edit" > $run_dir/ext/upstreams.conf
touch "# this is an auto generated do not edit" > $run_dir/ext/locations.conf

chown -R vcap:vcap $log_dir
chown -R vcap:vcap $run_dir

case $1 in
    start)
        ulimit -n 100000
        setcap cap_net_bind_service=+ep /var/vcap/packages/nginx/sbin/nginx
        exec chpst -u vcap:vcap "$job_dir/packages/nginx/sbin/nginx" \
            -c "$run_dir/nginx.conf" \
            -g "pid $pid_file;" \
            -p $run_dir
        ;;
    stop)
        kill "$(cat "$pid_file")"
        ;;
    *)
        echo "Usage: ctl {start|stop}"
        ;;
esac
