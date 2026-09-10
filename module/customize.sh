#!/system/bin/sh
#
# customize.sh —— 安装 / 升级时执行
#
# KernelSU 与 Magisk 都会带着 $MODPATH 调用它，$MODPATH 指向**临时解包目录**
# （Magisk 是 /data/adb/modules_update/<id>，KernelSU 类似），装完才会搬到
# /data/adb/modules/<id>。
#
# 因此这里刻意**不启动**任何东西：临时目录随后就消失了，此刻拉起来的 watchdog
# 会拿着一个失效的路径，之后既不可用也杀不掉。开机自启交给 service.sh，
# 立即启动交给模块的「操作」按钮（action.sh）或 WebUI。
#
# 做三件事：
#   1. 补可执行位（webroot 的权限由管理器自己设，不要碰）
#   2. 建运行期目录 /data/adb/dhcp6c
#   3. 生成 dhcp6c.conf —— 已存在则保留，避免升级冲掉用户改动

PREFIX=/data/adb/dhcp6c

if ! command -v ui_print >/dev/null 2>&1; then
	ui_print() { echo "$1"; }
fi

ui_print "- 安装 DHCPv6 客户端模块"

# ── 1. 可执行位
chmod 0755 "$MODPATH/bin/dhcp6c" 2>/dev/null
chmod 0755 "$MODPATH/service.sh" 2>/dev/null
chmod 0755 "$MODPATH/action.sh" 2>/dev/null
chmod 0755 "$MODPATH/uninstall.sh" 2>/dev/null
chmod 0755 "$MODPATH/lib/dhcp6c-ctl.sh" 2>/dev/null
chmod 0755 "$MODPATH/scripts/dhcp6c-watchdog.sh" 2>/dev/null
# 回调脚本必须可执行：dhcp6c 是按配置里的路径直接 exec 它的
chmod 0755 "$MODPATH/scripts/dhcp6c-script" 2>/dev/null

# ── 2. 运行期目录
mkdir -p "$PREFIX/state" "$PREFIX/log" 2>/dev/null

# ── 3. 回调脚本：模块自带，每次都覆盖，保证与模块版本一致
if [ -r "$MODPATH/scripts/dhcp6c-script" ]; then
	cp -f "$MODPATH/scripts/dhcp6c-script" "$PREFIX/dhcp6c-script"
	chmod 0755 "$PREFIX/dhcp6c-script"
fi

# ── 4. 配置：只有不存在时才生成
if [ -r "$PREFIX/dhcp6c.conf" ]; then
	ui_print "- 已存在 dhcp6c.conf，保留原文件不覆盖"
else
	# 挑无线接口：优先 operstate=up 的
	ifname=
	for d in /sys/class/net/*/wireless; do
		[ -e "$d" ] || continue
		i=${d%/wireless}
		i=${i##*/}
		case "$i" in p2p0|wifi-aware0) continue ;; esac
		[ -n "$ifname" ] || ifname=$i
		if [ "$(cat "/sys/class/net/$i/operstate" 2>/dev/null)" = up ]; then
			ifname=$i
			break
		fi
	done
	[ -n "$ifname" ] || ifname=wlan0

	if [ -r "$MODPATH/etc/dhcp6c.conf.in" ]; then
		sed "s/__IFNAME__/$ifname/" "$MODPATH/etc/dhcp6c.conf.in" > "$PREFIX/dhcp6c.conf"
		ui_print "- 已生成配置，接口：$ifname"
	else
		ui_print "! 找不到配置模板，安装可能不完整"
	fi
fi

ui_print "- 运行期目录：$PREFIX"
ui_print "- 装好了。开机后会自动启动；"
ui_print "  想立刻用，请点模块卡片上的「操作」按钮。"
