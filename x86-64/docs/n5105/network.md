# 网络、端口与 IPv6

## 1. 端口角色

| `ethX` | 角色 | 说明 |
|---|---|---|
| `eth0` | WAN | 接认证网络墙口（或家里的光猫 / 上级路由） |
| `eth1` | LAN | 接 AX3000T 的上联口（AP 模式） |
| `eth2` | LAN | 预留（可直接接电脑 / NAS） |
| `eth3` | LAN | 预留 |

`eth1`–`eth3` 都在 `br-lan` 网桥里，三个口等价，随便插哪个都能进后台。

**别照机壳丝印猜 `ethX`**：x86 上 `eth0..eth3` 由内核 PCI 探测顺序决定。想确认哪个物理口是哪个名字，一次只插一根网线，对比 `Link detected`：

```sh
for i in eth0 eth1 eth2 eth3; do
  printf '%s  %s  ' "$i" "$(cat /sys/class/net/$i/address)"
  ethtool "$i" 2>/dev/null | sed -n 's/.*Link detected: /link=/p'
done
```

看当前解析结果（不改配置）：

```sh
portmap resolve                 # 输出形如：wan=eth0 lan=eth1 eth2 eth3
portmap apply --dry-run         # 只打印将要写入的映射
```

## 2. 把端口角色钉死（按 MAC 或 PCI 槽位）

`/etc/config/portmap` 是「物理口 → 角色」的映射表。首次开机由 `portmap apply` 解析成真实 `ethX` 写进 `/etc/config/network`（`network.wan.device`、`br-lan` 的 `ports`），之后全部是标准 UCI，可以在 LuCI 里改。

填 MAC 最稳（MAC 跟着网卡走，换 PCI 槽位也不变）：

```sh
# 1) 抄下四个口的 MAC
for i in eth0 eth1 eth2 eth3; do echo "$i $(cat /sys/class/net/$i/address)"; done

# 2) 写进 portmap（把值换成你机器的）
uci set portmap.wan.macaddr='00:1b:21:aa:00:04'
uci set portmap.lan1.macaddr='00:1b:21:aa:00:01'
uci set portmap.lan2.macaddr='00:1b:21:aa:00:02'
uci set portmap.lan3.macaddr='00:1b:21:aa:00:03'
uci commit portmap

# 3) 重新解析并写入 network，然后让网络配置生效
portmap resolve                 # 先看对不对
portmap apply
ubus call network reload        # portmap 不会自己 reload，必须手动一次
```

也可以用 PCI 槽位（`option pci_slot '0000:01:00.0'`，值见 `/sys/class/net/ethX/device/uevent` 的 `PCI_SLOT_NAME`）。匹配优先级：`macaddr` > `pci_slot` > 物理顺序兜底。

> `portmap apply` 只 `uci commit network`，不会重启网络。漏了 `ubus call network reload` 会表现为「配置改了但一点变化都没有」。

## 3. 内网地址与 DHCP

| 地址 | 用途 |
|---|---|
| `192.168.100.1` | 软路由（LuCI / SSH / DNS / 网关） |
| `192.168.100.2` | AX3000T（AP，仅管理） |
| `192.168.100.3–99` | 固定设备（NAS、打印机、摄像头） |
| `192.168.100.100–199` | DHCP 池（租期 12h） |

看当前租约与地址：

```sh
cat /tmp/dhcp.leases
ip -br addr show br-lan
```

## 4. AX3000T 设为 AP（纯接入点）

目标：AX3000T 只做无线桥接，DHCP、路由、防火墙全部由软路由负责。**两个 DHCP 服务器同时在线会互相抢答**，典型症状是「能连上 WiFi 但上不了网 / 拿到奇怪的 IP」。

步骤（小米固件，管理地址默认 `192.168.31.1`，以机身贴纸为准）：

1. AX3000T 先单独上电，电脑连它的默认 WiFi 或用网线接它的 LAN 口。
2. 打开管理页 → 上网设置 → **工作模式切换 → 有线中继（AP）模式**。
3. 有线中继模式下它的 DHCP 会自动关闭；如果没关，手工关掉。
4. 上联网线：AX3000T 的 **WAN 口** → N5105 的 `eth1`。
5. 设 WiFi 名称与密码（2.4G/5G 可同名也可分开）。
6. 把它的管理地址固定在 `192.168.100.2`——在软路由上做静态租约最省事：

