#!/system/bin/sh
# 校验 settings.ini 语法
if ! /system/bin/sh -n /data/adb/clash/settings.ini 2>"/data/adb/clash/run/settings_err.log"; then
  echo "settings.ini包含语法错误" | tee -a "/data/adb/clash/run/settings_err.log"
  exit 1
fi

# 基础配置
scripts_dir="${0%/*}"
source /data/adb/clash/settings.ini

user_agent="ClashForRoot"
url_ghproxy="https://ghfast.top"
use_ghproxy="true"
mihomo_stable="enable"

# 优先使用curl，无则用wget
rev1="busybox wget --no-check-certificate -qO-"
which curl >/dev/null && rev1="curl --progress-bar --insecure -sL"

# 文件下载函数
upfile() {
  file="$1"
  update_url="$2"
  
  # GitHub链接自动走加速
  [ "${use_ghproxy}" = true ] && [[ "${update_url}" == @(https://github.com/*|https://raw.githubusercontent.com/*|https://gist.github.com/*|https://gist.githubusercontent.com/*) ]] && update_url="${url_ghproxy}/${update_url}"
  
  # 构建下载命令
  if which curl >/dev/null; then
    request="curl --progress-bar -L --insecure --user-agent ${user_agent} --connect-timeout 30 --max-time 180 -o ${file} ${update_url}"
  else
    request="busybox wget --no-check-certificate --user-agent ${user_agent} -O ${file} ${update_url}"
  fi
  
  ${request} >&2 || { log info "下载失败: ${request}"; return 1; }
  return 0
}

# 重启核心服务
restart_box() {
  "${scripts_dir}/box.service" restart
  PIDS=(${bin_name})
  PID=""
  i=0
  # 查找进程PID
  while [ -z "$PID" ] && [ "$i" -lt "${#PIDS[@]}" ]; do
    PID=$(busybox pidof "${PIDS[$i]}")
    i=$((i+1))
  done
  # 验证重启结果
  [ -n "$PID" ] && log info "${bin_name} 重启完成 [$(date +"%F %R")]" || { log info "重启 ${bin_name} 失败"; ${scripts_dir}/box.iptables disable >/dev/null 2>&1; }
}

# 校验配置文件有效性
check() {
  log info "校验 <${bin_name}> 配置文件"
  case "${bin_name}" in
    clash)
      ${bin_path} -t -d "${box_dir}/clash" -f "${clash_config}" 2>/dev/null && log info "${clash_config} 校验通过" || { log info "配置校验失败"; return 1; }
      ;;
    *)
      log info "<${bin_name}> 未知核心类型"
      exit 1
      ;;
  esac
}

# 重载配置
reload() {
  curl_command="curl"
  # 无系统curl则下载
  if ! command -v curl >/dev/null; then
    [ ! -x "${bin_dir}/curl" ] && { log info "下载curl"; upcurl || { log info "安装curl失败"; return 1; }; }
    curl_command="${bin_dir}/curl"
  fi

  # 校验配置后重载
  check || { log info "配置校验失败，中止重载"; return 1; }
  
  case "${bin_name}" in
    clash)
      # mihomo和普通clash重载端点区分
      endpoint=$([ "${xclash_option}" = "mihomo" ] && echo "http://${ip_port}/configs?force=true" || echo "http://${ip_port}/configs")
      # API重载
      ${curl_command} -sS -X PUT -H "Authorization: Bearer ${secret}" "${endpoint}" -d '{"path": "", "payload": ""}' && log info "配置重载成功" || { log info "配置重载失败"; return 1; }
      ;;
    *)
      log info "${bin_name} 不支持API重载"
      return 1
      ;;
  esac
}

