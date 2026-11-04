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
| 文件系统 | 新增 ext4 根（上游 squashfs 产物并存，实际刷写用 ext4），根分区固定 2G |
| 端口 | 按 MAC / PCI 槽位固定角色，不依赖内核枚举顺序 |
| 认证 | 内置 minieap（锐捷 v3），WAN 多探针投票后按需触发 |
| IPv6 | 三态开关 `nat66`/`native`/`off`，每个模式各自记忆调整 |
| 代理 | nikki（mihomo）走上游 apk 源，白名单透明代理 |
| 认证 | `/etc/minieap.conf` 由首次手动认证生成，`/etc/init.d/minieap` 开机自启 |
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
   - 认证与拨号都不在构建期配置：认证改 `/etc/minieap.conf`，宽带账号改 WAN 的 UCI（见[运维手册](docs/ops.md)）
4. 从 Release 下载 `immortalwrt-25.12.2-n5105-x86-64-generic-ext4-combined-efi.img.gz`（机型标识在前缀，`ext4-combined-efi` 在尾部）。
5. 按 [安装手册](docs/install.md) 刷写并进入后台。

## 构建产物与磁盘布局

每次构建产出两个镜像，按需选一个刷写：

| 产物 | 根文件系统 | 可写空间在哪 | 适用场景 |
|---|---|---|---|
| `*-ext4-combined-efi.img.gz` | ext4（整盘可写） | 根分区本身 | 推荐，需要自由安装软件、改系统文件 |
| `*-squashfs-combined-efi.img.gz` | squashfs（只读）+ overlay | `/overlay` 分区 | 需要恢复出厂能力，系统文件不会被改坏 |

两者分区布局相同（引导分区 + 根分区），区别只在根分区的文件系统类型。

### `/` 与 `/overlay` 的关系

- **ext4 镜像**：`/` 就是根分区，没有独立的 `/overlay`。扩容扩的是 `/`，`df -h /` 即整盘可用空间。
- **squashfs 镜像**：`/` 是只读 squashfs 底层，所有写入落到 `/overlay` 分区，由 overlayfs 合并呈现；`df -h /` 显示的其实是 `/overlay` 的容量。

因此：

- ext4 镜像 → 扩 `/`，扩完 `/` 就是整盘；
- squashfs 镜像 → 扩 `/overlay`；`/` 只读且 squashfs 不支持在线扩容，不需要、也无法扩。

**扩 `/overlay` 不会让 `/` 不够用。** squashfs 的 `/` 是固定大小的只读基础层，安装的软件与改动全部写入 `/overlay`；判断空间够不够看 `df -h /` 即可。

镜像里的根分区固定 **2G**，固件不再自动扩容。需要更大空间时手工扩一次（ext4 镜像）：

```sh
parted -s /dev/nvme0n1 resizepart 2 100%
partx -u /dev/nvme0n1
resize2fs /dev/nvme0n1p2
```

squashfs 镜像则扩 `/overlay` 所在分区后 `resize.f2fs`/`resize2fs`。

## 写入后开机

镜像写入系统盘并首次开机后，下列动作自动完成，无需交互：

1. **枚举物理网口**：读出所有真实网口，第一个作为 WAN，其余全部加入 `br-lan`；不重命名网卡，写进配置的就是真实名字。
2. **写入管理地址**：取构建参数 `custom_router_ip`，缺省 `192.168.100.1`。
3. **WAN 自动取地址**：沿用上游默认，认证放行后 netifd 的 DHCP 客户端立即拿到地址。
4. **应用 IPv6 模式**：默认 `nat66`，可一键切 `native` / `off`。
5. **服务就绪**：启用 ttyd、SSH、swap、并补齐 docker 区域（若装了容器）。

日志写入 `/etc/config/uci-defaults-log.txt`；脚本执行成功后自删，不会重复运行。完成后浏览器打开 `http://192.168.100.1`，用户 `root`，密码为空。

## 注意事项

- **先接 LAN、后接 WAN**：首次启动只插 `eth1`（接 AP 或电脑），配好认证参数后再把上级网线插入 `eth0`。
- **首次登录立即改密码**：出厂无密码，`passwd` 设置后再接入网络。
- **上级设备关闭 DHCP**：AP 需工作在 AP / 桥接模式，否则两个 DHCP 抢答，表现为能连 WiFi 但无法上网。
- **管理网段可能撞段**：`192.168.100.0/24` 与部分光猫维护地址重叠；撞段时按[安装手册](docs/install.md)手工改址。
- **刷写不可逆**：写入会清空目标盘全部分区，刷前确认盘符并备份数据。
- **根分区只有 2G**：装大量容器前先按上文手工扩容，否则 `/` 会先满。
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
- 存储与分区：parted、sfdisk、e2fsprogs、zram-swap
- 拨号：ppp / ppp-mod-pppoe（改 WAN 接口协议启用）

## 文档

- [安装与首次启动](docs/install.md)：写盘、首启动作、进入后台
- [锐捷认证](docs/ruijie.md)：minieap 配置与排障
- [网络与端口](docs/network.md)：端口角色、AP 模式、NAT66
- [内置软件](docs/packages.md)：追加的软件、用途与上游链接
- [日常运维](docs/ops.md)：认证与地址、swap、docker、回滚
- [使用条款与责任](docs/compliance.md)：合规边界
- [仓库说明](docs/README.md)：手册总览

## 目录结构

- `x86-64/`：目标配置、构建脚本、机型手册
- `files/`：随固件打包的配置与首启脚本
- `shell/`：第三方包准备、代理源接入、验收测试
- `.github/workflows/`：构建与清理

## 许可与致谢

- 许可：[GPL-2.0](LICENSE)
- 致谢：[wukongdaily/AutoBuildImmortalWrt](https://github.com/wukongdaily/AutoBuildImmortalWrt)（构建框架）、[ImmortalWrt](https://github.com/immortalwrt/immortalwrt)（固件本体）、[updateing/minieap](https://github.com/updateing/minieap)（锐捷认证）、[nikkinikki-org/OpenWrt-nikki](https://github.com/nikkinikki-org/OpenWrt-nikki)（透明代理）

## 免责

固件按现状提供，不附带担保。刷写不可逆；网络使用须遵守所接入网络的使用条款，账号与使用责任在持有人。详见[合规说明](docs/compliance.md)。
