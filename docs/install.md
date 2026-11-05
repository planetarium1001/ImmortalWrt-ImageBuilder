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

从构建产物的 Release 页面下载 `*squashfs-combined-efi.img.gz`（文件名里含机型标识 `n5105`）：

```sh
ls -lh *squashfs-combined-efi*.img.gz
gzip -t immortalwrt-*.img.gz && echo "压缩包完整"
shasum -a 256 immortalwrt-*.img.gz     # Linux 用 sha256sum，与发布页核对
```

后文统一用变量表示实际文件名（**按你下载到的名字改这一行**）：

```sh
IMG=immortalwrt-25.12.2-x86-64-generic-squashfs-combined-efi-n5105.img.gz
```

> 本固件只发布 squashfs 产物：根是只读 squashfs，写层在系统盘 p3 的 btrfs 子卷 `@overlay` 上。

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

镜像是一整块磁盘镜像（GPT + EFI 分区 p1 + squashfs 根分区 p2，p2 固定 512 MiB），必须**整盘写入**，不能拷成文件。

> 镜像里**只有 p1、p2 两个分区**：p3（btrfs 写层）由首启脚本在盘尾创建，故意不预置。
> 预置会让镜像分区表与盘上不一致，`sysupgrade` 判定布局改变后整盘覆写，p3 与数据全丢。

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

写层（`/overlay` 上的所有写入，包含全部 `/etc` 改动）从 p2 内部的临时 overlay 迁到 p3 的 btrfs 子卷，
这一步只能在启动早期（preinit）完成，所以**首次开机会自动重启一次**。两次开机各做一件事：

### 第一次开机：建 p3 并重启

| 顺序 | 脚本 | 做什么 |
|---|---|---|
| 1 | `/etc/uci-defaults/95-overlay-setup.sh` → `/usr/sbin/overlay-setup` | 在系统盘尾部建 p3（`btrfs`，label `wrt-overlay`）、建 `@overlay`/`@docker`/`@swap`/`@data` 四个子卷、给 `@docker`/`@swap` 置 NOCOW，然后 `sync` + 重启 |

这次开机只跑编号 `< 95` 的 uci-defaults（都是上游默认项），**配网、管理地址、swap 都还没生效**。

### 第二次开机：全部定制项生效

| 顺序 | 脚本 | 做什么 |
|---|---|---|
| 1 | `/etc/init.d/btrfs-subvols`（START=12） | 把 `@docker`→`/opt/docker`、`@swap`→`/swap`、`@data`→`/data` 挂上，随后 best-effort 调 `swapctl apply` 建 swapfile（**swap 的自启在这一步**） |
| 2 | `/etc/uci-defaults/98-campus-nft.sh` | 建防检测用的 `config include` 段 |
| 3 | `/etc/uci-defaults/99-custom.sh` | 端口角色（首个物理口 WAN、其余入桥，不重命名网卡）、管理地址（构建参数，缺省 `192.168.100.1`）、主机名、`netprofile` 默认档、docker 防火墙区域（swap 已在第 1 步做过，这里只在 `/swap` 已挂时补一次） |

两个日志：

```sh
logread -e overlay-setup                   # 第一次开机：建 p3/子卷的过程（成功时看这里）
cat /etc/config/overlay-setup.log          # 仅当首启**失败且没重启**时才有意义：此时 /etc 还在 p2 的临时 overlay 里
cat /etc/config/uci-defaults-log.txt       # 第二次开机：端口/管理地址/swap
```

> 为什么成功首启不能 `cat` 那个 log 文件：第一次开机的 `/etc` 位于 p2 内部的临时 overlay，
> extroot 生效后 fstools 直接切走、那份 overlay 不再被挂载 ⇒ 文件既看不见也拿不回来。
> 所以 `overlay-setup` 的关键事件同时写进内核日志（`logread` 可见），文件只在"没来得及重启"时有用。

确认写层真的落在 p3 上（第二次开机后）：

```sh
grep -E ' /(overlay|opt/docker|swap|data) ' /proc/mounts
# 期望四行都是 btrfs，设备指向 p3（nvme0n1p3 / sda3 这种带分区号的名字）
df -h /overlay                    # 期望接近整盘容量（p3 吃满剩余空间）
btrfs subvolume list /overlay     # 期望 4 个路径：@overlay @docker @swap @data
```

> 本固件**没有 `findmnt` / `lsblk`**（25.12 的镜像里不带），判断挂载点一律看 `/proc/mounts` 或用 `mount`。

> 没重启过、或重启后 `/proc/mounts` 里的 `/overlay` 还是那种 `overlayfs:/overlay` 的临时写层 ⇒ 写层没迁成，看第 8 节。

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

## 8. 容量与写层：现在不需要扩容了

