# fixtures/sysupgrade —— 上游 sysupgrade 分支判定的固定副本

这两个文件是 **openwrt/openwrt `openwrt-25.12` 的上游原文件**，逐字节拷贝，供
`shell/tests/sysupgrade-layout.sh` 真跑 `platform_do_upgrade` 的分支逻辑（而不是抄一份
副本自证）。ImmortalWrt 的同名文件与上游逐字节相同（2026-11-05 复核）。

| 文件 | 上游路径 | sha256 |
|---|---|---|
| `common.sh` | `package/base-files/files/lib/upgrade/common.sh` | `fee08a6dcea757850f9071425eaa3959568be58baade4101a8e0dc1dfa967177` |
| `platform.sh` | `target/linux/x86/base-files/lib/upgrade/platform.sh` | `4861fa0d3805a900dd1c08bc1aeccbe05bd5e1973acc2814ebd7ab107cc4b6e2` |

- 分支：`openwrt-25.12`
- 取文件时的分支头 commit：`cf2cae90b4ffd3c900ff902e85cce761492e9a38`（2026-11-04T21:28:36Z）
- 抓取日期：2026-11-05
- 来源 URL：`https://raw.githubusercontent.com/openwrt/openwrt/openwrt-25.12/<上表路径>`

## 如果要更新

```sh
base=https://raw.githubusercontent.com/openwrt/openwrt/openwrt-25.12
curl -sS "$base/package/base-files/files/lib/upgrade/common.sh" -o shell/tests/fixtures/sysupgrade/common.sh
curl -sS "$base/target/linux/x86/base-files/lib/upgrade/platform.sh" -o shell/tests/fixtures/sysupgrade/platform.sh
sha256sum shell/tests/fixtures/sysupgrade/*.sh   # 同步更新上表
```

更新后必须重跑 `sh shell/tests/sysupgrade-layout.sh`：这个用例断言的是"镜像分区表 ⊆ 盘上
分区表 ⇒ 逐分区写（p3 存活）"，逻辑一旦变化就说明升级语义变了（见 PRD ac-10）。