# 下载更新curl工具
upcurl() {
  # 检测架构
  case $(uname -m) in
    "aarch64") arch="aarch64" ;;
    "armv7l"|"armv8l") arch="armv7" ;;
    "i686") arch="i686" ;;
    "x86_64") arch="amd64" ;;
    *) log info "不支持架构: $(uname -m)"; return 1 ;;
  esac
  log info "架构: $(uname -m) -> ${arch}"

  # 获取最新版本
  latest_version=$($rev1 "https://api.github.com/repos/stunnel/static-curl/releases" | grep "tag_name" | busybox grep -oE "[0-9.]*" | head -1)
  [ -z "${latest_version}" ] && { log info "获取curl版本失败"; return 1; }
  log info "最新curl版本: ${latest_version}"

  # 下载并解压
  download_link="https://github.com/stunnel/static-curl/releases/download/${latest_version}/curl-linux-${arch}-glibc-${latest_version}.tar.xz"
  upfile "${bin_dir}/curl.tar.xz" "${download_link}" || { log info "下载curl失败"; return 1; }
  busybox tar -xJf "${bin_dir}/curl.tar.xz" -C "${bin_dir}" >/dev/null || { log info "解压curl失败"; return 1; }

  # 权限配置与清理
  chown "${box_user_group}" "${bin_dir}/curl"
  chmod 0700 "${bin_dir}/curl"
  rm -f "${bin_dir}/curl.tar.xz" "${bin_dir}/SHA256SUMS"
  log info "curl更新完成"
}

# 下载更新yq工具
upyq() {
  # 检测架构
  case $(uname -m) in
    "aarch64") arch="arm64"; platform="android" ;;
    "armv7l"|"armv8l") arch="arm"; platform="android" ;;
    "i686") arch="386"; platform="android" ;;
    "x86_64") arch="amd64"; platform="android" ;;
    *) log info "不支持架构: $(uname -m)"; return 1 ;;
  esac
  log info "架构: $(uname -m) -> 平台=${platform}, 架构=${arch}"

  # 下载并配置权限
  download_link="https://github.com/taamarin/yq/releases/download/prerelease/yq_${platform}_${arch}"
  upfile "${box_dir}/bin/yq" "${download_link}" || { log info "下载yq失败"; return 1; }
  chown "${box_user_group}" "${box_dir}/bin/yq"
  chmod 0700 "${box_dir}/bin/yq"
  log info "yq更新完成"
}

# 更新GeoIP/GeoSite/Country.mmdb数据库
upgeox() {
  [ "${update_geo}" != "true" ] && { log info "禁用GeoX更新，跳过"; return 1; }
  log info "${bin_name} 更新GeoX数据库 → $(date)"

  # 定义下载文件与链接
  geoip_file="${box_dir}/${bin_name}/geoip.dat"
  geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
  geosite_file="${box_dir}/${bin_name}/geosite.dat"
  geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
  country_mmdb_file="${box_dir}/${bin_name}/Country.mmdb"
  country_mmdb_url="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/GeoLite2-Country.mmdb"

  # 批量下载
  upfile "${geoip_file}" "${geoip_url}" || { log info "下载GeoIP失败"; return 1; }
  upfile "${geosite_file}" "${geosite_url}" || { log info "下载GeoSite失败"; return 1; }
  upfile "${country_mmdb_file}" "${country_mmdb_url}" || { log info "下载Country.mmdb失败"; return 1; }

  log info "GeoX数据库更新完成 → $(date)"
  return 0
}

