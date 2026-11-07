#!/bin/sh
# ac-5：dev 镜像的带外标识必须活到首启之后，并且要能被上游路由器看见。
#
# 为什么（2026-11-07 真机事故）：`90-dev-image`（编号 90）加的后缀被 `99-custom.sh`（编号 99）
# 无条件写回 'ImmortalWrt'；而 campus profile 又把 `network.wan.hostname` 设成 `*`（不发 option 12）。
# 结果：上游 DHCP 列表里只有 MAC，按文档"找 hostname 带 -dev 的那台"永远找不到。
# 本用例既做静态排序断言，也用 uci 桩**真的执行一遍**脚本看它写了什么。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEVUCI="$ROOT/phase1/dev/rootfs/etc/uci-defaults"
SCRIPT="$DEVUCI/99z-dev-hostname"
SB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/devid.XXXXXX")

echo "== 1. 文件存在且语法正确 =="
[ -f "$SCRIPT" ] && ok "99z-dev-hostname 存在（dev 注入树）" || bad "缺 phase1/dev/rootfs/etc/uci-defaults/99z-dev-hostname"
# 可执行位是仓库既有契约（dev-mode-content.sh 断言 90-dev-image 必须 -rwxr-xr-x），
# 而且 build.sh 用 cp -a 会把模式原样带进镜像。
[ -x "$SCRIPT" ] && ok "99z-dev-hostname 可执行（0755）" || bad "99z-dev-hostname 不可执行（chmod 0755）"
sh -n "$SCRIPT" && ok "语法通过" || bad "语法错误"
if grep -q "99z-dev-hostname" "$SCRIPT" 2>/dev/null && head -3 "$SCRIPT" | grep -q 'dev'; then
	ok "文件头写清了用途"
fi

echo "== 2. 执行顺序：在**真实注入树**里，它必须是最后一个写 hostname 的钩子 =="
# 早期的写法是拿两个字面量排序（'99z' > '99-custom.sh' 恒真），等于同义反复：
# 只要有人再丢一个 99zz-xxx 写死 hostname 进来，bug 就原样回来而用例仍全绿（2026-11-07 复核实测）。
# 这里改成扫真实目录：dev 注入树 + files 基线合并排序，取最后一个含 hostname 赋值的文件。
_last_hostname=''
for _f in $( { ls "$DEVUCI" 2>/dev/null; ls "$ROOT/files/etc/uci-defaults" 2>/dev/null; } | LC_ALL=C sort -u ); do
	for _d in "$DEVUCI" "$ROOT/files/etc/uci-defaults"; do
		[ -f "$_d/$_f" ] || continue
		if grep -q 'hostname' "$_d/$_f" 2>/dev/null; then
			_last_hostname=$_f
		fi
	done
done
eq "真实注入树里最后一个写 hostname 的钩子" '99z-dev-hostname' "$_last_hostname"
grep -q 'hostname' "$ROOT/files/etc/uci-defaults/99-custom.sh" &&
	ok "确认 99-custom.sh 里确实有写死 hostname 的那行（这就是要盖回来的原因）" ||
	bad "99-custom.sh 里没有 hostname 赋值？那本用例的前提要重新核对"

echo "== 3. 行为：用 uci 桩真的跑一遍，看它写了什么 =="
mkdir -p "$SB_ROOT/bin" "$SB_ROOT/etc/config"
cat >"$SB_ROOT/bin/uci" <<'EOF'
#!/bin/sh
# 极简 uci 桩：get 返回预置值，set 记到 calls.log
case "$1" in
	-q)
		shift
		[ "$1" = 'get' ] || exit 1
		case "$2" in
			system.@system[0].hostname) printf 'ImmortalWrt\n'; exit 0 ;;
			network.wan) printf 'wan\n'; exit 0 ;;
		esac
		exit 1
		;;
	get)
		case "$2" in
			system.@system[0].hostname) printf 'ImmortalWrt\n'; exit 0 ;;
			network.wan) printf 'wan\n'; exit 0 ;;
		esac
		exit 1
		;;
	set)
		printf '%s\n' "$2" >>"$UCI_CALLS"
		exit 0
		;;
	commit)
		printf 'commit %s\n' "$2" >>"$UCI_CALLS"
		exit 0
		;;
esac
exit 0
EOF
chmod 0755 "$SB_ROOT/bin/uci"
export UCI_CALLS="$SB_ROOT/calls.log"
: >"$UCI_CALLS"
(
	PATH="$SB_ROOT/bin:$PATH"
	export PATH UCI_CALLS
	# uci-defaults 的语义是 `( . ./file )`：这里同样 source，而不是另起进程
	cd "$DEVUCI" && . ./99z-dev-hostname
) >"$SB_ROOT/run.out" 2>&1
RC=$?
eq "脚本退出 0（uci-defaults 才会自删、不再重跑）" 0 "$RC"
CALLS=$(cat "$UCI_CALLS" 2>/dev/null)
contains "把 hostname 写成 ImmortalWrt-dev" 'system.@system[0].hostname=ImmortalWrt-dev' "$CALLS"
contains "把 wan.hostname 写成同一个值" 'network.wan.hostname=ImmortalWrt-dev' "$CALLS"
contains "commit 了 system" 'commit system' "$CALLS"
contains "commit 了 network" 'commit network' "$CALLS"

echo "== 4. 幂等：已经是 -dev 就不要再叠一层 =="
cat >"$SB_ROOT/bin/uci" <<'EOF'
#!/bin/sh
case "$1" in
	-q) shift; [ "$1" = 'get' ] || exit 1; case "$2" in "system.@system[0].hostname") printf 'wrt-dev\n'; exit 0 ;; network.wan) exit 0 ;; esac; exit 1 ;;
	get) case "$2" in "system.@system[0].hostname") printf 'wrt-dev\n'; exit 0 ;; network.wan) exit 0 ;; esac; exit 1 ;;
	set) printf '%s\n' "$2" >>"$UCI_CALLS" ;;
	commit) : ;;
esac
exit 0
EOF
chmod 0755 "$SB_ROOT/bin/uci"
: >"$UCI_CALLS"
(
	PATH="$SB_ROOT/bin:$PATH"
	export PATH UCI_CALLS
	cd "$DEVUCI" && . ./99z-dev-hostname
) >/dev/null 2>&1
CALLS=$(cat "$UCI_CALLS" 2>/dev/null)
contains "已是 -dev 时不叠加后缀" 'hostname=wrt-dev' "$CALLS"
not_contains "没有出现 wrt-dev-dev" 'wrt-dev-dev' "$CALLS"

echo "== 5. prod 镜像里不该有它 =="
grep -rn "99z-dev-hostname" "$ROOT/phase1/firstboot" 2>/dev/null | grep -q . &&
	bad "firstboot 注入树里出现了 dev 专用脚本（会污染 prod）" ||
	ok "firstboot 注入树里没有 dev 专用脚本（prod 不受影响）"

finish shell-dev-device-identity
