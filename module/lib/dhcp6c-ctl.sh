#!/system/bin/sh
# lib/dhcp6c-ctl.sh —— dhcp6c 生命周期控制与状态查询
#
# 用法：
#   dhcp6c-ctl.sh {status|start|stop|pause|resume|restart|ensure|desc}
#
# 本脚本设计为**只执行、不 source**：
# shell 里被 source 的脚本拿不到自己的路径（$0 是宿主脚本名），
# 定位 common.sh 会依赖调用者的目录结构，很容易出错。
# watchdog 只在需要改动状态时才调它，频率很低，多一次 fork 无所谓；
# 它循环里要用的探测函数直接自己 source common.sh。
#
# 职责划分：
#   common.sh  只读探测（谁都能用）
#   ctl.sh     有副作用的状态变更（唯一入口，且全程持锁）

_self=$(readlink -f "$0" 2>/dev/null)
[ -n "$_self" ] || _self=$0
. "${_self%/*}/common.sh"

D6_LOCK=$DHCP6C_STATE/.lock

d6_ensure_dirs() {
	mkdir -p "$DHCP6C_STATE" "$DHCP6C_LOGDIR"
}

# ── 互斥锁 ───────────────────────────────────────────────────────
#
# 为什么必须要有：启动/停止会被多个执行方同时触发 ——
# WebUI 的 exec、action.sh、watchdog 的自动重启，彼此独立。
# 而 d6_start 在启动前会 rm 掉 pidfile（因为 dhcp6c 会 flock 它，
# 里面残留的旧 PID 会让它误判「已有实例在跑」而直接退出），
# 这个 rm 会把 flock 赖以生效的 inode 换掉，于是两个并发的 d6_start
# 可以各自创建新 inode、各拿一把锁，**同时启动两个 dhcp6c**。
# 真机日志里出现过两行「dhcp6c 已启动」，就是这个竞态。
#
# 用 mkdir 做锁：它是原子的，且是所有 shell 都能用的最小手段。
d6_lock() {
	_i=0
	while ! mkdir "$D6_LOCK" 2>/dev/null; do
		_i=$((_i + 1))
		if [ "$_i" -gt 100 ]; then
			# 10 秒还拿不到：持有者可能异常退出留下了空目录。
			# 这里选择强行接管 —— 宁可放弃一次严格互斥，也不要永久卡死。
			d6_log "锁超时（$D6_LOCK），强行接管"
			rmdir "$D6_LOCK" 2>/dev/null
			mkdir "$D6_LOCK" 2>/dev/null
			return 0
		fi
		sleep 0.1
	done
	return 0
}

d6_unlock() {
	rmdir "$D6_LOCK" 2>/dev/null
	return 0
}

# ── dhcp6c ───────────────────────────────────────────────────────

# 启动 dhcp6c。
#
# 几个必须的写法，少一个都会出问题：
#
#   -f          前台运行。不加的话它会自己 daemon(0,0)，从 shell 看就是
#               「命令立刻返回」，像是没启动起来，而且日志会被丢给 syslog
#               （Android 上 bionic 的 syslog 走 logd，文件日志就没了）。
#   -p <pid>    必须显式指定。编译期 DHCP6C_PIDFILE 是 /var/run/dhcp6c.pid，
#               Android 上没有 /var/run，而该文件即使加了 -f 也会被无条件
#               打开，打不开就直接退出。
#   -c <conf>   配置文件。
#   -n          退出时不发送 RELEASE。理由见 d6_stop，这里把它做成启动期策略：
#               这样即使有人用 killall / SIGTERM 收掉进程，也仍然不释放地址，
#               不会因为换了种停止方式就丢掉这条保证。
#   -d          日志级别提到 LOG_INFO。不加的话阈值是 LOG_WARNING，
#               Solicit / Reply / 地址增删这些关键过程一条都不会记，
#               日志文件永远是空的（踩过）。用 -d 而不是 -D：-D 是 LOG_DEBUG，
#               噪声大得多，对诊断没有额外帮助。
#
# setsid 让 dhcp6c 脱离调用者的会话。它要长期活着，而调用者
# （service.sh、WebUI 的一次 exec、本 ctl）随时会退出。
#
# stdin 接 /dev/null 是安全的：主循环只 select() 在 DHCPv6 socket 上，
# 从不读 fd 0。早先「stdin EOF 会静默退出」的说法经读源码 + 真机实测
# （</dev/null 跑满 25 秒进程健在）都不成立，已经作废。
d6_start() {
	d6_lock
	d6__start
	_rc=$?
	d6_unlock
	return $_rc
}

