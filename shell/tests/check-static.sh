#!/bin/sh
# 两个预置配置文件的静态检查（不联网、不需要路由器）。
# 1) UCI 文件的语法与关键取值
# 2) mixin.yaml 的 YAML 解析与白名单语义
#
# 用法：sh check-static.sh [仓库根目录]

set -u
ROOT="${1:-}"
if [ -z "$ROOT" ]; then
	d=$(cd "$(dirname "$0")" && pwd)
	while [ "$d" != "/" ]; do
		[ -f "$d/files/etc/config/nikki" ] && { ROOT=$d; break; }
		d=$(dirname "$d")
	done
fi
[ -n "${ROOT:-}" ] || { echo "找不到仓库根目录" >&2; exit 1; }

UCI="$ROOT/files/etc/config/nikki"
MIXIN="$ROOT/files/etc/nikki/mixin.yaml"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1（$3）"; else no "$1（want=[$2] got=[$3]）"; fi; }

# uci get 的等价实现：取某个命名段里某个 option 的值
uci_get() {
	awk -v sec="$1" -v key="$2" '
		/^config / { cur = ($3 ~ /^\x27/) ? $3 : $3; gsub(/\x27/, "", cur) }
		cur == sec && $1 == "option" { k = $2; gsub(/\x27/, "", k); if (k == key) { v = $3; gsub(/\x27/, "", v); print v } }
	' "$UCI" | tail -n1
}

echo "== UCI 语法 =="
if command -v python3 >/dev/null 2>&1; then
	python3 - "$UCI" <<'PY'
import re, sys
path = sys.argv[1]
bad = []
pat_section = re.compile(r"^config\s+[A-Za-z0-9_]+(\s+'[^']*'|\s+[A-Za-z0-9_]+)?$")
pat_option  = re.compile(r"^\t(option|list)\s+[A-Za-z0-9_]+\s+'([^']*)'$")
secs = opts = 0
for i, raw in enumerate(open(path, encoding="utf-8"), 1):
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    if line.startswith("config "):
        secs += 1
        if not pat_section.match(line):
            bad.append((i, line))
    else:
        m = pat_option.match(line)
        if m:
            opts += 1
        else:
            bad.append((i, line))
print(f"  段={secs} 选项/列表行={opts}")
if bad:
    for i, l in bad:
        print(f"  非法行 {i}: {l}")
    sys.exit(1)
print("  所有非注释行都符合 config/option/list 语法")
PY
	[ $? -eq 0 ] && ok "UCI 语法" || no "UCI 语法"
else
	echo "  (跳过：没有 python3)"
fi

echo "== UCI 关键取值 =="
check "config.enabled（默认关闭）" "0" "$(uci_get config enabled)"
check "mixin.tun_enabled（TUN 关闭）" "0" "$(uci_get mixin tun_enabled)"
check "proxy.tcp_mode（redirect）" "redirect" "$(uci_get proxy tcp_mode)"
check "mixin.redir_port（端口 7893）" "7893" "$(uci_get mixin redir_port)"
check "mixin.api_listen（绑 0.0.0.0）" "0.0.0.0:9090" "$(uci_get mixin api_listen)"
check "mixin.mixin_file_content（让 mixin.yaml 生效）" "1" "$(uci_get mixin mixin_file_content)"
check "proxy.ipv4_dns_hijack（不劫持 DNS）" "0" "$(uci_get proxy ipv4_dns_hijack)"
check "mixin.dns_listen（不占 53）" "[::]:1053" "$(uci_get mixin dns_listen)"
check "mixin.mode（rule）" "rule" "$(uci_get mixin mode)"
check "config.init（首启生成随机密钥）" "1" "$(uci_get config init)"

echo "== mixin.yaml =="
if command -v ruby >/dev/null 2>&1; then
	ruby -Ku -ryaml -e '
		c = YAML.load_file(ARGV[0])
		fail = 0
		chk = lambda { |name, cond, extra| puts "  #{cond ? "ok  " : "FAIL"} #{name}#{extra ? "（#{extra}）" : ""}"; fail += 1 unless cond }
		rules = c["nikki-rules"] || []
		chk.call("mode 是 rule（白名单前提）", c["mode"] == "rule", c["mode"])
		chk.call("白名单规则在首位", rules.first.to_s.start_with?("RULE-SET"), rules.first)
		chk.call("兜底规则是 MATCH,DIRECT", rules.last == "MATCH,DIRECT", rules.last)
		g = (c["nikki-proxy-groups"] || []).first || {}
		chk.call("代理组引入订阅节点", g["include-all-proxies"] == true || g["include-all-providers"] == true, "include-all-*")
		chk.call("代理组不写死 provider 名", g["use"].nil?, "use=#{g["use"].inspect}")
		d = c["dns"] || {}
		chk.call("dns 不监听 53/不绑 LAN", d["listen"].nil?, d["listen"].inspect)
		chk.call("内网域名不做 fake-ip", Array(d["fake-ip-filter"]).any? { |x| x.to_s.include?("lan") }, Array(d["fake-ip-filter"]).size.to_s + " 项")
		rp = (c["rule-providers"] || {})["nikki-whitelist"] || {}
		chk.call("rule-provider 指向真实文件", !rp["path"].nil?, rp["path"])
		exit(fail.zero? ? 0 : 1)
	' "$MIXIN"
	[ $? -eq 0 ] && ok "mixin.yaml 语义" || no "mixin.yaml 语义"
else
	echo "  (跳过：没有 ruby)"
fi

printf '\n---------------- 静态检查: %d 通过, %d 失败 ----------------\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
