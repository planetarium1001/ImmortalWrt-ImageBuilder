# 内置软件说明

本固件在 ImmortalWrt 25.12.2 默认包基础上追加下列组件。**来源**一列区分「官方源」与「第三方源」——
第三方源接入方式见 `shell/nikki-repo.sh`，构建失败时会自动回退内置 apk。

## 认证

| 包 | 用途 | 来源 |
|---|---|---|
| `minieap` | 锐捷 v3/v4 客户端，实现 EAP-MD5 与锐捷扩展字段 | 官方源；上游 <https://github.com/updateing/minieap> |
| `luci-proto-minieap` | WAN 协议页，可视化配置账号与 `dhcp_type` | 官方源 |
| `luci-compat` | 上述协议处理器的 Lua 运行依赖 | 官方源 |
| `luci-i18n-minieap-zh-cn` | 中文界面 | 官方源 |

## 代理

| 包 | 用途 | 来源 |
|---|---|---|
| `nikki` | mihomo 透明代理控制器（REDIRECT/TPROXY，白名单模式） | **第三方源** <https://github.com/nikkinikki-org/OpenWrt-nikki> |
| `luci-app-nikki` | 订阅、规则、mixin 的 LuCI 界面 | 同上 |
| `mihomo-meta` | mihomo 内核（Meta 分支） | 同上；上游 <https://github.com/MetaCubeX/mihomo> |

> 官方 25.12.2 源不含 mihomo，因此必须接 nikki 自有 apk 源；导入公钥后才能通过签名校验。

## 容器

| 包 | 用途 | 来源 |
|---|---|---|
| `dockerd` / `docker` / `docker-compose` | 容器运行时 | 官方源；上游 <https://github.com/moby/moby> |
| `luci-app-dockerman` | 容器、镜像、网络、卷的图形管理 | 官方源；上游 <https://github.com/lisaac/luci-app-dockerman> |

## 存储与共享

| 包 | 用途 | 来源 |
|---|---|---|
| `luci-app-samba4` | SMB 共享 | 官方源；上游 <https://github.com/samba-team/samba> |
| `luci-app-minidlna` | DLNA 媒体服务 | 官方源；上游 <https://sourceforge.net/projects/minidlna/> |
| `luci-app-openlist` | 网盘聚合挂载 | 官方源；上游 <https://github.com/OpenListTeam/OpenList> |
| `luci-app-diskman` | 分区、格式化、挂载管理 | 官方源 |
| `luci-app-hd-idle` | 机械盘空闲休眠 | 官方源 |

## 系统工具与运维

| 包 | 用途 | 来源 |
|---|---|---|
| `luci-theme-argon` / `luci-app-argon-config` | 界面主题与其配置 | 官方源；上游 <https://github.com/jerrykuku/luci-theme-argon> |
| `luci-app-ttyd` | Web 终端 | 官方源；上游 <https://github.com/ttyd/ttyd> |
| `luci-app-filemanager` | Web 文件管理（可在线改配置文件） | 官方源 |
| `luci-app-commands` | 自定义命令按钮（可放 `netprofile home` / `netprofile status` 等一键按钮） | 官方源 |
| `luci-app-package-manager` | 25.12 的 apk 包管理界面 | 官方源 |
| `openssh-sftp-server` | SFTP 传输 | 官方源；上游 <https://github.com/openssh/openssh-portable> |
| `luci-app-nlbwmon` / `luci-app-vnstat2` / `luci-app-statistics` | 流量与系统统计 | 官方源 |
| `luci-app-watchcat` / `luci-app-autoreboot` | 链路看护、定时重启 | 官方源 |

## 网络与内核模块

| 包 | 用途 | 来源 |
|---|---|---|
| `kmod-tun` / `kmod-nft-tproxy` / `kmod-nft-socket` / `kmod-inet-diag` | 透明代理所需的内核能力 | 官方源 |
| `kmod-nf-nathelper-extra` | FullCone NAT 辅助 | 官方源 |
| `kmod-br-netfilter` | 桥接流量过防火墙 | 官方源 |
| `kmod-tcp-bbr` | BBR 拥塞控制 | 官方源 |
| `kmod-zram` / `zram-swap` | 压缩内存 swap | 官方源；上游 <https://github.com/torvalds/linux>（zram） |
| `ip-full` / `ethtool-full` / `conntrack` / `irqbalance` | 网络与中断调优 | 官方源 |
| `parted` / `sfdisk` / `e2fsprogs` / `fdisk` | 首启扩根分区 | 官方源 |

## 调试工具

| 包 | 用途 | 来源 |
|---|---|---|
| `htop` / `iftop` / `lsof` / `tmux` / `bash` / `jq` / `rsync` | 日常排障 | 官方源 |
| `tcpdump` / `iperf3` / `bind-dig` / `curl` / `ca-bundle` | 抓包、测速、DNS 与 HTTP 诊断 | 官方源 |
| `lm-sensors` / `pciutils` / `usbutils` / `smartmontools` / `nvme-cli` | 温度、PCI 设备、磁盘健康 | 官方源 |

## 站点切换

| 包 | 用途 | 来源 |
|---|---|---|
| `ppp` / `ppp-mod-pppoe` / `luci-proto-ppp` | 家用宽带拨号（改 WAN 协议启用） | 官方源；上游 <https://github.com/ppp-project/ppp> |

## 版本说明

- 包版本随 ImmortalWrt 25.12.2 官方源当日快照，不作为长期固定版本。
- 第三方源（nikki）版本由上游 feed 决定，构建时优先取源上最新版；源不可达则回退 `packages/` 内置 apk。
