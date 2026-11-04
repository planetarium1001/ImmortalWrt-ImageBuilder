# N5105 v5 四网口路由固件手册

- 适用设备：N5105 v5（Jasper Lake，4×i226-V 2.5G），UEFI 物理直装
- 系统盘：任意容量的 M.2 NVMe（首启自动扩满）
- 固件：ImmortalWrt 25.12.2（apk，Linux 6.12）定制构建

## 这套固件提供什么

- **认证**：minieap（锐捷 v3），配置文件 `/etc/minieap.conf`，开机自启 `/etc/init.d/minieap`
- **地址**：WAN 用原生 `proto dhcp`；IPv6 由网络侧决定，内网终端走 ULA + NAT66
- **端口**：开机按 PCI 槽位顺序固定为 `eth0`–`eth3`，与内核枚举顺序无关
- **代理**：nikki（mihomo）白名单模式，出厂关闭
- **容器**：dockerd + dockerman，构建时 `include_docker=yes` 才包含
- **运维**：LuCI 自定义命令、在线文件编辑、网页终端

## 五分钟上手

1. **刷写**：写入系统盘，见 [install.md](install.md)
2. **进后台**：`eth1` 接 AP 或电脑，浏览器打开 `http://192.168.100.1`，用户 `root`，出厂无密码
3. **配认证**：编辑 `/etc/minieap.conf` 填账号密码，见 [ruijie.md](ruijie.md)
4. **接上级网络**：网线插 `eth0`，`/etc/init.d/minieap restart`，`ifstatus wan` 看到地址即通

## 文档目录

| 文档 | 内容 |
|---|---|
| [install.md](install.md) | 刷写、首次启动、进入后台、扩容 |
| [ruijie.md](ruijie.md) | minieap 配置与认证排障 |
| [network.md](network.md) | 端口顺序、AP 模式、NAT66、网段 |
| [ops.md](ops.md) | 认证与地址、swap、数据盘与 docker、备份回滚 |
| [packages.md](packages.md) | 内置软件清单与上游链接 |
| [compliance.md](compliance.md) | 使用条款与责任声明 |

## 常用命令

```sh
# 认证
# 首次：手动认证一次，-w 把参数写回 /etc/minieap.conf
minieap -u 账号 -p 密码 -n eth1 --module rjv3 -d 0 -w
vi /etc/minieap.conf                # 之后可直接编辑
/etc/init.d/minieap restart         # 重载认证
logread -e minieap -f               # 实时日志
/usr/sbin/minieap -u 账号 -p 密码 -n eth0 --module rjv3   # 手工试跑

# 地址
ifstatus wan                        # WAN 是否拿到地址
ifup wan                            # 手动拉起 WAN

# 端口
ip -o link show | grep eth          # 看当前顺序
/usr/sbin/nicsync --dry-run          # 看接口名与配置是否一致

# IPv6
/usr/sbin/ipv6mode status           # 看当前模式
/usr/sbin/ipv6mode native           # 家宽下发 PD 时用
/usr/sbin/ipv6mode nat66            # 上级只给单地址时用
/usr/sbin/ipv6mode off              # 关掉内网 IPv6
/usr/sbin/ipv6mode forget native    # 丢弃该模式的记忆，回到模板

# swap
/usr/sbin/swapctl status
/usr/sbin/swapctl resize 2048
```

## 文件位置

| 路径 | 作用 |
|---|---|
| `/etc/minieap.conf` | 认证配置（唯一入口） |
| `/etc/config/network` | 接口与端口引用 |
| `/etc/config/uci-defaults-log.txt` | 首启脚本日志 |
| `/var/log/minieap.log` | minieap 自身日志 |
