#!/system/bin/sh
# 校验 settings.ini 语法正确性
if ! /system/bin/sh -n /data/adb/clash/settings.ini 2>"/data/adb/clash/run/settings_err.log"; then
  echo "错误: settings.ini 包含语法错误" | tee -a "/data/adb/clash/run/settings_err.log"
  exit 1
fi

# 基础路径定义
scripts_dir="${0%/*}"
file_settings="/data/adb/clash/settings.ini"
moddir="/data/adb/modules/ClashForRoot"

#查找busybox
busybox="/data/adb/magisk/busybox"
[ -f "/data/adb/ksu/bin/busybox" ] && busybox="/data/adb/ksu/bin/busybox"
[ -f "/data/adb/ap/bin/busybox" ] && busybox="/data/adb/ap/bin/busybox"

# 等待 data 分区就绪
wait_for_data_ready() {
  while [ ! -f "/data/system/packages.xml" ] ; do
    sleep 1
  done
}

# 刷新服务
refresh_box() {
  if [ -f "/data/adb/clash/run/box.pid" ]; then
    "${scripts_dir}/box.service" stop >> "/dev/null" 2>&1
    "${scripts_dir}/box.iptables" disable >> "/dev/null" 2>&1
  fi
}

# 启动服务
start_service() {
  if [ ! -f "${moddir}/disable" ]; then
    "${scripts_dir}/box.service" start >> "/dev/null" 2>&1
  fi
}

# 启用 iptables 规则
enable_iptables() {
  PIDS=("clash")
  PID=""
  i=0
  # 查找运行中的 clash 进程
  while [ -z "$PID" ] && [ "$i" -lt "${#PIDS[@]}" ]; do
    PID=$($busybox pidof "${PIDS[$i]}")
    i=$((i+1))
  done
  # 存在进程则启用规则
  if [ -n "$PID" ]; then
    "${scripts_dir}/box.iptables" enable >> "/dev/null" 2>&1
  fi
}

# 网络监控
net_inotifyd() {
  net_dir="/data/misc/net"
  ctr_dir="/data/misc/net/rt_tables"
  while [ ! -f "$ctr_dir" ] && [ ! -f "$net_dir" ]; do
      sleep 3
  done
  inotifyd "${scripts_dir}/ctr.inotify" "$ctr_dir" >/dev/null 2>&1 &
  inotifyd "${scripts_dir}/net.inotify" "$net_dir" >/dev/null 2>&1 &
}

# 启动 inotifyd 监控
start_inotifyd() {
  PIDs=($($busybox pidof inotifyd))
  for PID in "${PIDs[@]}"; do
    if grep -q -e "box.inotify" -e "net.inotify" "/proc/$PID/cmdline"; then
      kill -9 "$PID"
    fi
  done
  inotifyd "${scripts_dir}/box.inotify" "${moddir}" > "/dev/null" 2>&1 &
  net_inotifyd
}

# 创建运行日志目录
mkdir -p /data/adb/clash/run/

# 手动模式处理
if [ -f "/data/adb/clash/manual" ]; then
  [ -f "/data/adb/clash/run/box.pid" ] && rm -rf /data/adb/clash/run/box.pid
  net_inotifyd
  exit 1
fi

# 启动服务流程
if [ -f "$file_settings" ] && [ -r "$file_settings" ] && [ -s "$file_settings" ]; then
  wait_for_data_ready
  refresh_box
  start_service
  enable_iptables
fi

start_inotifyd