d6__start() {
	if d6_is_running; then
		return 0
	fi
	if [ ! -x "$DHCP6C_BIN" ]; then
		d6_log "启动失败：$DHCP6C_BIN 不存在或不可执行"
		return 1
	fi
	if [ ! -r "$DHCP6C_CONF" ]; then
		d6_log "启动失败：找不到配置 $DHCP6C_CONF"
		return 1
	fi

	d6_ensure_dirs
	rm -f "$DHCP6C_PIDFILE"

	setsid "$DHCP6C_BIN" -f -n -d -p "$DHCP6C_PIDFILE" -c "$DHCP6C_CONF" \
		</dev/null >>"$DHCP6C_LOG" 2>&1 &

	_i=0
	while [ "$_i" -lt 50 ]; do
		d6_is_running && { d6_log "dhcp6c 已启动 pid=$(d6_pid)"; return 0; }
		sleep 0.1
		_i=$((_i + 1))
	done

	d6_log "启动 dhcp6c 超时（5 秒内未写出可用 pidfile）"
	return 1
}

# 停止 dhcp6c。
#
# 用 SIGUSR1 而不是 SIGTERM：
#
#   SIGTERM -> free_resources() -> release_all_ia()，会走「归还地址」的分支
#   SIGUSR1 -> opt_norelease=1，直接退出，不发 RELEASE
#
# 本项目靠「DUID + IAID 稳定」保证每次拿到同一个地址。发了 RELEASE 就等于
# 告诉服务端「这个地址我还回去了」，它可能被回收再分给别人，下次未必还给你；
# 保留租约让它自然超时，重新 Solicitation 时更可能拿回原地址。
# 顺带省掉一次网络往返。DHCPv6 的租约本来就是软的，不发 RELEASE 完全合规。
#
# 这里其实有两道保险：启动时已经带了 -n（见 d6_start），所以即便被
# SIGTERM 或 killall 收掉也不会发 RELEASE；SIGUSR1 是第二道，
# 保证任何情况下这条路径都成立。
d6_stop() {
	d6_lock
	d6__stop
	_rc=$?
	d6_unlock
	return $_rc
}

d6__stop() {
	_p=$(d6_pid)
	if [ -n "$_p" ] && [ -d "/proc/$_p" ]; then
		kill -USR1 "$_p" 2>/dev/null
		_i=0
		while [ "$_i" -lt 30 ] && [ -d "/proc/$_p" ]; do
			sleep 0.1
			_i=$((_i + 1))
		done
		if [ -d "/proc/$_p" ]; then
			kill -KILL "$_p" 2>/dev/null
		fi
	fi
	rm -f "$DHCP6C_PIDFILE"
	return 0
}

# ── watchdog ─────────────────────────────────────────────────────

d6_watchdog_running() {
	_p=$(cat "$DHCP6C_WD_PID" 2>/dev/null)
	case "$_p" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ -d "/proc/$_p" ] || return 1
	# PID 会被系统回收，所以要确认这个 PID 现在确实还是那个 watchdog，
	# 而不只是「某个碰巧活着的 shell」。
	grep -qa 'dhcp6c-watchdog' "/proc/$_p/cmdline" 2>/dev/null || return 1
	return 0
}

d6_watchdog_start() {
	d6_lock
	d6__watchdog_start
	_rc=$?
	d6_unlock
	return $_rc
}

d6__watchdog_start() {
	d6_ensure_dirs
	d6_watchdog_running && return 0
	rm -f "$DHCP6C_WD_PID"
	setsid "$DHCP6C_MODDIR/scripts/dhcp6c-watchdog.sh" \
		</dev/null >>"$DHCP6C_WD_LOG" 2>&1 &
	_i=0
	while [ "$_i" -lt 50 ]; do
		d6_watchdog_running && return 0
		sleep 0.1
		_i=$((_i + 1))
	done
	d6_log "watchdog 启动超时"
	return 1
}

d6_watchdog_stop() {
	d6_lock
	d6__watchdog_stop
	_rc=$?
	d6_unlock
	return $_rc
}

d6__watchdog_stop() {
	_p=$(cat "$DHCP6C_WD_PID" 2>/dev/null)
	case "$_p" in
		''|*[!0-9]*) : ;;
		*)
			kill -TERM "$_p" 2>/dev/null
			_i=0
			while [ "$_i" -lt 30 ] && [ -d "/proc/$_p" ]; do
				sleep 0.1
				_i=$((_i + 1))
			done
			[ -d "/proc/$_p" ] && kill -KILL "$_p" 2>/dev/null
			;;
	esac
	rm -f "$DHCP6C_WD_PID"
	return 0
}

# ── 对外命令 ─────────────────────────────────────────────────────

