#!/bin/bash

set -eux

log_dir=/var/vcap/sys/log/router
job_dir=/var/vcap/jobs/router
run_dir=/var/vcap/run/router
cfg_dir=$job_dir/config
bin_dir=$job_dir/bin
pid_file=$run_dir/router.pid

mkdir -p \
    $bin_dir \
    $cfg_dir \
    $job_dir \
    $log_dir \
    $run_dir

chown -R vcap:vcap $log_dir
chown -R vcap:vcap $run_dir

case $1 in
    start)
        echo $$ > $pid_file
        export PATH=$job_dir/packages/ruby/bin:$job_dir/packages/rtr/bin:$PATH

        exec chpst -u vcap:vcap ruby "$job_dir/packages/router/start.rb"
        ;;
    stop)
        kill "$(cat "$pid_file")"
        ;;
    *)
        echo "Usage: ctl {start|stop}"
        ;;
esac
