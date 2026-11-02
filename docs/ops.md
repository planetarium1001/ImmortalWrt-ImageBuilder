# 运维：认证与地址、swap、数据盘、回滚

> 本页改的都是持久配置。**动手前先备份**，改完按每节的「验证」确认，再离开后台。

## 0. 先备份（每次动配置之前）

```sh
sysupgrade -b /tmp/cfg-$(date +%F).tar.gz     # OpenWrt 标准配置备份（含 /etc/config、/etc/firewall.user）
# 在电脑上取回：
scp root@192.168.100.1:/tmp/cfg-*.tar.gz .
```

单项快照与丢弃未提交的改动：

```sh
cp -a /etc/config/network /etc/config/network.bak
uci revert network minieap wandetect swap
```

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

`/etc/config/swap` 描述一个 **swapfile**（不是 swap 分区），默认 4G，放在系统盘根分区：

```sh
swapctl status               # 当前 swap 与内存
swapctl apply                # 按配置创建并启用（首启已自动跑过一次）
swapctl resize 8192          # 改成 8192MB：swapoff → 删旧文件 → 改配置 → 重建
```

`apply` 的动作：`fallocate`（失败回退 `dd`）建文件 → `chmod 600` → `mkswap` → `swapon` → 写 `/etc/sysctl.d/99-swappiness.conf`（`vm.swappiness=20`）→ 往 `/etc/fstab` 追加一行。

注意：

- 根分区没扩容时 4G 建不出来，`swapon` 会失败。先按 [install.md](install.md) 第 8 节扩容，或先 `swapctl resize 512`。
- 升到 8G 内存后不需要这么大：`swapctl resize 2048`，或把 `enabled` 设 `0` 后 `swapoff /swapfile`。
- `/etc/config/swap` 里的 `zram` / `zram_percent` 当前**未被 `swapctl` 读取**，本固件也没有打包 `zram-swap`。想要压缩内存要自己装：`apk update && apk add zram-swap`。
- swapfile 会持续写入系统盘；NVMe 耐久通常足够，但仍不建议把 `swappiness` 调高。

## 4. 数据盘与 docker 数据目录

固件**不会**自动分区、格式化或挂载任何数据盘（刻意为之，防误格式化）。数据盘需自行接管。

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

### 4.4 把 docker 数据搬过去

```sh
command -v dockerd && /etc/init.d/dockerd status   # 构建时 include_docker=yes 才有 docker

/etc/init.d/dockerd stop
mkdir -p /mnt/data/docker
rsync -a /opt/docker/ /mnt/data/docker/            # 出厂 data_root 是 /opt/docker
uci set dockerd.globals.data_root='/mnt/data/docker'
uci commit dockerd
/etc/init.d/dockerd start
docker info 2>/dev/null | grep -i 'docker root dir'
```

风险：

- 改了 `data_root` 旧镜像/容器不会自动跟过来，必须先 `rsync` 再切，否则 docker 当空环境处理。
- 数据盘没挂上就启动 docker，容器会把根分区写满。确认 `fstab` 条目 `enabled=1`，开机顺序由 block-mount 早于 dockerd（START=99）保证。
- 机械盘随机 I/O 差，数据库类容器会明显变慢；swap 刻意留在系统盘（NVMe）上。

## 5. 备份与回滚

### 5.1 三种「回滚」分清

| 层级 | 手段 | 影响范围 |
|---|---|---|
| 配置回滚 | `sysupgrade -r` 恢复备份 / 改回 `/etc/minieap.conf` | 只动配置，几秒生效 |
| 固件回滚 | 重刷上一版 `*ext4-combined-efi.img.gz` | 整盘覆盖，**数据全丢** |
| 救砖 | Live U 盘挂根分区改配置 | 只改文件，不重刷 |

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
ls -1 immortalwrt-*ext4-combined-efi*.img.gz
```

回滚步骤与刷写完全相同（[install.md](install.md) 第 4 节）：Live 环境里 `gunzip -c 旧镜像.img.gz | dd of=/dev/nvme0n1`，重启。ext4 单分区根没有 A/B 分区，**不能原地切版本**，只能整盘重刷。

### 5.4 改坏了进不去后台（救砖）

`eth1`–`eth3` 永远在 `br-lan` 里、LAN 是静态地址，所以绝大多数「配置写错」还能救：

1. 电脑网线直连 `eth1`/`eth2`/`eth3`，本机静态 `192.168.100.50/24`、网关 `192.168.100.1`，再访问。
2. 还不行就 Live U 盘（[install.md](install.md) 第 3 节）启动，挂载根分区改文件：

```sh
lsblk -o NAME,SIZE,FSTYPE          # 根分区 = nvme0n1p2（ext4），p1 是 16M 的 EFI
sudo mount /dev/nvme0n1p2 /mnt
sudo nano /mnt/etc/config/network   # 例如把 lan.ipaddr 改回来、或把 wan.proto 改回 none 先保命
sudo umount /mnt
```

改完拔 U 盘重启。常见要改的：`network.lan.ipaddr`、`network.wan.proto`、`firewall` 的区域定义。

> **恢复出厂**：本固件是 ext4 单分区根，没有 squashfs 只读层，`firstboot` 那套不适用；恢复出厂 = 重刷镜像。

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
logread -e wandetect                # 探测日志（同时写 /var/log/wandetect.log）
logread -e firewall                 # fw4 reload 报错
/etc/init.d/network reload           # 改完 network 后
/etc/init.d/firewall reload          # 改完防火墙后
/etc/init.d/wandetect restart        # 探测服务（procd 托管）
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