# 更新订阅配置
upsubs() {
  yq="yq"
  # 无系统yq则下载
  if ! command -v yq &>/dev/null; then
    [ ! -e "${box_dir}/bin/yq" ] && { log info "下载yq"; ${scripts_dir}/box.tool upyq; }
    yq="${box_dir}/bin/yq"
  fi

  case "${bin_name}" in
    "clash")
      [ -z "${subscription_url_clash[*]}" ] && { log info "订阅链接为空"; return 0; }
      [ "${update_subscription}" != "true" ] && { log info "禁用订阅更新"; return 1; }
      log info "${bin_name} 更新订阅 → $(date)"

      # renew模式仅用第一个订阅，否则匹配链接与配置文件名数量
      if [ "${renew}" = "true" ]; then
        urls=("${subscription_url_clash[0]}")
        cfgs=("${name_provide_clash_config[0]}")
      else
        [ "${#subscription_url_clash[@]}" -ne "${#name_provide_clash_config[@]}" ] && { log info "订阅链接与配置文件名数量不匹配"; return 1; }
        urls=("${subscription_url_clash[@]}")
        cfgs=("${name_provide_clash_config[@]}")
      fi

      # 遍历下载订阅
      for i in "${!urls[@]}"; do
        sub_url="${urls[$i]}"
        clash_provide_config="${clash_provide_path}/${cfgs[$i]}"
        enhanced=$([ "${renew}" != "true" ] && echo true || echo false)
        update_file_name=$([ "${enhanced}" = true ] && echo "${clash_config}.subscription" || echo "${clash_config}")

        upfile "${update_file_name}" "${sub_url}" || { log info "下载订阅失败: ${sub_url}"; return 1; }
        log info "订阅保存成功: ${update_file_name}"

        # 增强模式处理
        if [ "${enhanced}" = true ]; then
          mkdir -p "$(dirname "${clash_provide_config}")"
          if ${yq} 'has("proxies")' "${update_file_name}" | grep -q "true"; then
            ${yq} -i '{"proxies": .proxies}' "${clash_provide_config}"
            # 自定义订阅规则
            if [ "${custom_rules_subs}" = "true" ] && ${yq} '.rules' "${update_file_name}" >/dev/null; then
              ${yq} -i '{"rules": .rules}' "${clash_provide_rules}"
              ${yq} -i 'del(.rules)' "${clash_config}"
              cat "${clash_provide_rules}" >> "${clash_config}"
            fi
            log info "订阅更新成功 → $(date +"%F %R")"
          elif ${yq} '.. | select(tag == "!!str")' "${update_file_name}" | grep -qE "vless://|vmess://|ss://|hysteria2://|hysteria://|trojan://|tuic://|wireguard://|socks5://|http://|snell://|mieru://|anytls://"; then
            mv "${update_file_name}" "${clash_provide_config}"
          elif grep -qE '^[A-Za-z0-9+/=[:space:]]+$' "$update_file_name" && busybox base64 -d "$update_file_name" >/dev/null 2>&1; then
            mv "${update_file_name}" "${clash_provide_config}"
          else
            log info "未知文件格式: ${update_file_name}"; return 1;
          fi
        else
          # renew模式直接重启
          [ -f "${box_pid}" ] && kill -0 "$(<"${box_pid}" 2>/dev/null)" && $scripts_dir/box.service restart 2>/dev/null
          log info "订阅更新完成 → $(date)"; exit 1;
        fi
      done
      log info "所有订阅更新完成 → $(date)"
      return 0
      ;;
    *)
      log info "<${bin_name}> 不支持订阅更新"; return 1;
      ;;
  esac
}

# 更新核心内核
upkernel() {
  # 检测架构
  case $(uname -m) in
    "aarch64") arch=$([ "${bin_name}" = "clash" ] && echo "arm64-v8" || echo "arm64"); platform="android" ;;
    "armv7l"|"armv8l") arch="armv7"; platform="linux" ;;
    "i686") arch="386"; platform="linux" ;;
    "x86_64") arch="amd64"; platform="linux" ;;
    *) log info "不支持架构: $(uname -m)"; exit 1 ;;
  esac
  file_kernel="${bin_name}-${arch}"

  case "${bin_name}" in
    "clash")
      [ "${xclash_option}" != "mihomo" ] && { log info "仅支持mihomo内核更新"; return 1; }
      download_link="https://github.com/MetaCubeX/mihomo/releases"

      # 获取版本
      if [ "${mihomo_stable}" = "enable" ]; then
        latest_version=$($rev1 "https://api.github.com/repos/MetaCubeX/mihomo/releases" | grep "tag_name" | busybox grep -oE "v[0-9.]*" | head -1)
        [ -z "${latest_version}" ] && { log info "获取稳定版版本失败"; return 1; }
        tag="${latest_version}"
      else
        [ "$use_ghproxy" = true ] && download_link="${url_ghproxy}/${download_link}"
        tag="Prerelease-Alpha"
        latest_version=$($rev1 "${download_link}/expanded_assets/${tag}" | busybox grep -oE "alpha-[0-9a-z]+" | head -1)
        [ -z "${latest_version}" ] && { log info "获取开发版版本失败"; return 1; }
      fi
      log info "最新版本: ${latest_version}"

      # 下载并安装
      filename="mihomo-${platform}-${arch}-${latest_version}"
      full_url="${download_link}/download/${tag}/${filename}.gz"
      upfile "${box_dir}/${file_kernel}.gz" "${full_url}" || { log info "下载内核失败"; return 1; }
      xkernel  # 调用安装函数
      ;;
    *)
      log info "<${bin_name}> 不支持内核更新"; exit 1;
      ;;
  esac
}

