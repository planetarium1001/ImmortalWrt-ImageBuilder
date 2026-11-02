# 运维：profile、防检测、swap、数据盘、回滚

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
uci revert network wanprofile campus-guard wandetect swap
```

## 1. 站点 profile 切换（`wanmode`）

`/etc/config/wanprofile` 里有三个 profile，只改 WAN，不动 LAN 与防火墙：

| profile | 出厂协议 | 用途 |
|---|---|---|
| `campus` | `minieap` | 校园网锐捷认证 |
| `home` | `dhcp` | 家里光猫已拨号 / 上级路由给地址 |
| `adhoc` | `dhcp` | 酒店、临时环境 |

```sh
wanmode list                 # 列出可用 profile
wanmode show                 # active=campus proto=minieap user=20230001
wanmode apply home           # 切家用
wanmode apply campus         # 切回校园
```

改字段（`set <name> <key> <value>`，值含空格要加引号）：

```sh
wanmode set campus username '20230001'
wanmode set campus password 'p@ss w0rd'
wanmode set campus dhcp_type '2'
wanmode set home proto 'pppoe'          # 想在家 PPPoE 拨号时
wanmode set home username '宽带账号'
wanmode set home password '宽带密码'
```

`wanmode apply` 实际做的事：写 `network.wan.proto`（及 `username`/`password`/`module`/`dhcp_type`/`auto=1`）→ `uci commit` → `ubus call network reload` → 打印 `applied <name> (<proto>)`。切到 `dhcp`/`pppoe` 时会先删掉 `wan.username`/`wan.password`，不会把校园网账号带过去。

验证与回滚：

```sh
ifstatus wan | grep -E '"up"|"proto"|address'
wanmode show
wanmode apply campus             # 出问题切回来（LAN 没动，切 profile 不会失联）
```

## 2. 防检测开关（`campus-guard`）

### 它就是一段防火墙规则

`/usr/sbin/campus-guard` 只做一件事：把带标记的 nft 规则写进 `/etc/firewall.user`（LuCI「网络 → 防火墙 → 自定义规则」可见可改），然后 reload 防火墙。

| UCI 参数 | 作用 | 说明 |
|---|---|---|
| `enabled` | 总开关 | `0` 时 `apply` 会**删除**规则段 |
| `ttl_clamp` | WAN 出向 IPv4 TTL 统一为 `<值>` | 设 `0` 关闭该条；默认 `64` |
| `block_leak` | 丢弃经 WAN 外发的服务发现/地址分配类报文 | `udp 67/68/137/138/1900/5353/547` + `255.255.255.255` |
| `wan_input` | 丢弃来自 WAN 的 ICMP 时间戳/掩码查询 | `drop` 生成该条，`accept` 不生成 |

`single_mac`、`spoof_hostname`、`log_drop` 目前只是配置文件里的保留字段，**规则段不读取**：单出口 MAC 由 WAN 区 `masq` 天然实现（所有终端共用 eth0 的 MAC），DHCP 指纹由 `/etc/config/dhcp` 里统一的 option 60/61 处理。

### 开 / 关 / 查看

```sh
campus-guard show                    # 只打印将写入的规则，不改任何文件（先看再动）
campus-guard status                  # enabled=... + 规则段是否存在

# 开启
uci set campus-guard.globals.enabled='1'
uci commit campus-guard
campus-guard apply                   # 写规则段 + reload 防火墙

# 关闭（完整回滚）
uci set campus-guard.globals.enabled='0'
uci commit campus-guard
campus-guard clear                   # 删规则段 + reload
```

`apply` 先删旧段再写新段，反复执行不会叠加；`clear` 只删标记段，不动你在 `/etc/firewall.user` 里自己写的规则。

```sh
sed -n '/^# BEGIN campus-guard/,/^# END campus-guard/p' /etc/firewall.user
```

生效验证：

```sh
campus-guard status
nft list chain inet fw4 mangle_forward 2>/dev/null | grep ttl
nft list chain inet fw4 forward 2>/dev/null | grep -E '1900|5353|68'
```

### 后果与风险（务必读完）

- **TTL 钳制**改掉所有经 WAN 外发的 IPv4 报文 TTL：`traceroute`/`mtr` 结果失真，个别按 TTL 判路径的服务异常。排查网络问题时先 `campus-guard clear`。
- **`block_leak` 只作用在转发链（forward）**，路由器自己发的 DHCP 不受影响；但 LAN 侧 DHCP 中继、跨 WAN 的 mDNS/DLNA 会被这条打断。
- 规则里的出口网卡名写死为 **`eth0`**。若 `portmap resolve` 显示 WAN 不是 `eth0`，规则不命中——要么把 WAN 挪回 `eth0`，要么改 `/etc/firewall.user` 里的接口名（同时改 `/usr/sbin/campus-guard`，否则下次 `apply` 会覆盖）。
- **合规风险**：这些能力可能违反校园网使用协议，先读 [compliance.md](compliance.md)。学校明确禁止共享接入时不要开。

## 3. swap（`swapctl`）

`/etc/config/swap` 描述一个 **swapfile**（不是 swap 分区），默认 4G，放在傲腾根分区：

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
- swapfile 落在傲腾上会持续写入；傲腾耐久远高于普通 TLC，但别把 `swappiness` 调高。

## 4. 数据盘与 docker 数据目录

固件**不会**自动分区、格式化或挂载任何数据盘（刻意为之，防误格式化）。500G 机械盘要自己接管。

### 4.1 认出数据盘

```sh
cat /proc/partitions
block info 2>/dev/null | head -30      # 有 block-mount 时看 UUID/标签/挂载点
```

16G 的 `nvme0n1` 是系统盘，**任何写操作都不要指向它**。500G 机械盘通常是 `/dev/sda`——容量对得上才动手。

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
- 机械盘随机 I/O 差，数据库类容器会明显变慢；swap 已经刻意留在傲腾上。

## 5. 备份与回滚

### 5.1 三种「回滚」分清

| 层级 | 手段 | 影响范围 |
|---|---|---|
| 配置回滚 | `sysupgrade -r` 恢复备份 / `wanmode apply` / `campus-guard clear` | 只动配置，几秒生效 |
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
campus-guard clear                        # 删防检测规则段
wanmode apply home                        # WAN 回 DHCP
swapctl resize 2048                       # swap 调小
uci set campus-guard.globals.enabled='0'; uci commit campus-guard
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

白名单清单在 `/etc/nikki/ruleset/proxy-whitelist.yaml`（按行加域名，文件管理器可编辑）；自定义策略写 `/etc/nikki/mixin.yaml`，订阅更新不会冲掉它。校园网环境下建议先让认证跑通，再启用代理。

## 7. 日常维护命令

```sh
logread -e minieap -f               # 认证日志
logread -e wandetect                # 探测日志（同时写 /var/log/wandetect.log）
logread -e firewall                 # fw4 reload 报错
/etc/init.d/network reload           # 改完 network / wanprofile 后
/etc/init.d/firewall reload          # 改完防火墙 / campus-guard 后
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
