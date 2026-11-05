#!/bin/sh
# ac-12 的取证脚本：真机升级后，p3 与子卷是否还在、写层是否仍指向 @overlay。
#
#   ROUTER=root@192.168.100.1 sh shell/tests/device-upgrade-check.sh
#
# 无 ROUTER、或设备不可达 → 输出 PEND 并退出 2（不算失败，但也不算通过）。
# 这是 ac-12 的唯一判定入口：evidence 名 `upgrade-p3-survives`。
#
# 为什么不能离线判：`get_partitions` 解析 GPT 依赖 busybox hexdump 的字节序语义，
# 在 macOS/BSD 上无法复现（详见 shell/tests/sysupgrade-layout.sh 与 fixtures 的 PROVENANCE），
# 所以"同 profile 升级后 p3 仍在"只能到真机上验。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROUTER="${ROUTER:-}"
FAIL=0
SSHOPT="-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o BatchMode=yes"

pend() {
	printf 'PEND: %s\n' "$*"
	printf 'DEVICE PENDING\n'
	exit 2
}

[ -n "$ROUTER" ] || pend "未设置 ROUTER=<user@host>；ac-12 需要在已升级的真机上跑"
# shellcheck disable=SC2086
ssh $SSHOPT "$ROUTER" true >/dev/null 2>&1 || pend "连不上 ${ROUTER}（或密钥未授权）"

rsh() {
	# shellcheck disable=SC2086
	ssh $SSHOPT "$ROUTER" "$1" 2>&1
}

chk() { # <描述> <远程命令：退出 0 视为通过>
	_out=$(rsh "$2")
	if [ $? -eq 0 ]; then
		ok "$1"
	else
		bad "$1"
		printf '       %s\n' "$(printf '%s' "$_out" | head -3 | tr '\n' '|')"
	fi
}

echo "== ac-12 升级后 p3 与子卷是否仍在 =="
chk "机器可执行 btrfs（btrfs-progs 已装）" 'btrfs --version >/dev/null 2>&1'
chk "存在 label=wrt-overlay 的 btrfs 分区（p3 未被整盘覆写抹掉）" \
	'btrfs filesystem show wrt-overlay >/dev/null 2>&1'
chk "/overlay 仍然是 btrfs" 'awk "\$2==\"/overlay\"{exit !(\$3==\"btrfs\")}" /proc/mounts'
chk "@overlay 子卷仍在" 'btrfs subvolume list /overlay 2>/dev/null | grep -q @overlay'
chk "@docker 子卷仍在" 'btrfs subvolume list /overlay 2>/dev/null | grep -q @docker'
chk "@swap 子卷仍在" 'btrfs subvolume list /overlay 2>/dev/null | grep -q @swap'
chk "@data 子卷仍挂载在 /data" 'awk "\$2==\"/data\"{f=1} END{exit !f}" /proc/mounts'
chk "配置目录来自 p3 写层（/etc/config 可写且非 tmpfs）" \
	'grep -q " /overlay " /proc/mounts && touch /etc/config/.upgrade-probe && rm -f /etc/config/.upgrade-probe'
# 只检查**最后一次** overlay-setup 运行：日志是追加的，历史 ERROR（例如首启 chattr 缺失）会永久留着
chk "最后一次首启初始化无 ERROR" \
	'L=/etc/config/overlay-setup.log; [ ! -f "$L" ] || awk "/=== overlay-setup start ===/{buf=\"\"} {buf=buf \$0 \"\\n\"} END{exit (buf ~ /ERROR/)}" "$L"'

echo "---"
if [ "$FAIL" = 0 ]; then
	echo "UPGRADE-P3 OK（p3 与子卷在升级后存活）"
	exit 0
fi
echo "UPGRADE-P3 FAILED（p3 未存活：按 docs/install.md 升级章的恢复流程处理，并记录到 handoff）"
exit 1
