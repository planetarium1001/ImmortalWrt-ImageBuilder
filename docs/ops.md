# 运维：认证与地址、swap、写层与数据、恢复出厂与回滚

> 本页改的都是持久配置。**动手前先备份**，改完按每节的「验证」确认，再离开后台。

## 0. 先备份（每次动配置之前）

```sh
sysupgrade -b /tmp/cfg-$(date +%F).tar.gz     # 标准配置备份（/etc/config 与 /etc/sysupgrade.conf 登记的文件）
# 在电脑上取回：
scp root@192.168.100.1:/tmp/cfg-*.tar.gz .
```

单项快照与丢弃未提交的改动：

```sh
cp -a /etc/config/network /etc/config/network.bak
uci revert network dhcp firewall
```

## 0.5 场景切换（家 / 校）

```sh
netprofile status     # 看当前在哪套、每个受管键的实际值
netprofile home       # 回家：关防检测、IPv6 走上游默认、停用锐捷认证
netprofile            # 回 campus（默认）：NAT66 + 防检测 + 认证自启
```

两套配置各自记住你手改的受管键，切走再切回不丢；完整语义、防检测二档项的开启方法与真机实测步骤见[双 profile 手册](profile.md)。

> 本固件不含 `owut`。`owut upgrade` 会用服务器重建的镜像覆盖系统，那个镜像**不带**本仓库的 `netprofile`、`nicsync`、minieap init 与防检测片段（`sysupgrade` 只保留 `/etc` 配置），升级后会出现「后台能进、认证不自启、防检测消失」。要升级请重跑 GitHub Actions 重新构建刷机。

## 1. 认证与地址（minieap 原生配置）

认证只有一份配置：`/etc/minieap.conf`。改它不需要动任何脚本或 UCI，也不需要重刷。

```sh
vi /etc/minieap.conf          # 或 LuCI 文件管理器在线编辑
```

必填两项，其余保持注释即可：

```ini
username=你的账号
password=你的密码
nic=eth0
module=rjv3
```

改完重启认证：

```sh
/etc/init.d/minieap restart
logread -e minieap -f          # 实时看认证过程
```

**开机自启**已经配好（`/etc/init.d/minieap`），不需要额外 enable。

### 认证与地址是两件事

- **minieap 只做 802.1X 认证**，它不分配 IP，也不管理 IPv6。
- 地址由 WAN 接口的原生 `proto dhcp` 提供：认证放行后 netifd 自动取到地址、网关、DNS。
- IPv6 是否下发由网络侧决定，本固件不干预；内网终端的 IPv6 走 ULA + NAT66（见 [network.md](network.md)）。

### 终端手工调试

不启用服务、临时跑一次看输出：

```sh
/usr/sbin/minieap -u 账号 -p 密码 -n eth0 --module rjv3
```

成功后再把账号密码写进 `/etc/minieap.conf`，交给 init 脚本托管。

### 常见现象对照

| 现象 | 含义 | 处理 |
|---|---|---|
| 认证一直重试 | 账号/密码错或服务未开 | 用官方客户端先验证账号 |
| 认证成功但没有 IP | WAN 的 `auto` 为 0 | `uci set network.wan.auto=1; uci commit network; ifup wan` |
| 认证成功也拿到 IP，但上不了网 | 需要二次认证或 Portal | 按 [ruijie.md](ruijie.md) 处理 |
| 日志里看不到任何输出 | init 脚本因账号为空跳过 | 填好 `username` 后 `restart` |

## 3. swap（`swapctl`）

`/etc/config/swap` 描述一个 **swapfile**（不是 swap 分区），默认 4G，位置是 `@swap` 子卷上的 `/swap/swapfile`：

```sh
swapctl status               # 当前 swap 与内存
swapctl apply                # 按配置创建并启用（每次开机由 btrfs-subvols 自动跑；这里用于手动重试）
swapctl resize 8192          # 改成 8192MB：swapoff → 删旧文件 → 改配置 → 重建
```

