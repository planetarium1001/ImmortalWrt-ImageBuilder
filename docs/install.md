# 刷写与首次启动

> ⚠️ 刷写会清空目标磁盘上的全部分区与数据，且不可撤销。开始前确认：目标盘就是要写入的系统盘，其他磁盘上的数据都已另存。

## 1. 前提与 BIOS 设置

| 项目 | 要求 |
|---|---|
| 目标盘 | M.2 NVMe 系统盘（容量任意），写入后整盘被覆盖 |
| 启动模式 | UEFI（不要 CSM / Legacy） |
| Secure Boot | **关闭**（本镜像未签名，开启会拒绝引导） |
| SATA 模式 | AHCI |
| U 盘 | ≥ 4G（装 Live 系统 + 镜像文件） |

建议顺手在 BIOS 里打开「来电自启（Restore AC Power Loss = Power On）」，掉电恢复后路由自己起来。

## 2. 下载与校验

从构建产物的 Release 页面下载 `*ext4-combined-efi.img.gz`（文件名里含 `n5105`，认准 `ext4-combined-efi`，别拿成 `squashfs`）：

```sh
ls -lh *ext4-combined-efi*.img.gz
gzip -t immortalwrt-*.img.gz && echo "压缩包完整"
shasum -a 256 immortalwrt-*.img.gz     # Linux 用 sha256sum，与发布页核对
```

后文统一用变量表示实际文件名（**按你下载到的名字改这一行**）：

```sh
IMG=immortalwrt-25.12.2-x86-64-generic-ext4-combined-efi-n5105.img.gz
```

## 3. 做启动 U 盘（三选一）

### 方式 A：balenaEtcher（Windows / macOS 图形界面）

1. 打开 Etcher → **Flash from file** 选 `$IMG`（`.img.gz` 可直接选，Etcher 会自己解压）。
2. **Select target** 只勾 U 盘，逐字核对容量与盘符。
3. **Flash**，完成后拔插一次。

### 方式 B：`dd`（Linux / macOS 命令行）

Linux：

```sh
lsblk -o NAME,SIZE,MODEL,TRAN     # 确认 U 盘是 /dev/sdX，别选成 nvme0n1
sudo dd if="$IMG" of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync
```

macOS（U 盘是 `/dev/diskN`，原始设备用 `rdiskN` 更快）：

```sh
diskutil list                              # 记下 U 盘的 diskN
diskutil unmountDisk /dev/diskN
sudo dd if="$IMG" of=/dev/rdiskN bs=4m status=progress
sync
diskutil eject /dev/diskN
```

> `dd` 没有二次确认，`of=` 写错就是把这台电脑那块盘抹了。执行前把 `lsblk`/`diskutil list` 的输出拍照留证。

### 方式 C：Ventoy

Ventoy 适合「一只 U 盘同时放 Live 系统和固件镜像」，注意两点：

1. Ventoy 数据分区里放**解压后的 `.img`**（`gunzip -k "$IMG"`），放 `.img.gz` 也行，但启动后在 Live 系统里要自己解压。
2. Ventoy 直接用「img 模式」引导这个镜像时，系统运行在内存/虚拟盘上，**改动重启即丢**，只适合验证硬件能否点亮。要真正写入系统盘，请照第 4 节在 Live 环境里用 `dd` 写盘。

## 4. 写入系统盘（推荐流程）

镜像是一整块磁盘镜像（含 GPT + EFI 分区 + ext4 根），必须**整盘写入**，不能拷成文件。

