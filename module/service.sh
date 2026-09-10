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

CTL="$MODDIR/lib/dhcp6c-ctl.sh"

# 已经有一个在跑就什么都不做（幂等）
"$CTL" ensure

# 顺手把模块卡片上的简介刷成当前状态。这一步不能省给 watchdog ——
# 它启动后要先睡一个完整巡检周期，那之前卡片上还挂着开机前的旧状态。
# 刚开机时 Wi-Fi 通常还没连上，写进去的多半是「未连接 Wi-Fi」，
# 但那是**真话**；比显示上一次会话残留的「已获取」要诚实得多。
"$CTL" desc
