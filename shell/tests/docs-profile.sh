#!/bin/sh
# ac-10（U05 交付文档后转绿）：文档必须写明切换用法、二档项开启方法、真机实测步骤
# 与 owut/iptables 风险。这里断言的是**精确字串**，避免含糊表述过关。
set -u
. "$(dirname "$0")/lib-assert.sh"
. "$(dirname "$0")/lib-sandbox.sh"

D=$REPO/docs
if [ ! -d "$D" ]; then
	echo "SKIP: $D 尚未产出（U05 未完成）"
	echo "DOCS-PROFILE PENDING"
	exit 2
fi

need() { # <精确字串> <说明>
	if grep -rqF -- "$1" "$D" 2>/dev/null; then
		ok "文档含 [$1]（$2）"
	else
		bad "文档缺 [$1]（$2）"
	fi
}

need 'netprofile home'   'home 档切换命令'
need 'netprofile status' 'status 用法'
need 'campus_natport'    '二档项开启方法'
need 'owut'              'owut 风险'
need 'iptables'          'iptables 风险（25.12 无此二进制）'
need 'render.sh'         '片段渲染脚本'
need 'flow_offloading'   'flow_offloading 必须为 0 的说明'
need 'netprofile forget' 'forget 语义'
need 'enable_server'     '二档 NTP 开启的前置命令'
need 'mangle_forward'    '防检测规则所在链（避免再挂到不可达的 forward 末尾）'

# 手册文件本身必须在，且不是空壳
if [ -s "$D/profile.md" ]; then ok "docs/profile.md 存在且非空"; else bad "docs/profile.md 缺失或为空"; fi
# 用法表、二档回滚、真机清单三段必须在同一份手册里
for sec in 'netprofile status' "enabled='0'" 'nft list ruleset'; do
	if grep -qF -- "$sec" "$D/profile.md" 2>/dev/null; then ok "profile.md 含 [$sec]"; else bad "profile.md 缺 [$sec]"; fi
done

finish DOCS-PROFILE