# 安装内核
xkernel() {
  case "${bin_name}" in
    "clash")
      gunzip_command=$([ command -v gunzip >/dev/null ] && echo "gunzip" || echo "busybox gunzip")
      mkdir -p "${bin_dir}/xclash"
      ${gunzip_command} "${box_dir}/${file_kernel}.gz" >/dev/null || { log info "解压内核失败"; return 1; }
      mv "${box_dir}/${file_kernel}" "${bin_dir}/xclash/${xclash_option}" || { log info "移动内核失败"; return 1; }
      ln -sf "${bin_dir}/xclash/${xclash_option}" "${bin_dir}/${bin_name}"

      # 重启服务
      [ -f "${box_pid}" ] && { log info "重启 ${bin_name}"; restart_box; }
      ;;
    *)
      log info "<${bin_name}> 不支持内核安装"; exit 1;
      ;;
  esac

  # 清理与权限配置
  find "${box_dir}" -maxdepth 1 -type f -name "${file_kernel}.*" -delete >/dev/null
  chown ${box_user_group} ${bin_path}
  chmod 6755 ${bin_path}
  log info "内核更新完成"
}

# 更新控制面板
upxui() {
  [ "${bin_name}" != "clash" ] && { log info "${bin_name} 不支持控制面板"; return 1; }
  xdashboard="${bin_name}/dashboard"
  file_dashboard="${box_dir}/${xdashboard}.zip"
  url="https://github.com/Zephyruso/zashboard/archive/gh-pages.zip"
  [ "$use_ghproxy" = true ] && url="${url_ghproxy}/${url}"
  dir_name="zashboard-gh-pages"

  # 下载
  rev2=$([ which curl >/dev/null ] && echo "curl -L --progress-bar --insecure ${url} -o" || echo "busybox wget --no-check-certificate ${url} -O")
  $rev2 "${file_dashboard}" >/dev/null || { log info "下载控制面板失败"; return 1; }

  # 解压与部署
  mkdir -p "${box_dir}/${xdashboard}" && rm -rf "${box_dir}/${xdashboard}/"*
  unzip_command=$([ command -v unzip >/dev/null ] && echo "unzip" || echo "busybox unzip")
  "${unzip_command}" -o "${file_dashboard}" "${dir_name}/*" -d "${box_dir}/${xdashboard}" >/dev/null
  mv -f "${box_dir}/${xdashboard}/${dir_name}"/* "${box_dir}/${xdashboard}/"

  # 清理
  rm -f "${file_dashboard}" && rm -rf "${box_dir}/${xdashboard}/${dir_name}"
  log info "控制面板更新完成"
}

# 设置blkio控制组
cgroup_blkio() {
  local pid_file="$1"
  local fallback_weight="${2:-900}"
  [ -z "$pid_file" ] || [ ! -f "$pid_file" ] && { log info "PID文件无效: $pid_file"; return 1; }
  local PID=$(<"$pid_file" 2>/dev/null)
  [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null && { log info "PID无效: $PID"; return 1; }

  # 查找blkio路径并配置
  [ -z "$blkio_path" ] && blkio_path=$(mount | busybox awk '/blkio/ {print $3}' | head -1)
  [ -z "$blkio_path" ] || [ ! -d "$blkio_path" ] && { log info "未找到blkio路径"; return 1; }
  local target=$([ -d "${blkio_path}/foreground" ] && echo "${blkio_path}/foreground" || echo "${blkio_path}/box")
  mkdir -p "$target" && echo "$fallback_weight" > "${target}/blkio.weight"
  echo "$PID" > "${target}/cgroup.procs" && log info "PID $PID 加入blkio控制组，权重: $fallback_weight"
  return 0
}

# 设置memcg控制组
cgroup_memcg() {
  local pid_file="$1"
  local raw_limit="$2"
  [ -z "$pid_file" ] || [ ! -f "$pid_file" ] && { log info "PID文件无效: $pid_file"; return 1; }
  [ -z "$raw_limit" ] && { log info "未指定内存限制"; return 1; }

  # 转换内存限制为字节
  local limit
  case "$raw_limit" in
    *[Mm]) limit=$(( ${raw_limit%[Mm]} * 1024 * 1024 )) ;;
    *[Gg]) limit=$(( ${raw_limit%[Gg]} * 1024 * 1024 * 1024 )) ;;
    *[Kk]) limit=$(( ${raw_limit%[Kk]} * 1024 )) ;;
    *[0-9]) limit=$raw_limit ;;
    *) log info "无效内存格式: $raw_limit"; return 1 ;;
  esac

  local PID=$(<"$pid_file" 2>/dev/null)
  [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null && { log info "PID无效: $PID"; return 1; }

  # 查找memcg路径并配置
  [ -z "$memcg_path" ] && memcg_path=$(mount | grep cgroup | busybox awk '/memory/{print $3}' | head -1)
  [ -z "$memcg_path" ] || [ ! -d "$memcg_path" ] && { log info "未找到memcg路径"; return 1; }
  local name="${bin_name:-app}"
  local target="${memcg_path}/${name}"
  mkdir -p "$target" && echo "$limit" > "${target}/memory.limit_in_bytes"
  echo "$PID" > "${target}/cgroup.procs" && log info "PID $PID 加入memcg控制组，内存限制: ${limit}字节"
  return 0
}

# 设置cpuset控制组
cgroup_cpuset() {
  local pid_file="${1}"
  local cores="${2}"
  [ -z "${pid_file}" ] || [ ! -f "${pid_file}" ] && { log info "PID文件无效: ${pid_file}"; return 1; }
  local PID=$(<"${pid_file}" 2>/dev/null)
  [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null && { log info "PID无效: $PID"; return 1; }

  # 自动检测CPU核心
  [ -z "${cores}" ] && {
    local total_core=$(nproc --all 2>/dev/null)
    [ -z "$total_core" ] || [ "$total_core" -le 0 ] && { log info "检测CPU核心失败"; return 1; }
    cores="0-$((total_core - 1))"
  }

  # 查找cpuset路径并配置
  [ -z "${cpuset_path}" ] && cpuset_path=$(mount | grep cgroup | busybox awk '/cpuset/{print $3}' | head -1)
  [ -z "${cpuset_path}" ] || [ ! -d "${cpuset_path}" ] && { log info "未找到cpuset路径"; return 1; }
  local cpuset_target=$([ -d "${cpuset_path}/foreground" ] && echo "${cpuset_path}/foreground" || [ -d "${cpuset_path}/top-app" ] && echo "${cpuset_path}/top-app" || echo "${cpuset_path}/apps")
  [ ! -d "${cpuset_target}" ] && { log info "未找到cpuset控制组"; return 1; }
  echo "${cores}" > "${cpuset_target}/cpus" && echo "0" > "${cpuset_target}/mems"
  echo "${PID}" > "${cpuset_target}/cgroup.procs" && log info "PID $PID 加入cpuset控制组，CPU核心: [$cores]"
  return 0
}

# 获取clash外部控制端口
ip_port=$([ "${bin_name}" = "clash" ] && busybox awk '/external-controller:/ {print $2}' "${clash_config}" || echo "")
secret=""  # 认证密钥（留空禁用）

# 生成webroot索引页
webroot() {
  path_webroot="/data/adb/modules/ClashForRoot/webroot/index.html"
  touch -n "$path_webroot"
  if [ "${bin_name}" = "clash" ]; then
    # 跳转至控制面板
    echo -e '<!DOCTYPE html><script>document.location = "http://'"$ip_port"'/ui/"</script></html>' > "$path_webroot"
  else
    # 不支持提示
    echo -e '<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>不支持的控制面板</title><style>body{font-family:Arial,sans-serif;text-align:center;padding:50px;}h1{color:red;}</style></head><body><h1>不支持的控制面板</h1></body></html>' > "$path_webroot"
  fi
}

# 网络优化-平衡模式（WiFi优先，省电+稳定）
bond0() {
  # 核心TCP参数：平衡延迟与吞吐量，开启丢包恢复
  sysctl -w net.ipv4.tcp_low_latency=0 >/dev/null 2>&1 && log info "TCP低延迟: 禁用（平衡模式）"
  sysctl -w net.ipv4.tcp_sack=1 >/dev/null 2>&1
  sysctl -w net.ipv4.tcp_timestamps=1 >/dev/null 2>&1

  # WiFi网卡：队列适中，平衡功耗与吞吐量
  for dev in /sys/class/net/wlan*; do 
    ${busybox} ip link set dev $(basename $dev) txqueuelen 2500 >/dev/null 2>&1
  done && log info "wlan*发送队列: 2500"

  # 移动数据网卡：队列保守，统一MTU兼容TUN
  for dev in /sys/class/net/rmnet_data*; do 
    ${busybox} ip link set dev $(basename $dev) txqueuelen 1200 >/dev/null 2>&1
    ${busybox} ip link set dev $(basename $dev) mtu 1500 >/dev/null 2>&1
  done && log info "rmnet_data* - 发送队列:1200 | MTU:1500"
}

# 网络优化-高性能模式（移动数据/游戏优先，低延迟+高吞吐）
bond1() {
  # 核心TCP参数：低延迟优先，开启高速网络优化
  sysctl -w net.ipv4.tcp_low_latency=1 >/dev/null 2>&1 && log info "TCP低延迟: 启用（高性能模式）"
  sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1
  sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1
  sysctl -w net.ipv4.tcp_sack=1 >/dev/null 2>&1

  # WiFi网卡：队列提升，标准MTU兼容路由器
  for dev in /sys/class/net/wlan*; do 
    ${busybox} ip link set dev $(basename $dev) txqueuelen 3500 >/dev/null 2>&1
    ${busybox} ip link set dev $(basename $dev) mtu 1500 >/dev/null 2>&1
  done && log info "wlan*发送队列: 3500 | MTU:1500"

  # 移动数据网卡：队列适配突发带宽，统一MTU
  for dev in /sys/class/net/rmnet_data*; do 
    ${busybox} ip link set dev $(basename $dev) txqueuelen 2500 >/dev/null 2>&1
    ${busybox} ip link set dev $(basename $dev) mtu 1500 >/dev/null 2>&1
  done && log info "rmnet_data* - 发送队列:2500 | MTU:1500"

  # 旗舰机可选增强（高端设备启用）
  sysctl -w net.ipv4.tcp_no_metrics_save=1 >/dev/null 2>&1
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
}
# 命令行参数处理
case "$1" in
  check)
    check  # 校验配置
    ;;
  memcg|cpuset|blkio)
    # 控制组配置
    case "$1" in
      memcg) memcg_path=""; cgroup_memcg "${box_pid}" ${memcg_limit} ;;
      cpuset) cpuset_path=""; cgroup_cpuset "${box_pid}" ${allow_cpu} ;;
      blkio) blkio_path=""; cgroup_blkio "${box_pid}" "${weight}" ;;
    esac
    ;;
  bond0|bond1)
    $1  # 网络优化
    ;;
  geosub)
    upgeox && upsubs && [ -f "${box_pid}" ] && kill -0 "$(<"${box_pid}" 2>/dev/null)" && reload  # 更新Geo+订阅+重载
    ;;
  geox|subs)
    $1 && [ -f "${box_pid}" ] && kill -0 "$(<"${box_pid}" 2>/dev/null)" && reload  # 单独更新Geo/订阅+重载
    ;;
  upkernel|upxui|upyq|upcurl|reload|webroot)
    $1  # 单个更新/操作
    ;;
  all)
    # 全量更新
    update_geo="true"
    for bin_name in "$2"; do
      upkernel && upgeox && upsubs && upxui
    done
    ;;
  help|-h|--help|"")
    # 帮助信息
    echo "用法: $0 <命令>"
    echo "命令列表:"
    echo "  check       - 校验配置文件"
    echo "  memcg/cpuset/blkio - 配置cgroup限制"
    echo "  bond0|bond1 - 网络优化"
    echo "  geosub      - 更新订阅+Geo数据库+重载"
    echo "  geox/subs   - 单独更新Geo/订阅+重载"
    echo "  upkernel    - 更新内核"
    echo "  upxui       - 更新控制面板"
    echo "  upyq/upcurl - 更新配置工具"
    echo "  reload      - 重载配置"
    echo "  webroot     - 生成控制面板跳转页"
    echo "  all         - 全量更新"
    echo "示例: $0 check"
    ;;
  *)
    echo "$0 $1 命令未找到"
    echo "执行 '$0 help' 查看用法"
    ;;
esac