老镜像（ext4 根）需要把整盘空间扩给根分区，**这一版不存在这一步**：

- p2（squashfs 根）固定 512 MiB 且**只读**——装多少软件都不会让它变大变小，扩它既无意义也不可能；
- 所有写入落在 p3 的 btrfs 子卷 `@overlay` 上，p3 是首启自动建到**盘尾**的，天然吃满整盘。

所以不存在「把分区和文件系统撑大」这回事，老文档里那套分区/文件系统扩容步骤全部作废。要判断空间，只看写层：

```sh
df -h /overlay            # 写层容量（≈ 整盘容量减去 p1+p2 的 544 MiB）
df -h /                   # 合并视图，和 /overlay 基本一致
btrfs filesystem usage /overlay   # 池子整体用量（四个子卷共享同一个池）
```

### 8.1 首启建 p3 失败怎么重跑

`overlay-setup` 是幂等的，直接重跑即可（已就绪时只会打印 `up-to-date` 并退出 0）：

```sh
/usr/sbin/overlay-setup --dry-run     # 先看它打算做什么，什么都不改
/usr/sbin/overlay-setup              # 真跑；成功后会自己 sync + 重启
cat /etc/config/overlay-setup.log     # 哪一步失败会写在最后几行
```

几条对症处理：

| 日志里的现象 | 含义 | 处理 |
|---|---|---|
| `找不到 label=wrt-overlay 的 btrfs 分区` | p3 还没建出来 / 还没重启生效 | 先跑一次 `/usr/sbin/overlay-setup`，再重启 |
| `找不到 sgdisk`（`sgdisk: not found`） | **`sgdisk` 与 `gdisk` 是两个不同的包**（gptfdisk 拆成 `gdisk`/`cgdisk`/`sgdisk`/`fixparts`），镜像只装了 `gdisk` | `apk update && apk add sgdisk`，再重跑 `/usr/sbin/overlay-setup`；新版镜像已同时装两个包 |
| `sgdisk -e ... 失败` | 盘上 GPT 损坏 | 按 [ops.md](ops.md) 第 5 节救砖；确认没有别的工具在改这张表 |
| `partx` 失败 / `p3 节点尚未出现，需要重启` | 内核没感知新分区表（无 udev，只靠 devtmpfs）；`partx -a` 必须带 `-n <p3>:<p3>`，否则会撞上已挂载的 p1/p2 而整条失败 | 直接 `reboot`：分区已在表里，重启后 `overlay-setup` 会自动接着往下走（再重启一次即就绪） |
| `根文件系统在整盘设备上` | 刷成了无分区表的镜像 | 换回正常镜像重刷 |

`overlay-setup` 失败时**不会**动 p2 里已有的临时写层，所以系统始终可用；uci-defaults 的语义是「返回非 0 就下次开机重试」，
所以失败后重启一次往往会自己接着做。

> 不要手工 `mkfs.btrfs`/`sgdisk` 去凑 p3：label 必须是 `wrt-overlay`、四个子卷名必须带 `@`，
> 这些约定写死在 `/etc/config/fstab`（这也是 preinit 唯一认的那一份）。

### 8.2 客户端能连上但没有外网？先看防火墙是否加载成功

如果「路由器自己 ping 得通、LAN/WiFi 客户端却上不了网」，第一件事是确认 fw4 的 ruleset 真的加载了：

```sh
nft list tables                      # 应当有 table inet fw4
nft list chain inet fw4 srcnat_wan   # 应当有 masquerade 或 fullcone 规则
fw4 print >/dev/null                 # 有报错就会打在这里
```

**看 `srcnat_wan`，不是 `srcnat`**：`srcnat` 里只有一条 `jump srcnat_wan`，真正的出网 NAT 在
`srcnat_wan`。wan 开了 IPv4 fullcone 时那条规则叫 `fullcone` 而不是 `masquerade`
（2026-11-05 真机输出：`meta nfproto ipv4 fullcone comment "!fw4: Handle wan IPv4 fullcone NAT srcnat traffic"`）——
两个名字**见到任一即算恢复**，别只认 `masquerade` 就判定失败。

`table inet fw4` 不存在 = 整份防火墙没加载 ⇒ **没有 NAT**，只有路由器自己能上网；同时 WAN 侧处于无防护状态，尽快修好。

判据再加强：`table inet fw4` 在、`srcnat_wan` 也有规则、客户端仍然上不了网时，看 campus 片段是否真的注入
（带 counter 说明转发确实在走）：

```sh
nft list chain inet fw4 mangle_forward | grep campus   # 应看到 ttl/hl 改写与 no leak，且 counter 在涨
```

已知的一种成因（v25.12.2 首版镜像，已在后续版本修复）：`/etc/config/firewall` 里 `config include` 段的
`type`/`path`/`position`/`chain` 被写成了带引号的值（`type=''nftables''`），fw4 解析失败后中止整份渲染。
现场修法（不需要重刷）：

