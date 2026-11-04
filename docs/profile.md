# 家 / 校双 profile：`netprofile`

> 一条命令切换整机配置。**默认就是 campus**，不带参数执行即可。
> 两套配置各自记住你手改的内容，来回切换不丢。

## 1. 用法

| 命令 | 作用 |
|---|---|
| `netprofile` | 套用 **campus**（默认） |
| `netprofile campus` | 同上，显式写法 |
| `netprofile home` | 套用家庭配置（不做防检测、IPv6 走上游默认） |
| `netprofile status` | 显示当前 profile、每个受管键的实际值、与模板的差异 |
| `netprofile forget home` | 丢弃 home 的存档：非当前档 = 下次切回升效；当前档 = 立即按模板重写受管键 |

切换成功会打印生效摘要；失败会自动回滚并返回非 0，此时 `/etc/netprofile` 保持原值。

也可以在 LuCI 里点：**系统 → 命令**，三个按钮分别是「切换到 campus（默认）」「切换到 home」「查看当前 profile」。

```sh
netprofile status          # 先看现在在哪套
netprofile home            # 回 home
netprofile                 # 回 campus（默认）
```

## 2. 两套 profile 的区别

| 受管项 | campus（默认） | home |
|---|---|---|
| `network.wan.proto` | `dhcp` | `dhcp` |
| `network.wan.hostname` | `*`（不把主机名报给上游） | 上游默认 |
| `network.wan6.proto` / `auto` | `dhcpv6` / `1` | `dhcpv6` / `1` |
| `network.wan6.reqprefix` | `no`（不请求前缀委派） | 上游默认 |
| `network.globals.ula_prefix` | ULA（NAT66 内网前缀） | 上游默认 |
| `dhcp.lan.ra` / `dhcpv6` / `ndp` | `server` / `server` / `disabled` | `server` / `server` / `disabled` |
| `dhcp.lan.ra_flags` | `managed-config other-config` | 上游默认 |
| `firewall.<wan>.masq6` | `1`（NAT66） | 上游默认 |
| 防检测 `campus_ttl` / `campus_noleak` | 开 | 关 |
| 二档 `campus_natport` / `campus_ntp` / `campus_conncap` | 关（可手动开） | 关 |
| `minieap` 认证 | `enable` + `start`（conf 里没有账号时跳过） | `stop` + `disable` |

campus 侧为什么要 NAT66：这类接入环境按**设备数**限制，只要下游设备各自拿到独立 IPv6 地址，NAT44 再干净也会被一眼看穿。NAT66 让所有终端共用一个出口 v6 地址。

## 3. 记忆机制（手改不丢）

- **受管键**共 16 项（上表去掉"上游默认"的行）：11 个网络/DHCP/防火墙键 + 5 个 `firewall.campus_*.enabled`。
- 切走前把当前受管键存进 `/etc/netprofile.d/<当前 profile>.state`；切回时优先恢复这份存档，没有存档才套模板。
- **受管键之外的一切配置脚本不碰**：你手加的静态路由、防火墙自定义段、代理节点、DHCP 静态租约都不受影响。
- 切换前还会写一份整包快照 `/etc/netprofile.d/<profile>.backup`（`uci export` 全量），供人工排障；自动回滚用的是同目录的 `.backup.keys`。
- 想丢弃存档回到模板：`netprofile forget <mode>`。若 `<mode>` 正是当前 profile，会**立刻**按模板重写受管键（不是只删文件）；若非当前档，则下次切回时生效。

## 4. 防检测：一档（默认开）与二档（默认关）

规则由 fw4 的 `config include` 承载，片段在 `/etc/campus/nft/`，全部规则带 `!campus:` 注释。

**一档（campus 默认开，零副作用）**

| 项 | 规则链 | 作用 |
|---|---|---|
| `campus_ttl` | `mangle_forward` | 出口 TTL / HopLimit 统一为 64（防"TTL 递减不一致"推断多设备） |
| `campus_noleak` | `mangle_forward` | 出向丢 mDNS/SSDP/WS-D/NetBIOS/SMB 组播广播（防误配中继泄露；**不含 DHCP 67/68**） |

