#!/system/bin/sh
#
# uninstall.sh —— 卸载时执行
#
# 停掉 watchdog 和 dhcp6c，然后删掉运行期目录。
# 注意：DUID 与配置也在这里面，所以卸载后重装会是一个「全新的客户端」，
# 拿到的地址可能与卸载前不同。

MODDIR=$(readlink -f "$0" 2>/dev/null)
MODDIR=${MODDIR%/*}

"$MODDIR/lib/dhcp6c-ctl.sh" stop >/dev/null 2>&1

PREFIX=/data/adb/dhcp6c
# 只删自己这一个目录，路径写死并再校验一次，避免变量异常时误伤
case "$PREFIX" in
	/data/adb/dhcp6c)
		rm -rf "$PREFIX"
		;;
esac

exit 0
