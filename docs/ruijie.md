# 锐捷认证认证（minieap）

## 原理

认证网络墙口在认证前通常「链路是通的，但没有可用网络」：802.1x 的 EAP 认证过了，交换机才放行 DHCP 与上网。本固件用 `minieap`（`--module rjv3`，锐捷 v3/v4 算法）做认证，由 netifd 的 `minieap` 协议处理器在 `wan` 接口上拉起，不用自己写 init 脚本。

认证相关的 UCI 选项都写在 `/etc/config/network` 的 `wan` 段：

| 选项 | 含义 |
|---|---|
| `proto` | `minieap` |
| `username` / `password` | 认证账号（密码里如果有空格、`@`、`'`，用单引号包住） |
| `module` | 认证插件，必须是 `rjv3`；**这是列表**（`list module 'rjv3'`），不是字符串 |
| `dhcp_type` | 见下一节，`0`–`3` |
| `stage_timeout` / `max_retries` | 设成 `0` 让 minieap 失败后不退出、持续重试 |
| `log_file` | 可选，如 `/var/log/minieap.log` |

## 1. `dhcp_type` 的含义与现场确认

`dhcp_type` 直接传给 minieap 的 `--dhcp-type`，四个取值：

| 值 | 含义 | 什么时候用 |
|---|---|---|
| `0` | 不使用 DHCP | 接入方要求静态 IP，或地址由别的方式下发 |
| `1` | 二次认证 | 认证后服务器还要再走一次认证交互 |
| `2` | 认证后 DHCP | 最常见：认证通过后才拿到地址 |
| `3` | 认证前 DHCP | 先拿地址再认证（部分网络） |

**现场确认办法**：先看现象，再用抓包定论。

```sh
# 插上网线、WAN 还没起来时抓 50 个包
tcpdump -i eth0 -n -e -c 50 'udp port 67 or udp port 68 or ether proto 0x888e'
```

- 认证前就出现 DHCP `Discover/Offer`，之后才有 EAP → 用 `3`。
- 只有 EAP（`0x888e`）来回，认证成功后才出现 DHCP → 用 `2`。
- 认证后交换机还要求再认证一轮 → 用 `1`。
- 锐捷认证网络根本不发 DHCP（自己填静态地址）→ 用 `0`。

出厂设的是 `0`（不做 DHCP，交给 WAN 的 dhcp 客户端）。需要客户端自己取地址时改 `2`，二次认证改 `1`。

## 2. 配置账号

唯一入口是 `/etc/minieap.conf`，与程序自带格式一致：

```ini
username=20230001
password=你的密码
nic=eth0
module=rjv3
```

保存后重载：

```sh
/etc/init.d/minieap restart
logread -e minieap -f
```

需要调整高级参数时，取消对应行注释即可（`stage-timeout`、`max-retries`、`wait-after-fail`、`log-file` 等），不需要碰 UCI。


## 3. 前台手工试一次（最快定位问题）

正式配置前先手工跑一遍，能立刻分清是「账号问题」还是「配置问题」：

```sh
ifdown wan                                   # 先让 netifd 放开 eth0
minieap -u '20230001' -p 'p@ss w0rd' -n eth0 --module rjv3 --dhcp-type 2 -b 0
# 认证成功会打印交互过程；Ctrl+C 退出
minieap -h | head -40                        # 看本机支持的全部参数
ifup wan                                     # 交回 netifd 管理
```

## 4. 确认认证状态

```sh
logread -e minieap -f                        # 跟认证日志
ifstatus wan | grep -E 'up|address|errors'   # 接口是否起来、有没有地址
ip -4 addr show eth0                         # WAN 上的地址
ps w | grep -c '[m]inieap'                   # 进程数量（应为 1）
```

判定标准：`ifstatus wan` 里 `"up": true` 且有 `ipv4-address`，同时 `ping -c3 223.5.5.5` 能通。

## 5. 认证失败排查

按顺序排查，每步都有明确判断依据：

| # | 现象 | 原因 | 处理 |
|---|---|---|---|
| 1 | `ifstatus wan` 报 `MISSING_USER_OR_PASS` | 账号或密码为空 | 按第 2 节检查 `/etc/minieap.conf` 的 `username`/`password`，然后 `restart` |
| 2 | minieap 起来几秒就退出 | `stage_timeout` / `max_retries` 用了默认值 | 都设成 `0`（见第 2 节末尾） |
| 3 | 日志里 EAP 一直没回应 | 网线插错口 / 该口不是锐捷认证网络口 | `ip -o link show | grep eth` 确认 WAN 对应哪个 `ethX`；换口再试 |
| 4 | 认证通过但 `eth0` 没地址 | `dhcp_type` 不对 | 按第 1 节改 `2`/`3`/`0` 逐个试 |
| 5 | 服务器提示「非指定客户端」/ 版本不符 | 接入方有客户端校验 | 依次试 `uci set network.wan.version_str='...'`、`service`、`fake_serial`、`rj_option`（见第 6 节） |
| 6 | 认证报文发不出去，抓包看不到 `0x888e` | 组播地址不匹配 | `uci set network.wan.eap_bcast_addr='1'`，reload 后再试 |
| 7 | 认证成功但网页打不开 | DNS / 网关 / 防火墙 | `nslookup www.baidu.com 223.5.5.5`、`fw4 print \| head -40` |
| 8 | 隔一段时间掉线 | 心跳间隔与接入方不匹配 | 调 `uci set network.wan.heartbeat='30'`（默认 60） |
| 9 | 接入方绑定了 MAC | 换设备后认证不过 | 在 WAN 上克隆原设备 MAC：`uci set network.wan_dev.macaddr='AA:BB:CC:DD:EE:FF'; uci commit network; ifup wan` |
| 10 | 账号本身有问题（欠费、被停用） | 与固件无关 | 用官方客户端先验证一次，再回来排 |

> 排查期间把 `log_file` 指到 `/var/log/minieap.log`（见第 2 节），比 `logread` 看得全。

## 6. 客户端校验场景可用的字段

minieap 的 rjv3 插件允许附加/覆盖字段，全部通过 `network.wan` 设置（这些名字来自官方 `minieap` 包的 netifd 协议处理器）：

```sh
uci set network.wan.service=''                 # 服务名（锐捷服务名，中文场景注意编码）
uci set network.wan.version_str=''             # 客户端版本字符串
uci set network.wan.fake_serial=''             # 伪造硬盘序列号
uci add_list network.wan.rj_option='6a:000102' # 自定义字段，type:value[:r]
uci set network.wan.wait_after_fail='30'
uci commit network
ubus call network reload
```

逐项试、每改一项重启 `wan` 一次，用 `logread -e minieap -f` 看服务器返回。接入方没有客户端校验时这些留空即可。

## 7. 认证掉线怎么办

本固件不再内置探测模块。判断"是不是真掉线"用两条命令就够：

```sh
ifstatus wan | grep -E '"up"|address'    # WAN 还有没有地址
logread -e minieap | tail -20            # 认证进程最后说了什么
```

- 有地址但打不开网页 → 多半是 DNS 或上游问题：`nslookup www.baidu.com 223.5.5.5`。
- 没地址 → 认证掉了，重启认证即可：`/etc/init.d/minieap restart`。

认证进程由 procd 托管，异常退出会自动拉起，一般不需要人工干预。