```sh
# 先找出 AX3000T 的 MAC（看租约里哪条像路由器）
cat /tmp/dhcp.leases
uci add dhcp host
uci set dhcp.@host[-1].name='ax3000t'
uci set dhcp.@host[-1].mac='AA:BB:CC:DD:EE:FF'
uci set dhcp.@host[-1].ip='192.168.100.2'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

验证：电脑连 WiFi 后 `ping 192.168.100.1` 通、`ipconfig`/`ip addr` 拿到 `192.168.100.100–199` 的地址，说明 AP 只是二层桥接、DHCP 来自软路由。

## 5. IPv6：为什么用 NAT66

认证网络一般只给 WAN 侧一个地址段，**不下发 PD（前缀委派）**，所以内网终端拿不到公网 IPv6——这就是「路由器自己有 IPv6、手机却没有」的原因（iStoreOS 上踩过同一个坑）。

本固件用 NAT66 解决，三件套都是 fw4 / netifd 原生能力：

| 层 | 配置 | 位置 |
|---|---|---|
| 内网前缀 | ULA `fd7a:6e64:6c35::/48`（`ula_prefix`） | `/etc/config/network` 的 `globals` |
| 内网分发 | LAN `ip6assign 60` + `ra server` + `dhcpv6 server` | `network.lan`、`/etc/config/dhcp` |
| 出口地址转换 | 防火墙 wan 区域 `option masq6 '1'`（SNAT66） | `/etc/config/firewall` |

效果：终端拿到 `fd7a:6e64:6c35:xxxx::/64` 的地址，出网时源地址被换成 WAN 侧的接入地址，**接入侧只看到软路由一个 IPv6**。不做 relay、不请求 PD，`/etc/config/dhcp` 里 LAN 的 `ndp` 是 `disabled`，避免把终端地址暴露出去。

代价（必须知道）：

- 外网**无法主动连进终端**：BT/PT 做种、部分游戏语音、自建服务（NAS 外网访问）会退化或不通。
- 某些网站/应用按 IPv6 判设备，可能与 IPv4 表现不一致；出问题先试 `curl -4`。
- NAT66 与「按设备数计费」的策略天然冲突，是否使用见 [compliance.md](compliance.md)。

验证：

```sh
# 路由器侧
ip -6 addr show br-lan | grep fd7a          # 内网有 ULA 网关地址
ip -6 addr show eth0 | grep 'scope global'  # WAN 有下发的 v6（没有说明上级没给 v6）
fw4 print 2>/dev/null | grep -iE 'masq6|masquerade'

# 终端侧（电脑/手机）
ip -6 addr show | grep fd7a                 # 终端拿到 ULA
ping -6 -c3 2400:3200::1                    # 能出网（阿里 DNS 的 v6 地址）
```

要放行某台内网设备的入站端口，需要在内网侧自己做（NAT66 下 WAN 侧不转发），或者把该设备接在 AP 之外单独处理。

LuCI 里的等价入口：

- ULA 前缀：**网络 → 接口 → 全局网络选项 → IPv6 ULA 前缀**
- NAT66：**网络 → 防火墙 → 区域 → wan → 编辑 → 高级设置 → IPv6 Masquerading**

## 6. 网段冲突（`192.168.100.0/24`）

`192.168.100.0/24` 与部分 DOCSIS 电缆猫、华为 ONU 的默认网段重叠。**接线前先确认上级设备用的网段**（电脑直连光猫看网关地址，或在光猫后台看 LAN 设置）。

冲突时的表现：能进后台但上不了网、`ifstatus wan` 有地址却 ping 不通、路由表里两条同段路由打架。

改内网网段的两种方式：

```sh
# 方式一（推荐，改完所有设备要重新取址）
uci set network.lan.ipaddr='192.168.88.1'
uci commit network
ifup lan

# 方式二：如果还没首启，构建时把 custom_router_ip 填成目标地址，
#        首启脚本会读 /etc/config/custom_router_ip.txt 写进 LAN
cat /etc/config/custom_router_ip.txt
```

改完记得同步 DHCP 池（默认 `100`–`199`，随新网段自动适配，不用改）。改 LAN 地址会断开当前连接，等 30–90 秒用新地址重连。

## 7. 上联方式切换

| 场景 | 操作 |
|---|---|
| 锐捷认证 | `wanmode apply ruijie`，见 [ruijie.md](ruijie.md) |
| 家里 DHCP（光猫拨号） | `wanmode apply home`（`home` 出厂是 `proto dhcp`） |
| 家里 PPPoE（自己拨号） | 先改 `home` 的实现方式再应用：见下面 |
| 临时/酒店 | `wanmode apply adhoc`，再按酒店要求做 Portal 登录 |

把 `home` 改成 PPPoE：

```sh
wanmode set home proto 'pppoe'
wanmode set home username '宽带账号'
wanmode set home password '宽带密码'
wanmode apply home
```

切完统一验证：

```sh
ifstatus wan | grep -E '"up"|address|proto'
wanmode show
```