`apply` 的动作：确认 `/swap` 已挂上（`@swap` 子卷）→ `df -m` 检查空间（不足则非 0 退出，**不建文件、不写 fstab**）→
在 btrfs 上校验/补齐 `chattr +C`（swapfile 必须 NOCOW、不压缩、无洞，否则内核拒绝）→ `fallocate`（失败回退 `dd`）建文件 →
`chmod 600` → `mkswap` → `swapon` **成功之后**才写 `/etc/fstab` 与 `/etc/sysctl.d/99-swappiness.conf`（`vm.swappiness=20`）；
任一步失败都会清掉半成品并非 0 退出。

注意：

- `@swap` 与 `@overlay`/`@docker`/`@data` 共享同一个 btrfs 池（见 4.5），空间不够时 `swapctl apply` 直接非 0 退出，不会留半成品。
  想先要一个小 swap 就 `swapctl resize 512`。
- 升到 8G 内存后不需要这么大：`swapctl resize 2048`，或把 `enabled` 设 `0` 后 `swapoff /swap/swapfile`。
- `zram` 开关是**生效**的：`swapctl apply` 在 `zram=1` 时 `enable` + `start` `/etc/init.d/zram`（`zram-swap`/`kmod-zram` 已打包）。
  `zram_percent` 目前只写在配置里，`swapctl` 不读它；要改压缩盘大小请在 `/etc/config/zram` 上调。
- swapfile 会持续写入系统盘；NVMe 耐久通常足够，但仍不建议把 `swappiness` 调高。

## 4. 数据盘、`/data` 与 docker 数据目录

固件**不会**自动分区、格式化或挂载任何数据盘（刻意为之，防误格式化）。唯一的例外是系统盘本身：
首启脚本会在**系统盘尾部**建一个 p3 并挂出 `/overlay`、`/opt/docker`、`/swap`、`/data`（见 [install.md](install.md) 第 5 节）。

### 4.1 认出数据盘

```sh
cat /proc/partitions
block info 2>/dev/null | head -30      # 有 block-mount 时看 UUID/标签/挂载点
```

系统盘（通常是 `nvme0n1`）**任何写操作都不要指向它**。数据盘常见为 `/dev/sda`，动手前用容量与分区表双重确认。

### 4.2 分区 + 格式化（会清空该盘）

```sh
fdisk /dev/sda
#   o               新建 DOS 分区表（盘上原有数据会丢）
#   n  p  1  回车 回车   一个分区占满全盘
#   w               写入
mkfs.ext4 -L data /dev/sda1
```

### 4.3 持久挂载

```sh
mkdir -p /mnt/data
block detect | uci import fstab          # 生成 fstab 条目（没有 block 命令就用 LuCI：系统 → 挂载点）
uci show fstab
uci set fstab.@mount[-1].target='/mnt/data'
uci set fstab.@mount[-1].options='noatime'
uci set fstab.@mount[-1].enabled='1'
uci commit fstab
block umount; block mount                 # 或直接 reboot
df -h /mnt/data
```

按标签挂载更稳（换 SATA 口/加盘不会错位）：把 `device` 改成 `/dev/disk/by-label/data`。

### 4.4 docker 数据：出厂就在 `@docker` 子卷上，**不需要迁移**

docker 的 `data_root` 是 `/opt/docker`，它由 `/etc/init.d/btrfs-subvols`（START=12）挂在 `@docker` 子卷上：
镜像层与本机容器都写在 p3，**不要**再往数据盘 `rsync`（旧版本那套迁移步骤已作废）。

```sh
command -v dockerd && /etc/init.d/dockerd status   # 构建时 include_docker=yes 才有 docker
grep -E ' /opt/docker ' /proc/mounts                # 期望设备指向 p3、类型 btrfs
docker info 2>/dev/null | grep -i 'docker root dir'  # 期望 /opt/docker
btrfs subvolume list /overlay | grep @docker        # 子卷在
```

为什么要单独一个子卷：

- `@docker` 的根目录带 `chattr +C`（NOCOW）：容器层写入量大且本身已压缩，关掉 COW/校验和能显著降低写放大；
- 与 `@overlay` 分开 ⇒ 清系统层（`overlay-reset`）或重装容器都不会互相牵连。

风险与边界：

- **`@docker` 的 NOCOW 没有校验和**：静默损坏发现不了，但容器镜像可以重拉，代价可接受。
- **`/opt/docker` 没挂上就别用 docker**：`btrfs-subvols` 失败时会记 ERROR 并返回非 0（不挂空目录），
  此时 `/proc/mounts` 里没有 `/opt/docker`；请先按 [install.md](install.md) 第 8.1 节修好 p3 再启动容器。
  否则容器会写进系统层 `@overlay`，把它写满（见 4.5）。