1. U 盘启动后进 Live 系统（Ventoy 里选任意 Linux Live ISO，或方式 A/B 做好的镜像 U 盘本身）。
2. 找到镜像文件和目标盘：

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL          # 按容量与型号确认目标盘，通常是 /dev/nvme0n1
sudo nvme list                            # 装了 nvme-cli 时用它二次确认型号
```

3. 整盘写入（镜像在 Ventoy 数据分区时，先挂载它，路径按实际情况改）：

```sh
sudo gunzip -c /media/*/immortalwrt-*.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sync
```

4. 关机、拔掉 U 盘、从系统盘启动（BIOS 里把 `UEFI: <磁盘型号>` 调到第一启动项）。

## 5. 首次启动会做什么

首启脚本 `/etc/uci-defaults/99-custom.sh` 只跑一次（成功后自删），依次做：

| 步骤 | 说明 |
|---|---|
| 扩根分区 | `parted resizepart` + `resize2fs`，只动根分区（feed 里没有 `growpart`，所以走 parted/sfdisk） |
| 端口角色 | `/etc/init.d/portmap boot`：按 PCI 槽位顺序重命名为 `eth0`–`eth3` |
| 管理地址 | 写 `network.lan.ipaddr`（构建时填的 `custom_router_ip`，默认 `192.168.100.1`） |
| WAN 关闭 | `wan.auto=0`、`wan6.auto=0`，避免无网阶段乱发包 |
| 主机名/时间 | `n5105-router` + 安卓 TV 时间服务器映射 |
| 关闭 EEE | 逐个 `ethX` 执行 `ethtool --set-eee eee off`（i226 稳定性基线） |
| swap | `swapctl apply`，按 `/etc/config/swap` 建 4G swapfile（根分区没扩容时会失败，属正常） |

看结果：

```sh
cat /etc/config/uci-defaults-log.txt
df -h /                # 根分区是否已撑满整个系统盘
free -m                # swap 是否起来了
```

## 6. 进后台（此时还没有外网）

三条路，任选：

**A. 直连网线（最省事）**：电脑网线插 eth1 / eth2 / eth3，电脑用 DHCP 自动取址（会拿到 `192.168.100.100–199`），浏览器开 `http://192.168.100.1`。

**B. 经 AX3000T 的 WiFi**：eth1 接 AX3000T 上联口（AP 模式，见 [network.md](network.md)），电脑连它的 WiFi，再开 `http://192.168.100.1`。

**C. 电脑设静态地址**：DHCP 没起来时，把电脑设成 `192.168.100.50/24`、网关 `192.168.100.1`，再访问。

登录：用户名 `root`，**出厂密码为空**（首次进 LuCI 会被要求设置密码，或 SSH 里直接 `passwd`）。

```sh
ssh root@192.168.100.1
passwd                              # 第一件事：设密码
apk --version                       # 25.12 用 apk 管包，不是 opkg
```

> `ssh` 被拒说明 `dropbear` 没起来或密码已设过；用 LuCI 的 ttyd（系统 → 终端）或显示器 + 键盘登录。

## 7. 接线顺序（重要）

1. 先只接 LAN，进后台、设密码、配好认证账号（[ruijie.md](ruijie.md)）。
2. 再把锐捷认证网络网线插 **eth0**。
3. 编辑 `/etc/minieap.conf` 填账号密码，然后 `/etc/init.d/minieap restart`。

WAN 出厂是 `proto none` + `auto 0`：**插上网线也不会自己发包**，所以不会因为「先插了认证网络」而失联。

## 8. 根分区扩容（自动失败时手工做）

首启会自动扩，扩完 `df -h /` 应该接近整盘容量。如果没扩成功（例如分区表异常），手工执行：

检查：

```sh
df -h /                      # 只有 ~2G 说明自动扩容没生效
parted -l                    # 确认分区号（通常根是 2，1 是 EFI）
cat /proc/partitions          # 镜像里没有 lsblk/blkid，用这个看分区大小
block info 2>/dev/null | head -20
```

手工扩容（以 `/dev/nvme0n1` + 分区 2 为例，**只动根分区，别碰分区 1 的 EFI**）：

```sh
fdisk /dev/nvme0n1
# 交互里依次：
#   p            打印分区表，记下分区 2 的 Start 扇区
#   d  2         删除分区 2 的表项（不动数据）
#   n  2         新建分区 2；First sector 必须填上面记下的同一个值；Last sector 直接回车用满全盘
#   （提示 "Partition #2 contains a ext4 signature" 时选 N，不要删签名）
#   w            写入
reboot
```

重启后扩文件系统：

```sh
resize2fs /dev/nvme0n1p2
df -h /                      # 应该接近 14G
```

风险与回滚：

- 起始扇区填错 = 根分区偏移改变 = **系统起不来**。动手前把 `fdisk -l` 输出拍照/抄下来。
- 起不来时按 [ops.md](ops.md) 的「备份与回滚」用 Live U 盘救。
- 扩完之后再执行一次 swap：`swapctl apply`（4G swapfile 需要空间）。

## 9. 首次登录检查清单

```sh
ip -o link show | grep eth          # 看端口顺序
ip -br addr show                    # br-lan 是否 192.168.100.1/24
uci show network.wan.proto          # 应为 none（还没配认证）
uci show network.lan.ipaddr
df -h / && free -m
```

- [ ] root 密码已设置
- [ ] 端口角色与机壳丝印对得上（见 [network.md](network.md)）
- [ ] 根分区已扩容（否则先别开 docker）
- [ ] 备份一份配置：`sysupgrade -b /tmp/config-$(date +%F).tar.gz`，再 `scp` 到电脑
