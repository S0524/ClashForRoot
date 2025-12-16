#!/system/bin/sh

# 定义核心路径变量
box_dir="/data/adb/clash"
box_run="${box_dir}/run"
box_pid="${box_run}/box.pid"

# 以root权限执行命令
run_as_su() {
    su -c "$1"
}

# 停止Clash服务及iptables规则
stop_service() {
    echo "Service is shutting down"
    run_as_su "${box_dir}/scripts/box.iptables disable"
    run_as_su "${box_dir}/scripts/box.service stop"
}

# 启动Clash服务及iptables规则
start_service() {
    echo "Service is starting, please wait for a moment"
    run_as_su "${box_dir}/scripts/box.service start"
    run_as_su "${box_dir}/scripts/box.iptables enable"
}

# 核心逻辑：检查进程状态并执行对应操作
if [ -f "${box_pid}" ]; then
    PID=$(cat "${box_pid}")
    if [ -e "/proc/${PID}" ]; then
        stop_service
    else
        start_service
    fi
else
    start_service
fi

# 提示用户30秒后自动关闭窗口
echo -e "10秒后自动关闭"
sleep 10
kill -9 $$