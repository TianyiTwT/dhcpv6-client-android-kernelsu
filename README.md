# DHCPv6 客户端（Android / KernelSU 模块）

给 Android 补上 **DHCPv6 有状态地址分配（IA_NA）**。

Android 全版本都不实现 IA_NA（Google Issue 36949085，Won't Fix），所以在只做
IA_NA、不支持前缀委派（PD）的网络上，设备拿不到全局 IPv6 地址。本模块用一个
外部 `dhcp6c` 在无线接口上直接与服务器完成标准四步握手：

```
Solicit → Advertise → Request → Reply
```

拿到地址后由 `dhcp6c` 自己写进内核，之后 IPv6 数据面的转发与它无关。

底层是 [wide-dhcpv6](https://github.com/TianyiTwT/dhcp6c)（opnsense fork 的
Android 适配版）。关键改动是把收发下沉到 **AF_PACKET 二层**，绕开被 Android
系统 DHCPv6 客户端长期占用的 UDP 546 端口。

---

## 现状

在小米 13 Ultra / Android 16 / KernelSU 4.2.0 上实测通过：

| 项目 | 结果 |
|---|---|
| 四步握手 | 通过，拿到 `/128` 有状态地址 |
| 地址可用性 | 能 ping 通公网 IPv6 |
| 地址稳定性 | 反复重启都拿回同一个地址（靠 DUID + IAID 持久化） |
| 地址被清掉后自动恢复 | 通过。手动删除地址，1～2 秒内自动拿回**同一个**地址 |
| 空载唤醒 | 0 次（BPF 过滤器已收窄到只放行 DHCPv6 帧） |

**只做 IPv6，DNS 尚未处理**，见下文「已知限制」。

---

## 目录结构

```
.
├── .github/workflows/build.yml # CI：编译 + 打 tag 时自动发 Release
├── dhcp6c/                    # submodule：fork 出来的 wide-dhcpv6，锁定 tag android-v1.0.0
├── module/                    # 模块内容，即打进 zip 的东西
│   ├── module.prop
│   ├── customize.sh           # 安装/升级时执行
│   ├── service.sh             # 开机自启（late_start service）
│   ├── action.sh              # 模块卡片上的「操作」按钮
│   ├── uninstall.sh
│   ├── bin/dhcp6c             # 构建产物，不入库
│   ├── etc/dhcp6c.conf.in     # 配置模板
│   ├── lib/
│   │   ├── common.sh          # 只读探测（路径、接口、地址、进程）
│   │   └── dhcp6c-ctl.sh      # 状态变更的唯一入口（起停、查询）
│   ├── scripts/
│   │   ├── dhcp6c-watchdog.sh # 常驻监督进程
│   │   └── dhcp6c-script      # dhcp6c 的事件回调
│   └── webroot/               # WebUI（KernelSU 管理器里打开）
└── build.sh                   # 编译 + 打包
```

---

## 构建与安装

需要 Android NDK（r25+）与 bison/flex。见 `dhcp6c/android/README.md`。

```sh
git submodule update --init          # 首次
sh build.sh                          # 编译并打包
sh build.sh --install                # 打包后直接 adb + ksud 装到设备
```

产物：`dist/dhcp6c-android-<version>.zip`，可直接被 KernelSU / Magisk 安装。

装完后开机自动启动；想立刻生效就点模块卡片的「操作」按钮。

### 自动构建（GitHub Actions）

推送到 `main`、提 PR、或在 Actions 页手动触发，都会在 CI 上完整编译一遍。
矩阵是 `arm64-v8a` + `armeabi-v7a`（一个模块包只容纳一个 ABI 的二进制，
所以每个 ABI 各出一个 zip），产物在对应 run 的 Artifacts 里下载。

推形如 `v0.2.0` 的 tag 时，除了编译还会自动建 Release 并把两个 zip 挂上去。

CI 与本机等价的条件是 **NDK r29 + bison/flex**。本机编出的 arm64 二进制
SHA256 是 `08cb2ff61d249ee9ae7a7304e5fc53ed1890b777dfbfacbda2e8dfe1dfba3e52`，
CI 上若不同，先看 NDK 版本或宿主差异，不要先怀疑代码。

老设备（低于 Android 7.0）需要手动触发并把 minSdk 降到 21 —— 即 Actions 页的
`minSdk API level` 填 `21`。

---

## 运行时布局

模块自身在 `/data/adb/modules/dhcp6c-android/`（只读、随模块更新），
运行期数据统一在 `/data/adb/dhcp6c/`：

```
/data/adb/dhcp6c/
├── dhcp6c.conf          # 生效的配置（安装时由模板生成，之后不会被覆盖）
├── dhcp6c-script        # 回调脚本（每次安装覆盖，保证与模块版本一致）
├── dhcp6c_duid          # DUID，地址稳定的关键，不要删
├── dhcp6c.pid
├── log/{dhcp6c,watchdog,script}.log
└── state/
    ├── ia_na.addr       # 最近一次拿到的地址（32 位十六进制）
    ├── ia_na.text       # 同一地址的冒号写法
    ├── paused           # 存在 = 用户手动暂停
    └── watchdog.pid
```

`/data/adb/dhcp6c` 这个路径不是随便定的：它是 `dhcp6c` 的编译期 `--prefix`，
决定了 DUID 的落盘位置。换路径会让地址稳定性失效。

---

## 为什么需要一个 watchdog

这是本项目最容易被质疑的一点：**Android 自己的 DHCPv4 不需要看门狗，为什么你要？**

因为 Android 的 DHCP 客户端（`IpClient` / `ConnectivityService`）自带一个监督者，
而这个监督者只服务于**框架自己启动的**客户端：

| | Android 自带 DHCP | 本模块的 dhcp6c |
|---|---|---|
| 何时启动 | 网络需要地址时由框架启动 | 没人告诉它 → 需要看门狗 |
| 何时停止 | 网络消失时由框架停掉 | 不会自己停 → 需要看门狗 |
| 重连 / 漫游 | 框架重建客户端 | 不知道网络变了 → 需要看门狗 |
| 地址归属 | 写进 `LinkProperties`，框架保管 | 框架不认，会被当成未知地址清掉 → 需要看门狗 |
| 进程死了 | 框架会拉起 | 没人管 → 需要看门狗 |

而 `wide-dhcpv6` 本身也不监听链路事件。这一点是读过源码确认的：
**整个仓库没有任何 `PF_ROUTE` / `RTM_*` 处理**，只在启动时 `ifinit()` 取一次
接口信息，主循环只 `select()` 在 DHCPv6 socket 上。于是它

* 不知道 Wi-Fi 重连了；
* 不知道地址被网络栈清掉了；
* 只能等自己 75 分钟一次的 T1 续租 —— 那时旧地址早已不在，续租必然失败。

`scripts/dhcp6c-watchdog.sh` 补的就是这一层。这个角色在 BSD 上是 rc 脚本，
Android 上没有对应的钩子。

### 它的两个设计取舍

**轮询而不是监听事件。** 设备上没有可用的 netlink 事件工具：toybox 的 `ip`
不支持 `monitor`，busybox 的 `ip` 只认 `address|route|link|neigh|rule`。
所以直接读 `/proc/net/if_inet6`，用 shell 内建 `read`，不 fork 任何进程，
每 5 秒一次的代价可以忽略。

**判据是「上一次拿到的地址还在不在」，而不是「地址集合变没变」。**
后者看着更通用，其实会自我激发：`dhcp6c` 自己把地址加上去这个动作本身就让
集合变了，于是看门狗重启 `dhcp6c`、`dhcp6c` 重新加地址、集合又变 —— 无限重启。
盯着「某个具体地址消失了」才没有这个问题，因为地址出现不触发重启，只有消失会。

### 停止时不发送 RELEASE

停止走 `SIGUSR1`，并且启动时带了 `-n`（两道保险），两者都让 `dhcp6c` 在退出时
**不发送 RELEASE**。原因是地址稳定性靠「DUID + IAID 不变」来保证，而发出
RELEASE 等于告诉服务端「这个地址我还回去了」，它可能被回收再分给别人。
保留租约让它自然超时，重新 Solicitation 时更可能拿回原地址。
DHCPv6 的租约本来就是软的，不发 RELEASE 完全合规。

需要分清楚「不发 RELEASE」和「保住本地地址」是两件不同的事：进程退出时
`release_all_ia()` → `remove_ia()` → `cleanup_addr()` → `na_ifaddrconf(IFADDRCONF_REMOVE)`
（`dhcp6c_ia.c:441`、`addrconf.c:228/284`），**本地地址仍然会被删掉**，这条路径没有被
`opt_norelease` 拦。这是有意为之——用户点了停止就不该在接口上留一个没有协议守护的幽灵地址。
「不发 RELEASE」保的是**服务端的租约绑定**，所以下次拉起能很快拿回同一个地址；
真正让地址在重启前后保持一致的是 DUID 与 IAID 都没变。

### 并发保护

起停会被 WebUI、`action.sh`、watchdog 三处独立触发。而 `d6_start` 在启动前
必须删掉 pidfile（`dhcp6c` 会对它 `flock`，里面残留的旧 PID 会让它误判
「已有实例在跑」而直接退出），这个删除会把 flock 赖以生效的 inode 换掉 ——
两个并发的 `d6_start` 可以各建一个新 inode、各拿一把锁，**同时启动两个实例**。
真机日志里确实出现过。现在所有状态变更都在一个 `mkdir` 原子锁里串行化。

---

## WebUI

KernelSU 管理器里打开。显示目标接口上的 IPv4 / IPv6 地址，并标出哪个是本模块
通过 DHCPv6 拿到的。数据来自：

```sh
<模块>/lib/dhcp6c-ctl.sh status     # key=value 运行状态
ip -o addr show                     # 每行一个地址
```

两条命令合并成一次调用，用 `##ADDR` 分隔。

`webroot/dev-preview.html` 是给人看渲染效果的预览页（内含模拟桥与真机抓的数据），
**不会打进模块包**。

---

## 已知限制

1. **地址不被 `ConnectivityService` 追踪。** 框架的 `LinkProperties` 里没有这个
   地址，所以 `NetworkCapabilities` 的判定、以及应用通过 API 查询到的地址列表
   都不包含它。数据面能用（内核转发跟 `dhcp6c` 无关），但「系统是否认为这个网络
   有 IPv6」这一点上它是瞎的。要补这个缺口只能做 LSPosed 层。
2. **DNS 未处理。** 服务端下发的 DNS 只记录在 `state/dns.servers`，不会被注入
   `netd` 解析器。校园网常见「DNS 不返回 AAAA」的问题需要单独处理。
   顺带一提：`ndc resolver` 在 Android 16 上已被移除（实测返回
   `500 0 Command not recognized`），老式注入路线走不通。
3. **默认路由仍然只靠 RA。** DHCPv6 本身不下发默认路由，这个不归本模块管。
4. **WebUI 只在 KernelSU / APatch 里能开。** `webroot` 目录是 KernelSU 引入的机制，
   Magisk 没有对应的内置 WebUI（它的模块结构里只有 `post-fs-data.sh` / `service.sh` /
   `action.sh` / `system.prop` / `sepolicy.rule`）。所以在纯 Magisk 环境下，
   模块功能照常（`dhcp6c`、看门狗、开机自启、`action.sh` 的「操作」按钮都不依赖 KernelSU），
   但看地址得用「操作」按钮或自己 `cat /data/adb/dhcp6c/state/ia_na.text`。

---

## 许可

- 本仓库：BSD-3-Clause
- `dhcp6c/`（wide-dhcpv6）：BSD-3-Clause
