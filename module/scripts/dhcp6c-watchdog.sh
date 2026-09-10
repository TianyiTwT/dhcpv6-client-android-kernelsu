#!/system/bin/sh
#
# dhcp6c-watchdog.sh —— dhcp6c 的监督进程（常驻）
#
# ── 为什么必须有它 ───────────────────────────────────────────────
#
# Android 自己的 DHCP（v4、以及 11+ 的 DHCPv6-PD）不需要看门狗，因为
# IpClient / ConnectivityService 就是它的监督者和生命周期所有者：
#   * 网络需要地址时启动它，网络消失时停掉它；
#   * 重连、漫游时由框架重建它；
#   * 它拿到的租约被写进 LinkProperties，由框架负责保管，
#     别的组件不会把这份地址当成「未知来源」清掉。
#
# 而 dhcp6c 是模块从外面拉起来的、Android 网络栈完全不知道的进程，
# 上面四件事一件都没有。更麻烦的是 wide-dhcpv6 本身也不监听链路事件 ——
# 源码里没有任何 PF_ROUTE / RTM_ 处理，只在启动时 ifinit() 一次，
# 主循环仅 select() 在 DHCPv6 socket 上。于是：
#   * Wi-Fi 重连、地址被系统清掉，它都不知道；
#   * 只能等自己 75 分钟一次的 T1 续租，可那时旧地址早已不在、续租必然失败；
#   * 进程若被 lmkd 之类干掉，没有任何东西会把它拉起来。
#
# 这个脚本补的就是「谁、在什么时候、因为什么，去启动或重启它」这一层。
# 在 BSD 上这个角色是 rc 脚本，Android 上没有对应的钩子。
#
# 顺带它还负责一件事：每拍把当前状态写进 module.prop 的 description，
# 于是管理器卡片上能看到「已获取 IPv6 地址 / 未连接 Wi-Fi」这类实时状态
# （管理器每次打开都会重读 module.prop）。实现见 common.sh 的 d6_desc_update()。
#
# ── 两个设计取舍 ─────────────────────────────────────────────────
#
# 1) 轮询，而不是监听事件。
#    设备上没有可用的 netlink 事件工具：toybox 的 ip 不支持 monitor，
#    busybox 的 ip 只认 address|route|link|neigh|rule。所以只能轮询。
#    读 /proc/net/if_inet6 用的是 shell 内建 read，不 fork 任何进程，
#    每 5 秒一次的代价可以忽略（对比：dhcp6c 若用全放行的 BPF，
#    空载就有 20 次/秒唤醒）。
#
# 2) 判据是「上一次拿到的地址还在不在」，而不是「地址集合变没变」。
#    后者看着更通用，其实会自我激发：dhcp6c 自己把地址加上去这个动作
#    本身就让集合变了，于是看门狗重启 dhcp6c，dhcp6c 重新加地址，
#    集合又变 —— 无限重启。盯着「某个具体地址消失了」才没有这个问题，
#    因为地址出现不会触发重启，只有消失会。

