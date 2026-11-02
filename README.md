# N5105 四网口 i226 固件构建

面向单一硬件的 ImmortalWrt 固件构建仓库：**N5105 v5，4× Intel i226-V 2.5G，x86-64，UEFI**。

用途：锐捷认证接入、IPv4/IPv6 双栈分发、透明代理、容器与商店生态，可在不同网络环境间迁移使用。

## 与上游的关系

- 本仓库 fork 自 [wukongdaily/AutoBuildImmortalWrt](https://github.com/wukongdaily/AutoBuildImmortalWrt)，沿用其 ImageBuilder + GitHub Actions 构建方式。
- 固件本体由 [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) 官方 ImageBuilder 生成，版本 `25.12.2`，内核 `6.12`。
- 上游 README 原样保留于 [README.upstream.md](README.upstream.md)；上游第三方软件清单见 [PACKAGES.upstream.md](PACKAGES.upstream.md)。
- 本项目为第三方定制，**与 ImmortalWrt 官方无关**。由本项目定制产生的问题请勿反馈给 ImmortalWrt 官方或上游仓库。

## 相对上游的改动

| 方向 | 改动 |
|---|---|
| 目标 | 移除其余 9 个平台目录与全部非 x86-64 workflow，只保留本机型 |
| 文件系统 | 新增 ext4 根（上游 squashfs 产物并存，实际刷写用 ext4），首启自动扩满系统盘 |
| 端口 | 按 MAC / PCI 槽位固定角色，不依赖内核枚举顺序 |
| 认证 | 内置 minieap（锐捷 v3），WAN 多探针投票后按需触发 |
| IPv6 | ULA 前缀 + `masq6`（NAT66），终端地址对上级网络不可见 |
| 防护 | `ruijie-guard` 规则集，可整体启用 / 撤销 |
| 代理 | nikki（mihomo）走上游 apk 源，白名单透明代理 |
| 迁移 | 多站点 profile 一键切换（认证网络 / 家用 / 临时） |
| 运维 | 参数文件与开关均可在 LuCI 内修改，无需重刷 |

## 快速开始

1. Fork 本仓库。
2. Actions 中选择 **Build N5105 x86_64 25.12.x**，Run workflow。
3. 填写参数：
   - `luci_version`：`25.12.2`（workflow 默认值即为该版本）
   - `custom_router_ip`：管理地址，默认 `192.168.100.1`
   - `profile`：`2G`（首启自动扩满整盘）
   - `include_docker`：按需
   - `enable_store`：按需
   - 拨号不在构建期配置：锐捷认证与家用 PPPoE 均由设备上的站点 profile 切换（见[运维手册](x86-64/docs/n5105/ops.md)）
4. 从 Release 下载 `immortalwrt-25.12.2-n5105-x86-64-generic-ext4-combined-efi.img.gz`（机型标识在前缀，`ext4-combined-efi` 在尾部）。
5. 按 [安装手册](x86-64/docs/n5105/install.md) 刷写并进入后台。

## 写入后开机

镜像写入系统盘并首次开机后，下列动作自动完成，无需交互：

1. **根分区扩满系统盘**：从 `/proc/mounts` 反查根设备并解析磁盘与分区号（兼容 `sda1` / `nvme0n1p2` / `mmcblk0p2`），`parted resizepart 100%` 扩分区，失败回退 `sfdisk`，随后 `resize2fs` 在线扩容并回读校验。系统盘容量任意，不绑定固定规格。
2. **网口绑定角色**：按 MAC / PCI 槽位把 `eth0` 定为 WAN，`eth1`–`eth3` 桥入 `br-lan`，与枚举顺序无关。
3. **写入管理地址**：取构建参数 `custom_router_ip`，缺省 `192.168.100.1`。
4. **WAN 保持关闭**：`proto none` + `auto 0`，不主动发送探测包。
5. **服务就绪**：启用 ttyd、SSH、dnsmasq、防火墙，并完成设备侧初始化。

日志写入 `/etc/config/uci-defaults-log.txt`；脚本执行成功后自删，不会重复运行。完成后浏览器打开 `http://192.168.100.1`，用户 `root`，密码为空。

## 注意事项

- **先接 LAN、后接 WAN**：首次启动只插 `eth1`（接 AP 或电脑），配好认证参数后再把上级网线插入 `eth0`。
- **首次登录立即改密码**：出厂无密码，`passwd` 设置后再接入网络。
- **上级设备关闭 DHCP**：AP 需工作在 AP / 桥接模式，否则两个 DHCP 抢答，表现为能连 WiFi 但无法上网。
- **管理网段可能撞段**：`192.168.100.0/24` 与部分光猫维护地址重叠；撞段时按[安装手册](x86-64/docs/n5105/install.md)手工改址。
- **刷写不可逆**：写入会清空目标盘全部分区，刷前确认盘符并备份数据。
- **请勿接入其余设备**：首次开机的扩容为程序自己判断，不建议接入不必要的硬盘、存储设备等，以免造成错误的格式化和数据损坏。
- **扩容期间勿断电**：首次开机扩容未完成即断电，根分区会停在镜像大小，需按文档手工 `resize2fs`。
- **代理默认关闭**：nikki 出厂 `enabled=0`，先让认证跑通再启用。

## 内置软件

在 ImmortalWrt 官方源基础上追加，完整清单与上游链接见[内置软件说明](x86-64/docs/n5105/packages.md)。

- 认证：minieap（锐捷 v3）+ LuCI 协议页
- 代理：nikki（mihomo 内核），走 nikki 自有 apk 源
- 容器：dockerd、docker-compose、luci-app-dockerman
- 共享：samba4、minidlna、openlist、diskman、hd-idle
- 运维：argon 主题、ttyd、filemanager、commands、package-manager、nlbwmon、vnstat2、statistics、watchcat、autoreboot
- 网络：BBR、FullCone NAT、nft-tproxy/tun 内核模块、ip-full、ethtool-full、irqbalance
- 调试：htop、iftop、tcpdump、iperf3、bind-dig、lm-sensors、smartmontools、nvme-cli
- 存储与分区：parted、sfdisk、e2fsprogs、zram-swap
- 拨号：ppp / ppp-mod-pppoe（由站点 profile 启用）

## 文档

- [安装与首次启动](x86-64/docs/n5105/install.md)：写盘、首启动作、进入后台
- [锐捷认证](x86-64/docs/n5105/ruijie.md)：minieap 配置与排障
- [网络与端口](x86-64/docs/n5105/network.md)：端口角色、AP 模式、NAT66
- [内置软件](x86-64/docs/n5105/packages.md)：追加的软件、用途与上游链接
- [日常运维](x86-64/docs/n5105/ops.md)：profile、防护开关、swap、docker、回滚
- [使用条款与责任](x86-64/docs/n5105/compliance.md)：合规边界
- [仓库说明](x86-64/docs/n5105/README.md)：手册总览

## 目录结构

- `x86-64/`：目标配置、构建脚本、机型手册
- `files/`：随固件打包的配置与首启脚本
- `shell/`：第三方包准备、代理源接入、验收测试
- `.github/workflows/`：构建与清理

## 许可与致谢

- 许可：[GPL-2.0](LICENSE)
- 致谢：[wukongdaily/AutoBuildImmortalWrt](https://github.com/wukongdaily/AutoBuildImmortalWrt)（构建框架）、[ImmortalWrt](https://github.com/immortalwrt/immortalwrt)（固件本体）、[updateing/minieap](https://github.com/updateing/minieap)（锐捷认证）、[nikkinikki-org/OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)（透明代理）

## 免责

固件按现状提供，不附带担保。刷写不可逆；网络使用须遵守所接入网络的使用条款，账号与使用责任在持有人。详见[合规说明](x86-64/docs/n5105/compliance.md)。
