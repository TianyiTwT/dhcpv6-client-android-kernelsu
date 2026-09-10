#!/bin/sh
#
# build.sh —— 编译 dhcp6c 并打包成可安装的模块 zip
#
# 本模块不把二进制入库（见 .gitignore）：它是从 dhcp6c/ 这个 submodule 编译出来的。
# 这样做的好处是「本模块用的是哪个版本的 dhcp6c」始终明确 —— 就是 submodule
# 当前指向的那个 commit（当前锁定在 tag android-v1.0.0）。
#
# 用法：
#   sh build.sh                     # 默认 arm64-v8a
#   sh build.sh --abi arm64-v8a,armeabi-v7a
#   sh build.sh --ndk /path/to/ndk  # 透传给 fork 的构建脚本
#   sh build.sh --api 21            # minSdk API level（默认 24，即 Android 7.0）
#   sh build.sh --skip-build        # 不重编，直接用现有的 module/bin/dhcp6c
#   sh build.sh --install           # 打完后用 adb + ksud 直接装到设备
#
# 产物：dist/dhcp6c-android-<version>.zip
#       zip 的根目录就是模块内容（module.prop 在最外层），可直接被管理器安装。

set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

ABI=arm64-v8a
SKIP_BUILD=0
DO_INSTALL=0
NDK_ARG=
API_ARG=
ADB=${ADB:-adb}

while [ $# -gt 0 ]; do
	case "$1" in
		--abi)        ABI="$2";    shift 2 ;;
		--ndk)        NDK_ARG="$2"; shift 2 ;;
		--api)        API_ARG="$2"; shift 2 ;;
		--skip-build) SKIP_BUILD=1; shift ;;
		--install)    DO_INSTALL=1; shift ;;
		-h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 2 ;;
	esac
done

VERSION=$(sed -n 's/^version=//p' module/module.prop | head -n 1)
[ -n "$VERSION" ] || VERSION=dev
ZIP="dist/dhcp6c-android-$VERSION.zip"

# ── 1. 编译 dhcp6c ────────────────────────────────────────────────
if [ "$SKIP_BUILD" = 1 ]; then
	echo "跳过编译，沿用 module/bin/dhcp6c"
else
	if [ ! -f dhcp6c/android/build.sh ]; then
		echo "错误：找不到 dhcp6c/android/build.sh" >&2
		echo "      submodule 还没拉下来？先执行：git submodule update --init" >&2
		exit 1
	fi

	rm -rf .build-out
	mkdir -p .build-out

	# 一个模块包只能装一个 ABI 的二进制，多 ABI 时只取第一个并说明
	FIRST_ABI=$(echo "$ABI" | cut -d, -f1)
	case "$ABI" in
		*,*) echo "注意：模块包只容纳一个 ABI 的二进制，将使用 $FIRST_ABI" ;;
	esac

	echo "── 编译 dhcp6c ($FIRST_ABI) ──"
	set -- --abi "$FIRST_ABI" --out .build-out
	if [ -n "$NDK_ARG" ]; then set -- "$@" --ndk "$NDK_ARG"; fi
	if [ -n "$API_ARG" ]; then set -- "$@" --api "$API_ARG"; fi
	sh dhcp6c/android/build.sh "$@"

	if [ ! -f ".build-out/dhcp6c-$FIRST_ABI" ]; then
		echo "错误：没有找到编译产物 .build-out/dhcp6c-$FIRST_ABI" >&2
		exit 1
	fi

	mkdir -p module/bin
	cp ".build-out/dhcp6c-$FIRST_ABI" module/bin/dhcp6c
	chmod 0755 module/bin/dhcp6c
fi

if [ ! -f module/bin/dhcp6c ]; then
	echo "错误：module/bin/dhcp6c 不存在。" >&2
	echo "      先不带 --skip-build 跑一次编译。" >&2
	exit 1
fi

# ── 2. 打包 ──────────────────────────────────────────────────────
mkdir -p dist
rm -f "$ZIP"

echo "── 打包 ──"
# dev-preview.html 只是给人看渲染效果的预览页，不进模块包
if command -v zip >/dev/null 2>&1; then
	( cd module && zip -qr "../$ZIP" . -x 'webroot/dev-preview.html' )
else
	# Windows 上通常没有 zip，用 python 兜底
	PY=$(command -v python3 || command -v python || true)
	if [ -z "$PY" ]; then
		echo "错误：环境里既没有 zip 也没有 python，无法打包" >&2
		exit 1
	fi
	"$PY" - "$ZIP" <<'PYEOF'
import os
import sys
import zipfile

out = sys.argv[1]
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
if os.path.exists(out):
    os.remove(out)

SKIP = {'.DS_Store', 'Thumbs.db', 'dev-preview.html'}

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk('module'):
        dirs[:] = [d for d in dirs if d not in ('.git',)]
        for name in sorted(files):
            if name in SKIP:
                continue
            path = os.path.join(root, name)
            # 相对 module/ 打包，让 module.prop 落在 zip 根目录
            z.write(path, os.path.relpath(path, 'module'))
print('已写入 ' + out)
PYEOF
fi

echo "产物：$ZIP（$(wc -c < "$ZIP") 字节）"

# ── 3. 可选：直接装到设备 ────────────────────────────────────────
if [ "$DO_INSTALL" = 1 ]; then
	REMOTE=/data/local/tmp/$(basename "$ZIP")
	echo "── 安装到设备 ──"
	"$ADB" push "$ZIP" "$REMOTE"
	"$ADB" shell "su -c 'ksud module install $REMOTE'"
	echo "装好了。用 ksud module action dhcp6c-android 可立即启动。"
fi