_self=$(readlink -f "$0" 2>/dev/null)
[ -n "$_self" ] || _self=$0
MODDIR=${MODDIR:-${_self%/*/*}}
. "$MODDIR/lib/common.sh"

CTL="$DHCP6C_MODDIR/lib/dhcp6c-ctl.sh"

mkdir -p "$DHCP6C_STATE" "$DHCP6C_LOGDIR"
printf '%s\n' "$$" > "$DHCP6C_WD_PID"

# 收到 TERM 时把 pid 文件收干净，免得下次启动误判「已有实例在跑」。
trap 'rm -f "$DHCP6C_WD_PID"; exit 0' TERM INT

interval=5          # 正常巡检间隔（秒）
backoff_base=5      # 首次失败后的等待
backoff_cap=120     # 退避上限：网络确实不支持 IA_NA 时，最多两分钟试一次

fail=0
idle_stopped=0
rotate_tick=0

ifname=$(d6_resolve_ifname)
d6_log "watchdog 启动 pid=$$，目标接口 $ifname"

# 日志轮转：只在超过阈值时动手，避免长跑之后文件无限膨胀。
rotate_logs() {
	for _lf in "$DHCP6C_WD_LOG" "$DHCP6C_LOG" "$DHCP6C_SCRIPT_LOG"; do
		[ -r "$_lf" ] || continue
		_sz=$(wc -c < "$_lf" 2>/dev/null)
		case "$_sz" in ''|*[!0-9]*) continue ;; esac
		if [ "$_sz" -gt 131072 ]; then
			tail -n 400 "$_lf" > "$_lf.tmp" 2>/dev/null && mv "$_lf.tmp" "$_lf"
		fi
	done
}

# 先睡一个巡检周期再进入正式循环。
#
# 原因：刚被 ctl 拉起来时，ctl 紧接着就会自己启动 dhcp6c（快路径）。
# 如果不延迟，watchdog 第一轮立刻看到「进程还没起来」，
# 于是又走一遍 stop+start，白白多一次重启、日志里也会多出重复条目。
# 延迟一拍能避开这个窗口；窗口万一没避开也无所谓 —— 所有启停都由
# ctl 的互斥锁串行化，最坏只是多重启一次，不会出现两个实例。
sleep "$interval"

while :; do
	# ── 刷新模块卡片上的简介（module.prop 的 description）
	#
	# 放在最前面，是为了「暂停 / 已停用 / 没连 Wi-Fi」这些状态也能被写出去：
	# 下面几个分支都会 continue，放到后面就漏了。
	# 状态没变时 d6_desc_update() 只读一次文件、不写，所以每拍都调无所谓。
	d6_desc_update "$(d6_status_short "$ifname")"

	# ── 模块被停用 / 待卸载：收工
	if d6_is_module_off; then
		d6_log "模块已停用或待卸载，watchdog 退出"
		"$CTL" stop >/dev/null 2>&1
		rm -f "$DHCP6C_WD_PID"
		exit 0
	fi

	# ── 用户手动暂停：待命，不反复去停 dhcp6c
	if d6_is_paused; then
		sleep "$interval"
		continue
	fi

	# ── 接口还不存在（没开 Wi-Fi / 启动早期）：停掉客户端等它出现
	if ! d6_iface_exists "$ifname"; then
		if [ "$idle_stopped" != 1 ]; then
			d6_log "接口 $ifname 不存在，先停掉 dhcp6c 等待"
			"$CTL" stop >/dev/null 2>&1
			idle_stopped=1
		fi
		# 接口名有可能变（换网卡、热插拔），顺手重新解析一次
		_newif=$(d6_resolve_ifname)
		[ -n "$_newif" ] && ifname=$_newif
		sleep "$interval"
		continue
	fi
	idle_stopped=0

	# ── 判断要不要重启
	want_restart=0
	reason=

	if ! d6_is_running; then
		want_restart=1
		reason="进程未在运行"
	elif [ -r "$DHCP6C_IA_FILE" ]; then
		expect=$(cat "$DHCP6C_IA_FILE" 2>/dev/null)
		if [ -n "$expect" ] && ! d6_iface_has_addr "$ifname" "$expect"; then
			want_restart=1
			reason="期望的地址 $expect 已不在 $ifname 上（多半被网络栈清掉了）"
		fi
	fi

	rotate_tick=$((rotate_tick + 1))
	[ "$rotate_tick" -ge 720 ] && { rotate_tick=0; rotate_logs; }

	if [ "$want_restart" = 1 ]; then
		fail=$((fail + 1))
		d6_log "第 $fail 次重启：$reason"
		"$CTL" restart >/dev/null 2>&1

		# 指数退避 5,10,20,40,80,120,120,...
		wait=$backoff_base
		_n=$fail
		while [ "$_n" -gt 1 ] && [ "$wait" -lt "$backoff_cap" ]; do
			wait=$((wait * 2))
			_n=$((_n - 1))
		done
		[ "$wait" -gt "$backoff_cap" ] && wait=$backoff_cap

		sleep "$wait"
	else
		fail=0
		sleep "$interval"
	fi
done