```sh
for s in campus_ttl campus_noleak campus_natport campus_ntp campus_conncap; do
	for k in type position chain path enabled; do
		v=$(uci -q get "firewall.$s.$k") || continue
		uci set "firewall.$s.$k=$(printf '%s' "$v" | tr -d "\047\042")"
	done
done
uci commit firewall
/etc/init.d/firewall restart
nft list chain inet fw4 srcnat_wan | head    # 看到 masquerade 或 fullcone 就恢复了
```

## 9. 升级（sysupgrade）

默认路径会**保留 p3 与其中数据**，前提是镜像的分区表与盘上一致：

```sh
scp immortalwrt-*-squashfs-combined-efi-n5105.img.gz root@192.168.100.1:/tmp/

sysupgrade -T /tmp/immortalwrt-*-squashfs-combined-efi-n5105.img.gz   # 预演，只看不改
sysupgrade    /tmp/immortalwrt-*-squashfs-combined-efi-n5105.img.gz
```

预演时如果看到这一句，**先停下备份**：

```
Partition layout has changed. Full image will be written.
```

它的意思是「整盘覆写」——p3、`@docker`、`@swap`、`@data` 会一起没了。出现这句的典型原因：

- **换了 profile / 改过 `ROOTFS_PARTSIZE`**：本仓库已把根分区固定成 512 MiB 并去掉了尺寸选项，正常不会触发；
- 用了 `sysupgrade -p`（`SAVE_PARTITIONS=0`，强制整盘 dd）——刷机时**别带 `-p`**；
- p3 建好后被 `resize`/`move` 过，或分区表被第三方工具重写过。

其他约束：

- **p3 建好后不要再 resize / move**（包括用 `luci-app-diskman` 动分区表）。p3 的起止扇区一旦变化，下次升级就会判定布局改变。
- **别用 `luci-app-diskman` 改 `/etc/config/fstab`**：它可能改写掉 extroot 那一段，导致下次开机不挂 p3。
- `-n` 是「不保存配置」：会丢掉 `/etc` 下的一切（它们都在 `@overlay` 上），通常不要用。
- `-k` 不是「保留分区」，只是把已装包清单附进备份，与 p3 无关。
- 本固件**不含 `owut`**：它会用服务器重建的镜像覆盖系统，那个镜像不带本仓库的定制；升级请重跑流水线后按上面刷。

升级后自检（三条都应通过）：

```sh
grep -E ' /overlay ' /proc/mounts          # 仍是 btrfs
btrfs subvolume list /overlay              # 仍能看到 @overlay/@docker/@swap/@data
mount | grep -E '/opt/docker|/data'        # docker 与个人数据都还在
```

## 10. 恢复出厂

**`firstboot` / `jffs2reset` 在本固件无效**，别用：fstools 的恢复出厂只重置「未被挂载的 `rootfs_data`」，
而本固件把写层搬到了 p3，`rootfs_data` 根本没被挂载 —— 它们会报成功但什么都没删（账号、密钥、装过的包都还在）。

用本仓库自带的命令：

```sh
overlay-reset            # 只打印计划：会删什么、有多少条、当前写层是什么文件系统
overlay-reset --yes      # 真删：清空 /overlay/upper（含隐藏文件）→ sync → 重启 = 恢复出厂
```

- 清的是**系统层可写差异**（`/overlay/upper`）：配置、密钥、装过的包全部回到出厂状态；
- **不动** `@docker`、`@swap`、`@data`（容器数据、swapfile、个人文件保留）；
- 要连容器数据一起清，只能重刷镜像（整盘写入）。

重刷也是恢复出厂，且更彻底（连 p3 一起重建）：

```sh
gunzip -c 新镜像.img.gz | dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
```

## 11. 首次登录检查清单

```sh
ip -o link show | grep eth          # 看端口顺序
ip -br addr show                    # br-lan 是否 192.168.100.1/24
uci show network.wan.proto          # 应为 none（还没配认证）
uci show network.lan.ipaddr
grep -E ' /overlay ' /proc/mounts    # 应为 btrfs（写层已迁到 p3）
df -h /overlay && free -m
```

- [ ] 首启已经自动重启过一次（`/proc/mounts` 里 `/overlay` 是 btrfs）
- [ ] root 密码已设置
- [ ] 端口角色与机壳丝印对得上（见 [network.md](network.md)）
- [ ] `/overlay` 在 btrfs 子卷上，`@docker`/`@swap`/`@data` 都已挂载（第 5 节四条命令）
- [ ] 备份一份配置：`sysupgrade -b /tmp/config-$(date +%F).tar.gz`，再 `scp` 到电脑