- 强烈不建议把 `data_root` 改到机械数据盘：随机 I/O 差，数据库类容器会明显变慢。swap 也一样，刻意留在系统盘（NVMe）上。

### 4.5 `/data` 与 `/mnt/data` 的分工（池子共享，注意连坐）

| 路径 | 在哪 | 放什么 |
|---|---|---|
| `/data` | 系统盘 p3 上的 `@data` 子卷（btrfs） | 个人数据、共享/下载目录、samba/minidlna 的内容 |
| `/mnt/data` | 你后来接的**外接数据盘**（4.1–4.3） | 大容量媒体库、备份；不受黄线容量约束 |

`@data` 的定位：

- 保留 CoW + 校验和（可以 `btrfs scrub start /overlay` 查出静默损坏），压缩沿用文件系统级的 `zstd:1`；
- **不加配额**。`@overlay`/`@docker`/`@swap`/`@data` 共用同一个 btrfs 池，所以：

> ⚠️ `@data`（或任何子卷）写满 = 整个池子满 = 系统层也 ENOSPC。btrfs 满盘后的恢复比 ext4 麻烦
> （需要留出空间做 balance / 删快照），不要把它当无底洞。大文件请放 `/mnt/data`。

自查：

```sh
btrfs filesystem usage /overlay     # 池子整体用量（四个子卷共享）
du -sh /data/* 2>/dev/null | sort -h | tail
```

## 5. 备份与回滚

### 5.1 四种「回滚」分清

| 层级 | 手段 | 影响范围 |
|---|---|---|
| 配置回滚 | `sysupgrade -r` 恢复备份 / 改回 `/etc/minieap.conf` | 只动配置，几秒生效 |
| 清系统层（恢复出厂） | `overlay-reset --yes` | 清空 `/overlay/upper`：配置/密钥/装过的包回到出厂；保留 `@docker`/`@swap`/`@data` |
| 固件回滚 | 重刷上一版 `*squashfs-combined-efi.img.gz` | 整盘覆盖，**数据全丢**（含 p3） |
| 救砖 | Live U 盘挂 p3 的 `@overlay` 改配置 | 只改文件，不重刷 |

> **本期没有快照**：`btrfs` 快照/回滚（`bsnap` 之类）不在本版范围，别指望「秒回滚」。
> 真要回退系统状态，能用的只有 `overlay-reset`（回出厂）、`sysupgrade -r`（回配置）和重刷。

### 5.2 配置备份与恢复

```sh
sysupgrade -b /tmp/cfg-$(date +%F).tar.gz
sysupgrade -r /tmp/cfg-2026-11-02.tar.gz          # 恢复
/etc/init.d/network reload; /etc/init.d/firewall reload
```

单项回滚：

```sh
uci set network.wan.proto='dhcp'; uci commit network; ifup wan
swapctl resize 2048                       # swap 调小
```

### 5.3 固件回滚（保留旧镜像）

电脑上同时保留当前版与上一版，文件名带日期：

```sh
ls -1 immortalwrt-*squashfs-combined-efi*.img.gz
```

回滚步骤与刷写完全相同（[install.md](install.md) 第 4 节）：Live 环境里 `gunzip -c 旧镜像.img.gz | dd of=/dev/nvme0n1`，重启。

`squashfs` 根没有 A/B 分区，**不能原地切版本**，只能整盘重刷。重刷会连 p3 一起重建 ⇒
`@overlay`（配置）、`@docker`（容器）、`@data`（个人文件）全部丢失，回滚前务必：

```sh
sysupgrade -b /tmp/cfg-$(date +%F).tar.gz     # 至少把配置带走
rsync -a /data/ /mnt/data/backup-$(date +%F)/  # 个人数据先挪到外接盘
```

### 5.4 改坏了进不去后台（救砖）

`eth1`–`eth3` 永远在 `br-lan` 里、LAN 是静态地址，所以绝大多数「配置写错」还能救：

1. 电脑网线直连 `eth1`/`eth2`/`eth3`，本机静态 `192.168.100.50/24`、网关 `192.168.100.1`，再访问。
2. 还不行就 Live U 盘（[install.md](install.md) 第 3 节）启动，挂 p3 的 `@overlay` 子卷改文件：

