# DHCPv6 客户端（Android）

[![build](https://github.com/TianyiTwT/dhcpv6-client-android-kernelsu/actions/workflows/build.yml/badge.svg)](https://github.com/TianyiTwT/dhcpv6-client-android-kernelsu/actions/workflows/build.yml)
[![license](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)

为 Android 补齐 DHCPv6 有状态地址分配（IA_NA）的 KernelSU / Magisk 模块。

Android 全版本都不实现 IA_NA（Google Issue 36949085，Won't Fix）。在只提供
IA_NA、不做前缀委派（PD）的网络上，设备无法获得全局 IPv6 地址。本模块在无线
接口上运行一个外部 `dhcp6c`，直接与服务器完成标准四步握手：

```
Solicit → Advertise → Request → Reply
```

地址由 `dhcp6c` 自行写入内核，握手结束后数据面不再需要本模块参与。

底层是 [wide-dhcpv6](https://github.com/TianyiTwT/dhcp6c) 的 Android 适配 fork。
收发下沉到 AF_PACKET 二层，绕开被系统 DHCPv6 客户端长期占用的 UDP 546 端口。

## 特性

- 标准四步握手，取回 `/128` 有状态地址
- 地址稳定：DUID 与固定 IAID 落盘，重启后取回同一地址
- 地址被外部清除后 1～2 秒内自动恢复
- 空载零唤醒：BPF 过滤器收窄到只放行 DHCPv6 帧
- 开机自启；接口出现、地址丢失、进程退出均自动收敛
- 模块卡片实时显示当前状态（依据 `module.prop`，不依赖管理器专有接口）
- WebUI 显示接口地址，并标出哪一个是本模块取得的

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Android | 7.0（API 24）及以上 |
| 架构 | arm64-v8a 或 armeabi-v7a |
| Root 方案 | KernelSU / SukiSU / ReSukiSU / Magisk |
| 网络 | 目标网络提供 DHCPv6 有状态地址分配（RA 中 M 位为 1） |

WebUI 依赖 KernelSU 系管理器（`webroot` 是该系引入的机制）。纯 Magisk 环境下
模块功能不受影响，只是没有内置 WebUI，查看状态改用模块卡片的「操作」按钮或
直接读状态文件。

## 安装

从 [Releases](https://github.com/TianyiTwT/dhcpv6-client-android-kernelsu/releases)
下载对应 ABI 的 zip，在模块管理器里安装，然后重启。

命令行安装：

```sh
adb push dhcp6c-android-v0.1.1-arm64-v8a.zip /data/local/tmp/
adb shell su -c 'ksud module install /data/local/tmp/dhcp6c-android-v0.1.1-arm64-v8a.zip'
```

KernelSU 系的模块内容替换在下次开机才生效，安装后需要重启。重启即自动启动；
不想等重启，可点模块卡片的「操作」按钮立刻拉起。

## 使用

打开模块的 WebUI（KernelSU 系管理器），页面显示目标接口的 IPv4 / IPv6 地址，
并标出本模块通过 DHCPv6 取得的那一个，以及客户端与看门狗的运行状态。
底部的「重启客户端」按钮等价于 `restart`。

不开 WebUI 时，用模块卡片的「操作」按钮查看状态，或直接调用控制脚本：

```sh
S=/data/adb/modules/dhcp6c-android/lib/dhcp6c-ctl.sh

sh $S status     # key=value 运行状态
sh $S start      # 清除暂停标志，确保 watchdog 在跑，并启动客户端
sh $S pause      # 停止客户端并置暂停标志（watchdog 保留但待命）
sh $S resume     # 等同 start
sh $S restart    # 停掉后重新拉起
sh $S ensure     # 只确保 watchdog 在跑
sh $S hold       # 只停止客户端，不置暂停标志、不结束 watchdog（供 watchdog 内部使用）
sh $S desc       # 刷新模块卡片上的状态短语
```

三个停止类子命令的差别：`hold` 只停客户端，watchdog 会把它重新拉起，因此仅用于
watchdog 内部的暂时性状况；`pause` 额外写入暂停标志，watchdog 转为待命并停止拉起；
`stop` 在 `pause` 基础上进一步结束 watchdog。

## 配置

生效的配置文件是 `/data/adb/dhcp6c/dhcp6c.conf`，由 `module/etc/dhcp6c.conf.in`
在安装时生成，之后不会被模块更新覆盖。

```
interface wlan0 {
	send ia-na 0;
	request domain-name-servers;
	script "/data/adb/dhcp6c/dhcp6c-script";
};

id-assoc na {
};
```

两处不能改动的地方：

- `domain-name-servers` 必须写 `request`。写成 `send` 只会打印一行
  `invalid operation (0) for option type (19)`，然后静默地不把选项 23 加进 ORO，
  也就是根本没有请求 DNS。
- `send ia-na 0;` 中的 IAID 不要改。地址稳定性依赖 DUID 与 IAID 都不变。

## 构建

依赖 Android NDK（r25+）与 bison / flex。Windows 上可用便携版 WinFlexBison。
详见 `dhcp6c/android/README.md`。

```sh
git submodule update --init         # 首次
sh build.sh                         # 编译 arm64-v8a 并打包
sh build.sh --abi armeabi-v7a       # 换 ABI
sh build.sh --api 21                # 改 minSdk API level（默认 24）
sh build.sh --ndk /path/to/ndk      # 指定 NDK 路径
sh build.sh --skip-build            # 跳过编译，沿用现有 module/bin/dhcp6c
sh build.sh --install               # 打包后用 adb + ksud 装到设备
```

产物为 `dist/dhcp6c-android-<version>.zip`。zip 的根目录就是模块内容
（`module.prop` 位于最外层），可直接被管理器安装。一个模块包只容纳一个 ABI 的
二进制，所以换 ABI 需要重新打包。

### 持续集成

`.github/workflows/build.yml` 在以下时机运行：推送到 `main`、Pull Request、
手动触发，以及推送形如 `v0.1.1` 的 tag。

- 构建矩阵为 `arm64-v8a` 与 `armeabi-v7a`，每个 ABI 各出一个 zip，
  产物在对应 run 的 Artifacts 中下载。
- 推送 `v*` tag 时额外创建 Release 并附上两个 zip。
- 手动触发可填写 minSdk API level，默认沿用 `build.sh` 的 24；
  需要支持 Android 7.0 以下的设备时填 21。
- CI 与本机等价的条件是 NDK r29 + bison / flex。交叉编译可复现，
  arm64-v8a 的预期摘要在 workflow 的「记录二进制摘要」一步中给出；摘要不符时
  先核对 NDK 版本与宿主环境。

## 仓库结构

```
.
├── .github/workflows/build.yml   # CI：构建、打包、tag 触发 Release
├── build.sh                      # 编译 + 打包
├── dhcp6c/                       # submodule：wide-dhcpv6 的 Android fork
├── module/                       # 模块内容，即打进 zip 的部分
│   ├── module.prop
│   ├── customize.sh              # 安装 / 升级时执行
│   ├── service.sh                # 开机自启（late_start service）
│   ├── action.sh                 # 模块卡片的「操作」按钮
│   ├── uninstall.sh
│   ├── bin/dhcp6c                # 构建产物，不入库
│   ├── etc/dhcp6c.conf.in        # 配置模板
│   ├── lib/
│   │   ├── common.sh             # 路径常量与只读探测
│   │   └── dhcp6c-ctl.sh         # 状态变更的唯一入口
│   ├── scripts/
│   │   ├── dhcp6c-watchdog.sh    # 常驻监督进程
│   │   └── dhcp6c-script         # dhcp6c 事件回调
│   └── webroot/                  # WebUI
└── docs/design.md                # 设计说明
```

`dhcp6c/` 固定在 tag `android-v1.0.0`。模块不提交编译产物，因此「用的是哪个
版本的 dhcp6c」始终由 submodule 指针决定。

## 运行时布局

模块自身位于 `/data/adb/modules/dhcp6c-android/`，只读且随模块更新。
运行期数据统一位于 `/data/adb/dhcp6c/`：

```
/data/adb/dhcp6c/
├── dhcp6c.conf          # 生效的配置（安装时由模板生成，之后不被覆盖）
├── dhcp6c-script        # 回调脚本（每次安装覆盖，与模块版本保持一致）
├── dhcp6c_duid          # DUID，地址稳定的关键，不要删除
├── dhcp6c.pid
├── log/{dhcp6c,watchdog,script}.log
└── state/
    ├── ia_na.addr       # 最近一次取得的地址（32 位十六进制）
    ├── ia_na.text       # 同一地址的冒号写法
    ├── ifname           # 目标接口（可选，未设置则自动探测）
    ├── paused           # 存在即表示用户手动暂停
    └── watchdog.pid
```

该路径同时是 `dhcp6c` 的编译期 `--prefix`，决定 DUID 的落盘位置。换到其它
路径会使地址稳定机制失效。

## 测试情况

开发与验证在两台设备上进行：

| 设备 | 系统 | Root 方案 |
| --- | --- | --- |
| 小米 13 Ultra | Android 16 / HyperOS 3 | SukiSU Ultra v4.2.0 |
| Redmi K30 Pro | Android 16 / HyperOS 3 | ReSukiSU |

在小米 13 Ultra 上确认的行为：

- 四步握手通过，取得 `/128` 有状态地址，可访问公网 IPv6
- 反复重启取回同一地址
- 手动删除地址后 1～2 秒内自动取回同一地址
- 空载唤醒 0 次

Redmi K30 Pro 用于第二套管理器环境下的安装、开机自启与 WebUI 验证。

## 已知限制

1. **地址不被 `ConnectivityService` 追踪。** 框架的 `LinkProperties` 不包含该
   地址，因此 `NetworkCapabilities` 的判定和通过 API 查询到的地址列表都不含它。
   数据面可用（内核转发与 `dhcp6c` 无关），但在「系统是否认为该网络有 IPv6」
   这一点上框架是无感知的。补齐这个缺口需要在 LSPosed 层实现。

2. **DNS 未处理。** 服务端下发的 DNS 仅记录在 `state/dns.servers`，不会注入
   系统解析器。`ndc resolver` 在 Android 16 上已被移除（实测返回
   `500 0 Command not recognized`），传统注入路径不可用；需要自定义 DNS 请
   配合独立的 DNS 模块。

3. **默认路由仍由 RA 提供。** DHCPv6 本身不下发默认路由，这部分不归本模块管。

4. **WebUI 仅在 KernelSU / APatch 系可用。** Magisk 的模块结构中没有 `webroot`
   机制，其模块卡片只有「操作」按钮。

## 设计说明

看门狗的必要性、轮询而非监听事件的原因、不发送 RELEASE 的取舍、并发保护，
以及状态短语的判定顺序，见 [docs/design.md](docs/design.md)。

## 许可

BSD-3-Clause，见 [LICENSE](LICENSE)。

`dhcp6c/`（wide-dhcpv6 fork）同为 BSD-3-Clause，许可证原文在该目录内。
