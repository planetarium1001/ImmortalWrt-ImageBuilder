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
| 文件系统 | squashfs 只读根（根分区固定 512 MiB）+ btrfs 写层：`/overlay` 在系统盘 p3 的 `@overlay` 子卷上，`@docker`/`@swap`/`@data` 各占一个子卷 |
| 端口 | 首个物理口为 WAN，其余入桥；按 PCI `bus:dev.fn` 数值序判定，不重命名网卡 |
| 认证 | 内置 minieap（锐捷 v3），campus profile 下自动 `enable` + `start` |
| 场景切换 | `netprofile`（默认 campus）↔ `netprofile home`，两套配置各自记住手改内容 |
| IPv6 | campus 默认 NAT66（下游不暴露独立地址）；home 走上游默认 |
| 防检测 | fw4 的 `config include` 承载：TTL/HopLimit 归一、发现协议兜底；二档默认关 |
| 代理 | nikki（mihomo）走上游 apk 源，白名单透明代理 |
| 运维 | 参数文件与开关均可在 LuCI 内修改，无需重刷 |

## 快速开始

1. Fork 本仓库。
2. Actions 中选择 **Build N5105 x86_64 25.12.x**，Run workflow。（固件不含 `owut`：它重建的镜像不带本仓库定制，升级请重跑本流水线）
3. 填写参数：
   - `luci_version`：`25.12.2`（workflow 默认值即为该版本）
   - `custom_router_ip`：管理地址，默认 `192.168.100.1`
   - `include_docker`：按需
   - `enable_store`：按需
   - 认证与拨号都不在构建期配置：认证改 `/etc/minieap.conf`，宽带账号改 WAN 的 UCI（见[运维手册](docs/ops.md)）
4. 从 Release 下载 `immortalwrt-25.12.2-n5105-x86-64-generic-squashfs-combined-efi.img.gz`（机型标识在前缀，`squashfs-combined-efi` 在尾部）。
5. 按 [安装手册](docs/install.md) 刷写并进入后台。

## 构建产物与磁盘布局

每次构建只产出一个镜像，直接整盘写入：

| 产物 | 根文件系统 | 写层在哪 |
|---|---|---|
| `*-squashfs-combined-efi.img.gz` | squashfs（只读，固定 512 MiB） | 系统盘 p3 的 btrfs 子卷 `@overlay` |

写盘后盘上的布局（p3 由**首启**创建，镜像里只有 p1/p2）：

| 分区 | 大小 | 内容 |
|---|---|---|
| p1 | 32 MiB | EFI / GRUB 引导 |
| p2 | 512 MiB | squashfs 根（只读，`/rom`） |
| p3 | 盘尾全部剩余（128G 盘约 126 GiB） | btrfs，label `wrt-overlay`：`@overlay`→`/overlay`、`@docker`→`/opt/docker`、`@swap`→`/swap`、`@data`→`/data` |

### `/` 与 `/overlay` 的关系

- `/` 是只读 squashfs 底层 + `@overlay` 写层合并后的视图，所有写入都落到 `@overlay`；
- 装软件、改 `/etc`、放 docker 层都吃 `@overlay` 的空间，`df -h /overlay` 就是可用容量；
- p3 建好后**吃满整盘**，所以没有「扩容」这一步：既不需要、也不要手工动分区表
  （p3 被 resize/move 过，下次升级就会判定布局改变而整盘覆写）。

> 为什么 p3 不预置进镜像：镜像里的 p3 尺寸构建期就冻结了，与盘上「剩余空间」永不相等，
> `sysupgrade` 会判定分区布局改变并整盘覆写，p3 与数据每次升级全丢。镜像保持 stock 两分区
> （p1+p2）时，默认升级路径逐分区写，p3 一个字节都不动。

## 写入后开机

镜像写入系统盘后**首次开机会自动重启一次**（写层要从 p2 内部的临时 overlay 迁到 p3 的 btrfs 子卷，
这一步只能在启动早期完成），重启后下列动作自动完成，无需交互：

1. **建写层**（第一次开机）：在系统盘尾部建 p3、建四个子卷、给 `@docker`/`@swap` 置 NOCOW，然后重启。
2. **枚举物理网口**（第二次开机）：读出所有真实网口，第一个作为 WAN，其余全部加入 `br-lan`；不重命名网卡，写进配置的就是真实名字。
3. **写入管理地址**：取构建参数 `custom_router_ip`，缺省 `192.168.100.1`。
4. **WAN 自动取地址**：沿用上游默认，认证放行后 netifd 的 DHCP 客户端立即拿到地址。
5. **应用 IPv6 模式**：默认 `nat66`，可一键切 `native` / `off`。
6. **服务就绪**：启用 ttyd、SSH、swap（`/swap/swapfile`，在 `@swap` 子卷上），并补齐 docker 区域（若装了容器）。

