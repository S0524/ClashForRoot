#!/system/bin/sh

# 脚本配置变量
SKIPUNZIP=1
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

# 检查安装条件：必须在 Magisk/KernelSU/APatch 管理器中安装，不支持 Recovery 安装。
# 同时检查 KernelSU 版本是否满足最低要求（10670）。
if [ "$BOOTMODE" != true ]; then
  ui_print "请使用Magisk/KernelSU/APatch管理器安装"
  ui_print "不支持Recovery安装"
elif [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  ui_print "请升级KernelSU至10670及以上版本"
fi

# 根据运行环境设置服务目录路径，并打印当前使用的模块管理器及其版本信息
service_dir="/data/adb/service.d"
if [ "$KSU" = "true" ]; then
  ui_print "KernelSU版本:$KSU_VER ($KSU_VER_CODE)"
  [ "$KSU_VER_CODE" -lt 10683 ] && service_dir="/data/adb/ksu/service.d"
elif [ "$APATCH" = "true" ]; then
  APATCH_VER=$(cat "/data/adb/ap/version")
  ui_print "APatch版本:$APATCH_VER"
else
  ui_print "Magisk版本:$MAGISK_VER ($MAGISK_VER_CODE)"
fi

# 创建服务目录并清理旧版模块文件夹
mkdir -p "${service_dir}"
if [ -d "/data/adb/modules/ClashForRoot" ]; then
  rm -rf "/data/adb/modules/ClashForRoot"
  ui_print "旧模块已删除"
fi

# 解压 ZIP 包中的内容到 MODPATH 目录
ui_print "正在安装ClashForRoot"
unzip -o "$ZIPFILE" -x 'META-INF/*' -x 'webroot/*' -d "$MODPATH" >&2

# 确保目标目录存在
mkdir -p /data/adb/clash

# 清空目标目录
ui_print "正在清理现有数据"
rm -rf /data/adb/clash/*

# 将新内容复制到目标目录
ui_print "正在部署新文件"
cp -r "$MODPATH/clash/"* /data/adb/clash/ 2>/dev/null
cp -r "$MODPATH/clash/".[^.]* /data/adb/clash/ 2>/dev/null || true

# 创建必要的工作目录结构
ui_print "创建目录"
mkdir -p /data/adb/clash/ /data/adb/clash/run/ /data/adb/clash/bin/xclash/
mkdir -p $MODPATH/system/bin

# 提取关键脚本文件到指定目录
ui_print "正在提取"
ui_print "uninstall.sh→$MODPATH"
ui_print "clash_service.sh→${service_dir}"
ui_print "sbfr→$MODPATH/system/bin"
unzip -j -o "$ZIPFILE" 'uninstall.sh' -d "$MODPATH" >&2
unzip -j -o "$ZIPFILE" 'clash_service.sh' -d "${service_dir}" >&2
unzip -j -o "$ZIPFILE" 'sbfr' -d "$MODPATH/system/bin" >&2

# 设置所有相关文件和目录的权限
ui_print "设置权限"
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive /data/adb/clash/ 0 3005 0755 0644
set_perm_recursive /data/adb/clash/scripts/ 0 3005 0755 0700
set_perm ${service_dir}/clash_service.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
set_perm $MODPATH/system/bin/sbfr 0 0 0755

chmod ugo+x ${service_dir}/clash_service.sh $MODPATH/uninstall.sh /data/adb/clash/scripts/*

# 函数功能：自动启用 ghfast.top 镜像加速下载
# 参数：无
# 返回值：通过修改 /data/adb/clash/scripts/box.tool 中 use_ghproxy 的值来控制镜像开关
apply_mirror() {
  ui_print "自动启用ghfast加速"
  sed -i 's/use_ghproxy=.*/use_ghproxy="true"/' /data/adb/clash/scripts/box.tool
}

apply_mirror

# 函数功能：自动下载所有二进制文件
# 参数：无
# 返回值：自动执行所有下载操作
find_bin() {
  # 自动下载所有二进制程序
  ui_print "正在自动下载所有必需的二进制文件"
  
  ui_print "准备下载yq"
  /data/adb/clash/scripts/box.tool upyq
  
  ui_print "准备下载curl"
  /data/adb/clash/scripts/box.tool upcurl
  
  # 下载 clash相关文件
  ui_print "准备下载clash"
  /data/adb/clash/scripts/box.tool all clash
}

find_bin

# 更新模块描述信息，如果没有找到内核可执行文件则提示需手动下载
[ -z "$(find /data/adb/clash/bin -type f)" ] && sed -Ei 's/^description=(\[.*][[:space:]]*)?/description=[ 😱 模块已安装但需要手动下载内核 ] /g' $MODPATH/module.prop

# 根据不同的运行环境定制模块显示名称
if [ "$KSU" = "true" ]; then
  sed -i "s/name=.*/name=Clash For KernelSU/g" $MODPATH/module.prop
elif [ "$APATCH" = "true" ]; then
  sed -i "s/name=.*/name=Clash For APatch/g" $MODPATH/module.prop
else
  sed -i "s/name=.*/name=Clash For Magisk/g" $MODPATH/module.prop
fi
unzip -o "$ZIPFILE" 'webroot/*' -d "$MODPATH" >&2

# 清理临时文件
ui_print "正在清理残留文件"
rm -rf /data/adb/clash/bin/.bin $MODPATH/clash $MODPATH/sbfr $MODPATH/clash_service.sh

ui_print ""
# 创建快捷方式链接以便快速访问 sbfr 工具
ln -sf "$MODPATH/system/bin/sbfr" /dev/sbfr
ui_print "快捷方式'/dev/sbfr'已创建"
ui_print "您现在可以运行:su -c /dev/sbfr"
ui_print ""
# 完成安装流程并提示重启设备
ui_print "安装完成，请重启您的设备"