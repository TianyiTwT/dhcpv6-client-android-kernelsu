#!/system/bin/sh
#
# service.sh —— 开机自启（late_start service 阶段）
#
# 这个阶段只做一件事：确保 watchdog 在跑，然后立刻返回。
#
# 为什么不在这里等网络 / 等地址：
#   late_start service 时 Wi-Fi 通常还没连上，阻塞在这里没有意义，
#   而且会拖慢开机流程。所有「等接口出现、等地址拿到、地址掉了就重启」
#   的逻辑都在 watchdog 里 —— 它本来就是为长时间驻留设计的。

MODDIR=$(readlink -f "$0" 2>/dev/null)
MODDIR=${MODDIR%/*}

. "$MODDIR/lib/common.sh"
CTL="$MODDIR/lib/dhcp6c-ctl.sh"

# ── 先清掉上一次会话残留的「用户暂停」标志 ──────────────────────────
#
# 暂停是**运行期的临时状态**，跨重启没有意义 —— 开机时用户并没有表达
# 「这次也先别启动」的意图。而它一旦残留，watchdog 会静默待命，客户端
# 永远不启动，症状就是「重启完客户端不自启，手动点一下才好」。
#
# 历史上这个标志还会被 watchdog 自己误写（见 dhcp6c-watchdog.sh 里
# 接口不存在 / 模块停用两处的注释），所以这道清理同时也是兜底。
# 想长期关掉模块，请用模块管理器的「停用」（那是 disable 文件，不冲突）。
mkdir -p "$DHCP6C_STATE" "$DHCP6C_LOGDIR"
if [ -e "$DHCP6C_PAUSED" ]; then
	d6_log "开机：清掉上次残留的暂停标志（暂停不跨重启）"
	rm -f "$DHCP6C_PAUSED"
fi

# 已经有一个在跑就什么都不做（幂等）
"$CTL" ensure

# 顺手把模块卡片上的简介刷成当前状态。这一步不能省给 watchdog ——
# 它启动后要先睡一个完整巡检周期，那之前卡片上还挂着开机前的旧状态。
# 刚开机时 Wi-Fi 通常还没连上，写进去的多半是「未连接 Wi-Fi」，
# 但那是**真话**；比显示上一次会话残留的「已获取」要诚实得多。
"$CTL" desc