日志：`/etc/config/overlay-setup.log`（建 p3 的过程）、`/etc/config/uci-defaults-log.txt`（端口/管理地址/swap）；
脚本执行成功后自删，不会重复运行。完成后浏览器打开 `http://192.168.100.1`，用户 `root`，密码为空。

## 注意事项

- **先接 LAN、后接 WAN**：首次启动只插 `eth1`（接 AP 或电脑），配好认证参数后再把上级网线插入 `eth0`。
- **首次登录立即改密码**：出厂无密码，`passwd` 设置后再接入网络。
- **上级设备关闭 DHCP**：AP 需工作在 AP / 桥接模式，否则两个 DHCP 抢答，表现为能连 WiFi 但无法上网。
- **管理网段可能撞段**：`192.168.100.0/24` 与部分光猫维护地址重叠；撞段时按[安装手册](docs/install.md)手工改址。
- **刷写不可逆**：写入会清空目标盘全部分区，刷前确认盘符并备份数据。
- **四个子卷共享一个池子且无配额**：`@overlay`（系统层）、`@docker`（容器）、`@swap`、`@data`（个人数据）共用 p3，
  `@data` 写满会让系统层也 ENOSPC（btrfs 满盘恢复麻烦）。大文件请放外接数据盘 `/mnt/data`。
- **恢复出厂用 `overlay-reset`**：`firstboot` / `jffs2reset` 在本固件**无效**（写层不在 `rootfs_data` 上），
  用 `overlay-reset --yes` 清系统层，或重刷镜像。`@docker`/`@data` 的数据不会被它清掉。
- **别用 `-p` 或改根分区尺寸升级**：会让 `sysupgrade` 整盘覆写，p3 与数据全丢。升级前先 `sysupgrade -T <镜像>` 预演。
- **代理默认关闭**：nikki 出厂 `enabled=0`，先让认证跑通再启用。
- **认证需手动初始化一次**：出厂 `/etc/minieap.conf` 为空，先按 [锐捷认证](docs/ruijie.md) 手动跑一次并加 `-w`。

## 内置软件

在 ImmortalWrt 官方源基础上追加，完整清单与上游链接见[内置软件说明](docs/packages.md)。

- 认证：minieap（锐捷 v3）+ LuCI 协议页
- 代理：nikki（mihomo 内核），走 nikki 自有 apk 源
- 容器：dockerd、docker-compose、luci-app-dockerman
- 共享：samba4、minidlna、openlist、diskman、hd-idle
- 运维：argon 主题、ttyd、filemanager、commands、package-manager、nlbwmon、vnstat2、statistics、watchcat、autoreboot
- 网络：BBR、FullCone NAT、nft-tproxy/tun 内核模块、ip-full、ethtool-full、irqbalance
- 调试：htop、iftop、tcpdump、iperf3、bind-dig、lm-sensors、smartmontools、nvme-cli
- 存储与分区：btrfs-progs、gdisk、parted、sfdisk、e2fsprogs、chattr/lsattr、zram-swap
- 拨号：ppp / ppp-mod-pppoe（改 WAN 接口协议启用）

## 文档

- [安装与首次启动](docs/install.md)：写盘、首启重启与建 p3、进入后台、升级与恢复出厂
  （附录 B 是 Phase 1 可刷镜像的取产物 / 写盘 / 首启说明，实验路径）
- [锐捷认证](docs/ruijie.md)：minieap 配置与排障
- [网络与端口](docs/network.md)：端口分配、改口、AP 模式、NAT66
- [家/校双 profile](docs/profile.md)：`netprofile` 切换、防检测一档/二档、记忆机制
- [内置软件](docs/packages.md)：追加的软件、用途与上游链接
- [日常运维](docs/ops.md)：认证与地址、swap、docker、回滚
- [使用条款与责任](docs/compliance.md)：合规边界
- [仓库说明](docs/README.md)：手册总览

## 目录结构

- `x86-64/`：目标配置、构建脚本、机型手册
- `files/`：随固件打包的配置与首启脚本
- `shell/`：第三方包准备、代理源接入、验收测试
- `phase1/`：Phase 1（只读 btrfs 子卷根 + 独立写层）的构建与装机链，含 CI 可刷镜像入口
- `.github/workflows/`：固件构建、Phase 1 镜像构建、历史运行清理

## 许可与致谢

- 许可：[GPL-2.0](LICENSE)
- 致谢：[wukongdaily/AutoBuildImmortalWrt](https://github.com/wukongdaily/AutoBuildImmortalWrt)（构建框架）、[ImmortalWrt](https://github.com/immortalwrt/immortalwrt)（固件本体）、[updateing/minieap](https://github.com/updateing/minieap)（锐捷认证）、[nikkinikki-org/OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)（透明代理）

## 免责

固件按现状提供，不附带担保。刷写不可逆；网络使用须遵守所接入网络的使用条款，账号与使用责任在持有人。详见[合规说明](docs/compliance.md)。
