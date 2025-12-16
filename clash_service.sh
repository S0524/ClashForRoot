#!/system/bin/sh

# 使用子shell在后台执行任务
(
    # 等待Android系统启动完成
    # 持续检查bootanim服务状态，直到其变为"stopped"表示系统启动完毕
    until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do
        sleep 10  # 每10秒检查一次
    done

    # 检查启动脚本是否存在
    if [ -f "/data/adb/clash/scripts/start.sh" ]; then
        # 为所有脚本文件设置执行权限
        chmod -R 755 /data/adb/clash/scripts/
        # 执行启动脚本，并将输出重定向到空设备（不显示输出）
        /data/adb/clash/scripts/start.sh >/dev/null 2>&1
    else
        # 如果启动脚本不存在，则记录错误日志
        echo "文件 /data/adb/clash/scripts/start.sh 未找到" > "/data/adb/clash/run/clash_service.log"
    fi
) &