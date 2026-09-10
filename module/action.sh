#!/system/bin/sh
#
# action.sh —— 模块卡片上的「操作」按钮
#
# KernelSU / Magisk 会在用户点击时执行本脚本，stdout 会显示给用户。
# 所以这里输出的是给人看的中文，不是给程序解析的 key=value。
#
# 行为：确保 watchdog 在跑 -> dhcp6c 没跑就拉起来 -> 打印当前状态。
# 相当于一个「一键修复 + 看看现在怎么样」的按钮。

MODDIR=$(readlink -f "$0" 2>/dev/null)
MODDIR=${MODDIR%/*}
CTL="$MODDIR/lib/dhcp6c-ctl.sh"

"$CTL" ensure >/dev/null 2>&1

_out=$("$CTL" status 2>/dev/null)

get() {
	printf '%s\n' "$_out" | sed -n "s/^$1=//p" | head -n 1
}

running=$(get RUNNING)
pid=$(get PID)
wd=$(get WATCHDOG)
ifname=$(get IFNAME)
iface_up=$(get IFACE_UP)
ia=$(get IA_ADDR)
g6=$(get GLOBAL6)
paused=$(get PAUSED)
off=$(get MODULE_OFF)

echo "DHCPv6 客户端"
echo "──────────────"

if [ "$running" = 1 ]; then
	echo "状态：运行中（pid $pid）"
else
	echo "状态：未运行"
fi

if [ "$paused" = 1 ]; then
	echo "监督：已暂停（用户手动停止）"
elif [ "$wd" = 1 ]; then
	echo "监督：watchdog 在跑"
else
	echo "监督：watchdog 未运行"
fi

if [ "$off" = 1 ]; then
	echo "模块：已停用或待卸载"
fi

if [ "$iface_up" = 1 ]; then
	echo "接口：$ifname（已就绪）"
else
	echo "接口：$ifname（未就绪）"
fi

if [ -n "$ia" ]; then
	echo "IA_NA 地址：$ia"
else
	echo "IA_NA 地址：尚未取得"
fi

echo "全局 IPv6 地址数：$g6"