```sh
lsblk -o NAME,SIZE,FSTYPE          # 系统盘 = nvme0n1；p1 EFI、p2 squashfs（只读，改不了）、p3 btrfs
sudo mount -o subvol=@overlay /dev/nvme0n1p3 /mnt
sudo nano /mnt/upper/etc/config/network   # 例如把 lan.ipaddr 改回来、或把 wan.proto 改回 none 先保命
sudo umount /mnt
```

3. 配置在 `@overlay` 上分两层：`/mnt/upper/` 是改动（真源），`/mnt/` 根下是子卷根。
   只想回出厂，卸载后在该盘上清空 upper 即可，或进系统后跑 `overlay-reset --yes`（见 5.5）。

改完拔 U 盘重启。常见要改的：`network.lan.ipaddr`、`network.wan.proto`、`firewall` 的区域定义。

> 别去改 p2：squashfs 是只读镜像本身，改了下次升级也会被覆盖；`/etc/config/fstab`（extroot 那一段）
> 就在 p2 里，是 preinit 唯一认的那份，运行期改 `/etc/config/fstab` 不会影响开机挂载。

### 5.5 恢复出厂（`firstboot` / `jffs2reset` 已作废）

**`firstboot` / `jffs2reset` 在本固件无效**：fstools 的恢复出厂只重置「未被挂载的 `rootfs_data`」，
而本固件把写层搬到了 p3 的 `@overlay`，`rootfs_data` 压根没挂 ⇒ 它们会报成功，但账号/密钥/装过的包一条都不会删。

用 `overlay-reset`：

```sh
overlay-reset            # 预演：打印会删多少条、当前写层是什么文件系统
overlay-reset --yes      # 清空 /overlay/upper（含隐藏文件）→ sync → 重启 = 恢复出厂
```

- 清的是系统层可写差异：配置、密码、SSH 密钥、装过的包全部回到出厂；
- **不动** `@docker`/`@swap`/`@data`（容器数据、swapfile、个人文件保留）；
- 要连数据一起清，只能重刷镜像（整盘写入，p3 一起重建）。

## 6. 代理（nikki，出厂关闭）

```sh
uci show nikki.config | head            # enabled='0' 表示还没启用
# 在 LuCI「Nikki」页填订阅、确认规则后：
uci set nikki.config.enabled='1'
uci commit nikki
/etc/init.d/nikki restart
```

白名单清单在 `/etc/nikki/ruleset/proxy-whitelist.yaml`（按行加域名，文件管理器可编辑）；自定义策略写 `/etc/nikki/mixin.yaml`，订阅更新不会冲掉它。认证环境下建议先让认证跑通，再启用代理。

## 7. 日常维护命令

```sh
logread -e minieap -f               # 认证日志
logread -e firewall                 # fw4 reload 报错
/etc/init.d/network reload           # 改完 network 后
/usr/sbin/ipv6mode status            # 看当前 IPv6 模式
/etc/init.d/firewall reload          # 改完防火墙后
grep -E ' /(overlay|opt/docker|swap|data) ' /proc/mounts   # 四个挂载点是否都在（写层健康）
/etc/init.d/btrfs-subvols start      # 子卷掉线时重挂（幂等，已挂的会跳过）
logread -e overlay-setup              # 首启建 p3 的过程（成功时看这里）
cat /etc/config/overlay-setup.log     # 首启失败且未重启时看文件（extroot 生效后该文件不再可见）
cat /etc/config/btrfs-subvols.log     # 每次开机挂载子卷与 NOCOW 复核记录
btrfs filesystem usage /overlay       # 池子用量（四个子卷共享，写满会连坐）
uptime; free -m; df -h               # 资源三连
sensors 2>/dev/null | head -20       # 温度（lm-sensors）
for i in eth0 eth1 eth2 eth3; do ethtool "$i" 2>/dev/null | sed -n "s/.*Speed: /$i speed: /p"; done
```

软件包（25.12 用 apk）：

```sh
apk update
apk upgrade --available          # 不建议整批升；升完重启并复查认证与防火墙
```

每次改配置后往 `/root/changelog.txt` 追加一行（时间、改了什么、怎么回滚），下次排障能省半小时。
