# N5105 v5 校园网路由固件手册

适用设备：N5105 v5（Jasper Lake，4×i226-V 2.5G，UEFI 物理直装），16G 傲腾系统盘 + 500G 机械数据盘。
适用固件：ImmortalWrt 25.12.2（apk 包管理，Linux 6.12）定制构建，ext4 根分区，产物 `*ext4-combined-efi.img.gz`。

## 这套固件提供什么

- 锐捷校园网认证：`minieap`（`--module rjv3`）+ LuCI 协议页，账号由站点 profile 管理。
- 双栈分发：IPv4 NAT + IPv6 NAT66（内网 ULA `fd7a:6e64:6c35::/48`，出口 SNAT66），校园侧只看到软路由一个出口。
- 端口角色固定：按 MAC / PCI 路径绑定，不依赖内核 `ethX` 枚举顺序（`/usr/sbin/portmap`）。
- WAN 可用性探测：`/usr/sbin/wandetect`，6 个 HTTP 探针 + 3 个 ICMP 投票判定，阈值可配。
- 站点 profile 一键切换：`/usr/sbin/wanmode`（校园 / 家用 / 临时）。
- 防检测开关：`/usr/sbin/campus-guard`（TTL 钳制 + 外泄屏蔽 + WAN 禁入站），规则段落在 `/etc/firewall.user`，可随时 `clear`。
- 代理与容器：nikki（mihomo，白名单模式）；docker 需构建时打开（`include_docker=yes`）。
- 运维面：LuCI 自定义命令按钮（`luci-app-commands`）+ 在线文件编辑（`luci-app-filemanager`）+ ttyd 网页终端。

## 五分钟上手

1. **刷写**：把镜像写到 16G 傲腾，见 [install.md](install.md)。
2. **进后台**：eth1 接 AX3000T（AP 模式）或直接接电脑，浏览器开 `http://192.168.100.1`，用户名 `root`，出厂密码为空。
3. **先进后台、后接校园网**：首启 WAN 是关闭的（`proto none`），不会自己发 DHCP；先配好再插网线。
4. **配认证**：`wanmode set campus username '学号'` → `wanmode apply campus`，见 [campus.md](campus.md)。
5. **接校园网**：网线插 eth0，`ifstatus wan` 看到地址即通。

## 文档目录

| 文档 | 内容 |
|---|---|
| [install.md](install.md) | 刷写（Etcher / `dd` / Ventoy）、首次启动、进入后台、根分区扩容 |
| [campus.md](campus.md) | minieap 配置、`dhcp-type` 现场确认、认证失败排查 |
| [network.md](network.md) | 端口角色、AX3000T AP 模式、NAT66 与 IPv6 说明、网段冲突 |
| [ops.md](ops.md) | profile 切换、防检测开关、swap、数据盘与 docker、备份与回滚 |
| [compliance.md](compliance.md) | 校园网使用条款与责任声明（**上线前必读**） |

## 常用命令速查

```sh
# 端口角色
portmap resolve                     # 看 wan=eth0 lan=eth1 eth2 eth3
portmap apply --dry-run             # 只解析，不写配置
portmap apply                       # 写入 network 配置（之后还要 reload network）

# WAN 站点 profile
wanmode list                        # 列出 profile
wanmode show                        # 当前生效的 profile
wanmode apply campus                # 切到校园网（minieap）
wanmode set campus username '学号'   # 改 profile 字段

# 防检测
campus-guard status                 # 开关状态 + 当前规则段
campus-guard show                   # 只打印将要写入的规则（不改任何文件）
campus-guard apply                  # 写入 /etc/firewall.user 并 reload 防火墙
campus-guard clear                  # 删除规则段并 reload（回滚用）

# WAN 探测
wandetect run                       # 立即探测一轮，输出 online/degraded/failed
wandetect status                    # 最近一次判定

# swap
swapctl status                      # 当前 swap 与内存
swapctl apply                       # 按 /etc/config/swap 创建并启用 swapfile
swapctl resize 8192                 # 改到 8192MB（先 swapoff 再重建）

# 通用
logread -e minieap -f               # 跟认证日志
ifstatus wan                        # WAN 接口状态（JSON）
uci show network.wan                # WAN 的 UCI 配置
```

## 常见问题入口

| 症状 | 先看哪里 |
|---|---|
| 刷完开不了机 / 找不到启动项 | [install.md](install.md) 的「前提与 BIOS 设置」 |
| 连上 WiFi 但打不开 192.168.100.1 | [install.md](install.md) 的「进后台」；[network.md](network.md) 的「AX3000T 设为 AP」 |
| 能进后台但上不了网 | [campus.md](campus.md) 的「认证失败排查」 |
| 认证成功但终端没有 IPv6 | [network.md](network.md) 的「IPv6：为什么用 NAT66」 |
| 想把固件带回家里用 | [ops.md](ops.md) 的「profile 切换」 |
| 担心被校园网识别成路由器 | [ops.md](ops.md) 的「防检测开关」+ [compliance.md](compliance.md) |
| 数据盘 / docker 数据存哪里 | [ops.md](ops.md) 的「数据盘与 docker」 |
| 改坏了进不去后台 | [ops.md](ops.md) 的「备份与回滚」 |
| 根分区没扩满、swap 起不来 | [install.md](install.md) 的「根分区扩容」 |

## 配置文件与脚本位置

| 路径 | 作用 |
|---|---|
| `/etc/config/network` | 接口与网桥；`wan` 的协议、账号由 profile 切换写入 |
| `/etc/config/portmap` | 物理口 → 角色 映射（MAC / PCI 槽位） |
| `/etc/config/wanprofile` | 站点 profile（校园 / 家用 / 临时） |
| `/etc/config/wandetect` | 探针端点、投票阈值、探测间隔 |
| `/etc/config/campus-guard` | 防检测总开关与参数 |
| `/etc/config/swap` | swapfile 路径、大小、swappiness |
| `/etc/config/dockerd` | docker 全局配置（`data_root`） |
| `/etc/firewall.user` | LuCI「自定义规则」页；`campus-guard` 的规则段写在这里 |
| `/usr/sbin/portmap`、`/usr/sbin/wanmode`、`/usr/sbin/wandetect`、`/usr/sbin/campus-guard`、`/usr/sbin/swapctl` | 对应的命令行工具 |
| `/etc/config/uci-defaults-log.txt` | 首次启动脚本的执行日志 |

## 三条安全底线

1. **数据盘固件不碰**：不会自动格式化、不会自动挂载，分区与挂载都要手工做（见 ops.md）。
2. **WAN 出厂关闭**：`proto none` + `auto 0`，插上网线也不乱发包；用 `wanmode apply` 显式启用。
3. **防检测有代价**：相关能力可能违反校园网使用协议，后果由账号持有人承担，先读 [compliance.md](compliance.md)。