# 整套拉起：清暂停标志 -> 确保 watchdog 在跑 -> 立刻启动 dhcp6c。
# watchdog 那边会先睡一个巡检周期才动手（见脚本里的说明），
# 所以这里的 d6_start 是「快路径」，两者不会互相打断。
d6_cmd_start() {
	rm -f "$DHCP6C_PAUSED"
	d6_watchdog_start
	d6_start
}

# 暂停 dhcp6c 但保留 watchdog：它进入待命，不会把进程再拉起来。
# 这样「用户手动停止」和「进程意外挂掉」两种情况就能区分开 ——
# 后者需要自动恢复，前者不该被自动恢复。
d6_cmd_pause() {
	touch "$DHCP6C_PAUSED"
	d6_stop
}

d6_cmd_stop() {
	d6_cmd_pause
	d6_watchdog_stop
}

# 只停客户端：**不设「用户暂停」标志，也不动 watchdog**。
#
# 专门给 watchdog 内部用。它遇到的都是**暂时性**状况 —— 接口还没出现、
# 模块被停用 —— 这些都必须能自动恢复，所以绝不能借用 cmd_stop：
# cmd_stop 会 touch 暂停标志（于是 watchdog 下一拍进入待命、永不再拉起客户端）
# 并且杀掉 watchdog 自己（于是连"待命"都没有了，直接消失）。
#
# 这就是「重启后客户端偶尔不自启、点一下『重启客户端』才好」的根因：
# 开机时 Wi-Fi 往往还没起来，watchdog 第一拍就撞上「接口不存在」，
# 一句 stop 把自己永久关掉了。
d6_cmd_hold() {
	d6_stop
}

d6_cmd_restart() {
	d6_stop
	rm -f "$DHCP6C_PAUSED"
	d6_watchdog_start
	d6_start
}

# 供 WebUI / action.sh 读取的状态块。
# 刻意用最简单的 key=value：在 shell 里手拼 JSON 太容易出转义问题，
# 让上层自己解析反而更稳。
d6_cmd_status() {
	_if=$(cat "$DHCP6C_STATE/ifname" 2>/dev/null)
	[ -n "$_if" ] || _if=$(d6_resolve_ifname)

	if d6_is_running; then
		echo "RUNNING=1"
		echo "PID=$(d6_pid)"
	else
		echo "RUNNING=0"
		echo "PID="
	fi

	if d6_watchdog_running; then echo "WATCHDOG=1"; else echo "WATCHDOG=0"; fi

	echo "IFNAME=$_if"
	if d6_iface_up "$_if"; then echo "IFACE_UP=1"; else echo "IFACE_UP=0"; fi
	echo "GLOBAL6=$(d6_count_global_v6 "$_if")"

	if d6_is_paused; then echo "PAUSED=1"; else echo "PAUSED=0"; fi
	if d6_is_module_off; then echo "MODULE_OFF=1"; else echo "MODULE_OFF=0"; fi

	echo "IA_ADDR=$(cat "$DHCP6C_IA_PRETTY" 2>/dev/null)"
	echo "IA_ADDR_HEX=$(d6_ia_addr 2>/dev/null)"
	echo "DNS=$(cat "$DHCP6C_DNS_FILE" 2>/dev/null)"
	echo "BIN=$DHCP6C_BIN"
	echo "CONF=$DHCP6C_CONF"
	echo "PREFIX=$DHCP6C_PREFIX"
}

# 刷新模块卡片上的简介（module.prop 的 description）。
#
# 单独立一个命令，而不是塞进 status 里顺手做：status 是只读查询，WebUI 每
# 10 秒调一次，在只读路径上写文件是不该有的副作用。何况 WebUI 刷新得再勤
# 也改不了「管理器要重新读 module.prop 才看得见」这件事，频率没意义。
d6_cmd_desc() {
	_if=$(cat "$DHCP6C_STATE/ifname" 2>/dev/null)
	[ -n "$_if" ] || _if=$(d6_resolve_ifname)
	d6_desc_update "$(d6_status_short "$_if")"
}

d6_main() {
	case "$1" in
		start)   d6_cmd_start ;;
		stop)    d6_cmd_stop ;;
		hold)    d6_cmd_hold ;;
		pause)   d6_cmd_pause ;;
		resume)  d6_cmd_start ;;
		restart) d6_cmd_restart ;;
		ensure)  d6_watchdog_start ;;
		status)  d6_cmd_status ;;
		desc)    d6_cmd_desc ;;
		*)
			echo "用法: ${0##*/} {status|start|stop|hold|pause|resume|restart|ensure|desc}" >&2
			return 2
			;;
	esac
}

d6_main "$@"
