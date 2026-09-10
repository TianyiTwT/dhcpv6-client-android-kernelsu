#!/system/bin/sh
# lib/common.sh —— 路径常量与探测工具
#
# 本文件被其它脚本以 `. ` 的方式加载，因此必须遵守：
#   * 不调用 exit（会把宿主脚本一起带走）
#   * 不依赖 set -e
#   * 只定义变量和函数，不产生副作用

# ---------------------------------------------------------------- 路径
#
# 运行期文件（配置、DUID、日志、状态）统一放在 /data/adb/dhcp6c。
# 这个路径不是随便定的：它是 dhcp6c 的编译期 --prefix，决定了
# SYSCONFDIR 与 LOCALDBDIR，也就是默认配置文件位置和 DUID 的落盘位置。
# 换成别的路径会让「DUID 持久化」这条地址稳定机制失效。
DHCP6C_PREFIX=${DHCP6C_PREFIX:-/data/adb/dhcp6c}

DHCP6C_CONF=$DHCP6C_PREFIX/dhcp6c.conf
DHCP6C_PIDFILE=$DHCP6C_PREFIX/dhcp6c.pid
DHCP6C_DUID=$DHCP6C_PREFIX/dhcp6c_duid
DHCP6C_SCRIPT=$DHCP6C_PREFIX/dhcp6c-script

DHCP6C_STATE=$DHCP6C_PREFIX/state
DHCP6C_LOGDIR=$DHCP6C_PREFIX/log

DHCP6C_IA_FILE=$DHCP6C_STATE/ia_na.addr   # 上一次拿到的 IA_NA 地址（32 位十六进制）
DHCP6C_IA_PRETTY=$DHCP6C_STATE/ia_na.text # 同一地址的冒号写法，供 WebUI 直接显示
DHCP6C_PAUSED=$DHCP6C_STATE/paused        # 存在即表示用户手动暂停
DHCP6C_DNS_FILE=$DHCP6C_STATE/dns.servers # 服务端下发的 DNS（本期只记录，不启用）
DHCP6C_WD_PID=$DHCP6C_STATE/watchdog.pid

DHCP6C_LOG=$DHCP6C_LOGDIR/dhcp6c.log        # dhcp6c 自身的 stdout/stderr
DHCP6C_WD_LOG=$DHCP6C_LOGDIR/watchdog.log   # watchdog 与 ctl 的运行日志
DHCP6C_SCRIPT_LOG=$DHCP6C_LOGDIR/script.log # dhcp6c 回调每次事件记一行

# ---------------------------------------------------------------- 模块目录
#
# KernelSU 在 service.sh / post-fs-data.sh 里注入 MODDIR。
# 其它入口（手动执行、WebUI 调用 action.sh）没有这个变量，
# 就从 $0 反推：脚本要么在 lib/ 要么在 scripts/，其上一级就是模块根。
d6_moddir() {
	if [ -n "$MODDIR" ]; then
		printf '%s\n' "$MODDIR"
		return 0
	fi
	_m=$(readlink -f "$0" 2>/dev/null)
	[ -n "$_m" ] || _m=$0
	case "$_m" in
		*/lib/*|*/scripts/*) printf '%s\n' "${_m%/*/*}" ;;
		*)                   printf '%s\n' "${_m%/*}" ;;
	esac
}

DHCP6C_MODDIR=$(d6_moddir)
DHCP6C_BIN=$DHCP6C_MODDIR/bin/dhcp6c

# ---------------------------------------------------------------- 日志
d6_log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >>"$DHCP6C_WD_LOG"
}

# ---------------------------------------------------------------- 接口探测

