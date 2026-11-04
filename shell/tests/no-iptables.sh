#!/bin/sh
# ac-8：25.12 镜像里没有 iptables 二进制，规则只走 fw4 的 include 片段。
#   ① 代码里不得有 iptables **命令调用**（注释里说明"不用 iptables"是允许的）；
#   ② /etc/firewall.user 必须文件级消失、代码里不再引用；
#   ③ 不得有 `nft add rule inet fw4` 这类运行时注入写法。
# 扫描范围：files/、x86-64/、shell/tests/（代码与测试都不许调用 iptables）。
# 注意：x86-64/imm25.config 里的 CONFIG_PACKAGE_iptables-mod-* 是内核模块名，
# 不是命令调用，因此不在扫描范围内（那里也无法用"是否执行"来判定）。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

# 只保留"非注释行"的命中
code_hits() { # <grep 参数...>
	grep -rn "$@" 2>/dev/null | grep -vE 'shell/tests/(no-iptables|docs-.*)\.sh' | awk '
		{
			line = $0
			sub(/^[^:]*:[0-9]+:/, "", line)
			if (line ~ /^[ \t]*#/) next
			print
		}'
}

echo "== 无 iptables 命令调用 =="
hits=$(code_hits -E '(^|[^[:alnum:]_./-])ip6?tables([[:space:]]|$)' \
	"$REPO/files" "$REPO/x86-64" "$REPO/shell/tests")
eq "代码里没有 iptables/ip6tables 调用" '' "$hits"

echo "== /etc/firewall.user 已消失且不再引用 =="
if [ -e "$REPO/files/etc/firewall.user" ]; then
	bad "files/etc/firewall.user 仍存在"
else
	ok "files/etc/firewall.user 已删除"
fi
hits=$(grep -rn 'firewall\.user' "$REPO/files" "$REPO/x86-64" "$REPO/shell/tests" 2>/dev/null \
	| grep -vE 'shell/tests/(no-iptables|docs-.*)\.sh')
eq "代码里不引用 /etc/firewall.user" '' "$hits"

echo "== 不用运行时 nft 注入 =="
hits=$(code_hits -E 'nft (add|insert|delete|flush) rule' "$REPO/files")
eq "没有 nft add/insert rule 写法" '' "$hits"
hits=$(code_hits -E '(^|[^[:alnum:]_])nft -f' "$REPO/files")
eq "没有 nft -f 直接加载整份规则文件" '' "$hits"

echo "== 防检测规则只经 fw4 include（config include + 片段文件）=="
eq "include 段由 98-campus-nft.sh 创建" 'yes' \
	"$([ -x "$REPO/files/etc/uci-defaults/98-campus-nft.sh" ] && echo yes || echo no)"
eq "片段目录存在" 'yes' "$([ -d "$REPO/files/etc/campus/nft" ] && echo yes || echo no)"
eq "存在 .nft.tmpl 片段" 'yes' \
	"$(ls "$REPO"/files/etc/campus/nft/*.nft.tmpl >/dev/null 2>&1 && echo yes || echo no)"

finish NO-IPTABLES