两条一档规则都挂在 `mangle_forward`：它没有 zone-jump，追加的规则必然命中；而 `forward` 链里 `chain-append` 的位置在所有 zone-jump 之后，那里已经被 `accept` 短路，规则**永远收不到转发的包**。

TTL 归一写在 `mangle_forward` 而不是 postrouting：内核在 forward 钩子**之前**就做了 TTL 递减，所以 forward 内设 64，出网就是 64；同时路由器自身流量不受影响，本机 `traceroute` 仍然可用。已知副作用是 **LAN 终端 traceroute 只剩一跳**。

**二档（默认关，需要时手动开）**

```sh
# NAT 源端口随机化（对应"同一 IP 出现多条递增源端口序列"这条判据）
uci set firewall.campus_natport.enabled='1'; uci commit firewall; fw4 reload

# 全网 NTP 收敛到本机（先把本机变成 NTP 服务端）
uci set system.ntp.enable_server='1'; uci commit system
uci set firewall.campus_ntp.enabled='1'; uci commit firewall; fw4 reload

# 单源并发连接上限（默认 400）
uci set firewall.campus_conncap.enabled='1'; uci commit firewall; fw4 reload
```

回滚就是把对应项置 `enabled='0'` 再 `fw4 reload`，例如
`uci set firewall.campus_ntp.enabled='0'; uci commit firewall; fw4 reload`。三项的副作用与实测方法见每节：

- `campus_natport`：端口预测类应用（部分游戏联机、SIP/RTP、UPnP 映射）可能失效；**二次 masquerade 行为未验证**，务必在无流量时段开启，先看 `conntrack -L | grep SNAT` 的端口分布。
- `campus_ntp`：全网时间取决于路由器；上游 NTP 不可达时终端可能拿不到时间。
- `campus_conncap`：BT/PT、多标签页、多设备备份会误伤，体感是"网变卡"；阈值需按现场调整。

这些改动都属于 `firewall.campus_*.enabled`（受管键），**会被记进当前 profile 的存档**，切走再切回仍然是你设的值。

## 5. 生效链路与两个前置条件

```
netprofile campus
  → 写 11 个非 include 受管键
  → sh /etc/campus/nft/render.sh      # 把 @WAN@/@LAN_IF@ 换成真实设备名
  → 置 5 个 campus_*.enabled
  → uci commit + network reload + dnsmasq/odhcpd + fw4 reload
```

- **`render.sh` 渲染失败就整体失败**：不会出现"include 指向不存在文件、规则静默不生效"的半套状态。WAN 口变了要重跑 `sh /etc/campus/nft/render.sh`（`netprofile` 每次切换都会自动跑）。
- **`flow_offloading` 必须保持 `0`**（默认就是 0）：一旦开启，已 offload 的流会绕过 netfilter，TTL 规则只对首包生效。
- 本固件**没有 iptables**：25.12 用 firewall4 + nftables，网上基于 `iptables -t mangle …` 或 `/etc/firewall.user` 的教程在这里一律无效（`/etc/firewall.user` 在 fw4 下默认不执行）。要加规则请写 `config include` 片段。

## 6. 关于 `owut`（已被移除）

本固件**不再包含 `owut`**。它是上游 25.12 默认带的在线升级工具，但它的工作方式是"把包清单发给服务器重新编镜像"——那个镜像**不含本仓库 `files/` 里的任何定制**（`netprofile`、`nicsync`、`minieap` init、防检测片段都不在），而 `sysupgrade` 只保留 `/etc` 配置。结果是升级后配置还在、脚本却全没了，表现为"后台能进、但认证不自启、防检测消失"。

升级固件的正路是**重跑 GitHub Actions 重新构建并刷机**。

## 7. 上机后逐条验收（真机）

```sh
uci get network.wan6.auto               # campus 下应为 1
uci get firewall.campus_ttl.enabled     # campus 下应为 1
nft list ruleset | grep -c '!campus'    # campus>0；netprofile home 后应为 0
nft list chain inet fw4 mangle_forward | grep '!campus'
tcpdump -ni $(uci get network.wan.device) -vv -c 20 'ip'   # ttl 恒 64、校验和正常
ifstatus wan6 | grep -c prefix          # 应为 0（不请求 PD）
```

`netprofile` 不会替你确认"上游到底给了什么"，它只保证本机配置一致——链路是否通仍以 `ifstatus wan` 为准。