# 目标接口名。优先级：
#   1. state/ifname（由 WebUI 或用户显式指定）
#   2. dhcp6c.conf 里的 interface 语句
#   3. 自动探测：无线接口，优先 operstate=up 的
#   4. 兜底 wlan0
# 只在启动时调用一次；无线接口名在会话期间不会变。
d6_resolve_ifname() {
	if [ -r "$DHCP6C_STATE/ifname" ]; then
		_n=$(cat "$DHCP6C_STATE/ifname" 2>/dev/null)
		[ -n "$_n" ] && { printf '%s\n' "$_n"; return 0; }
	fi

	if [ -r "$DHCP6C_CONF" ]; then
		_n=$(sed -n 's/^[[:space:]]*interface[[:space:]]\{1,\}\([^[:space:]{]*\).*/\1/p' \
			"$DHCP6C_CONF" 2>/dev/null | head -n 1)
		# 配置里写的接口若在当前设备上不存在，就不要信它 ——
		# 同一个配置可能被复制到别的机型上，那边接口名未必相同。
		if [ -n "$_n" ] && [ -e "/sys/class/net/$_n" ]; then
			printf '%s\n' "$_n"
			return 0
		fi
	fi

	_any=
	for _d in /sys/class/net/*/wireless; do
		[ -e "$_d" ] || continue
		_i=${_d%/wireless}
		_i=${_i##*/}
		# p2p0 / wifi-aware0 也是无线接口，但不是上网站，排除
		case "$_i" in p2p0|wifi-aware0) continue ;; esac
		[ -n "$_any" ] || _any=$_i
		if [ "$(cat "/sys/class/net/$_i/operstate" 2>/dev/null)" = up ]; then
			printf '%s\n' "$_i"
			return 0
		fi
	done
	[ -n "$_any" ] && { printf '%s\n' "$_any"; return 0; }

	printf '%s\n' wlan0
}

d6_iface_exists() {
	[ -n "$1" ] && [ -e "/sys/class/net/$1" ]
}

d6_iface_up() {
	[ "$(cat "/sys/class/net/$1/operstate" 2>/dev/null)" = up ]
}

# d6_iface_has_addr <ifname> <32位小写十六进制>
# /proc/net/if_inet6 的每行是固定宽度字段：
#   <32位十六进制地址> <ifindex> <前缀长> <scope> <flags> <接口名>
# 接口名前有补位空格，靠 read 的默认 IFS 吃掉。
d6_iface_has_addr() {
	[ -r /proc/net/if_inet6 ] || return 1
	while read -r _a _i _p _s _f _dev; do
		[ "$_dev" = "$1" ] && [ "$_a" = "$2" ] && return 0
	done < /proc/net/if_inet6
	return 1
}

# 接口上全局 IPv6 地址（scope=00）的条数。仅用于诊断展示。
d6_count_global_v6() {
	_n=0
	[ -r /proc/net/if_inet6 ] || { printf '0\n'; return 0; }
	while read -r _a _i _p _s _f _dev; do
		[ "$_dev" = "$1" ] || continue
		[ "$_s" = "00" ] && _n=$((_n + 1))
	done < /proc/net/if_inet6
	printf '%s\n' "$_n"
}

# ---------------------------------------------------------------- 进程状态

d6_pid() {
	[ -r "$DHCP6C_PIDFILE" ] || return 1
	_p=$(cat "$DHCP6C_PIDFILE" 2>/dev/null)
	case "$_p" in
		''|*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "$_p"
}

# 判断 dhcp6c 是否真的活着。
#
# 不能只信 pidfile：dhcp6c 退出后不会清理它，而 PID 会被系统回收。
# 万一回收给了别的进程，只看「/proc/<pid> 存在」会得到假阳性，
# 于是 watchdog 永远不去拉新的客户端。所以再核对一次进程名，
# 并排除僵尸态。
d6_is_running() {
	_p=$(d6_pid) || return 1
	[ -d "/proc/$_p" ] || return 1
	grep -q '^State:[[:space:]]*Z' "/proc/$_p/status" 2>/dev/null && return 1
	[ "$(cat "/proc/$_p/comm" 2>/dev/null)" = dhcp6c ] || return 1
	return 0
}

d6_is_paused() {
	[ -e "$DHCP6C_PAUSED" ]
}

# 模块是否已被停用/待卸载。KernelSU 就是靠这两个文件表达状态的。
d6_is_module_off() {
	[ -e "$DHCP6C_MODDIR/disable" ] || [ -e "$DHCP6C_MODDIR/remove" ]
}

# 上一次拿到的 IA_NA 地址（32 位十六进制）。没有则返回非零。
d6_ia_addr() {
	[ -r "$DHCP6C_IA_FILE" ] || return 1
	_a=$(cat "$DHCP6C_IA_FILE" 2>/dev/null)
	[ -n "$_a" ] || return 1
	printf '%s\n' "$_a"
}
