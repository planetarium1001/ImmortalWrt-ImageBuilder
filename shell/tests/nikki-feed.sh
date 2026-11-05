#!/bin/sh
# nikki 上游源接入脚本的桩测试（离线可跑，不需要网络）。
#
# 设计：全部场景都在临时目录里伪造一个 ImageBuilder 工作目录，
# 用本地目录当"镜像站"（NIKKI_BASE_URL 指向它），因此既不联网也不依赖 apk/curl 的真实行为；
# "源不可达"用 127.0.0.1:1（必然连接被拒）模拟，也不会真的出网。
#
# 用法：sh nikki-feed.sh [-v]

set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# 定位被测脚本：优先 $NIKKI_REPO_SH，否则从本文件向上逐级找 shell/nikki-repo.sh
find_subject() {
	[ -n "${NIKKI_REPO_SH:-}" ] && { printf '%s\n' "$NIKKI_REPO_SH"; return; }
	d=$(cd "$(dirname "$0")" && pwd)
	while [ "$d" != "/" ]; do
		if [ -f "$d/shell/nikki-repo.sh" ]; then
			printf '%s\n' "$d/shell/nikki-repo.sh"
			return
		fi
		d=$(dirname "$d")
	done
	printf '%s\n' "$(pwd)/shell/nikki-repo.sh"
}

SUBJECT=$(find_subject)
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/nikki-feed-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT INT TERM

PASS=0
FAIL=0
CASE=""

say() { [ "$VERBOSE" = 1 ] && printf '      | %s\n' "$*"; return 0; }

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/      > /'; }

assert_eq() {
	label=$1; want=$2; got=$3
	if [ "$want" = "$got" ]; then ok "$label"; else no "$label (want=[$want] got=[$got])"; fi
}

assert_contains() {
	label=$1; needle=$2; hay=$3
	case "$hay" in
		*"$needle"*) ok "$label" ;;
		*) no "$label (缺失片段: $needle)" ;;
	esac
}

assert_not_contains() {
	label=$1; needle=$2; hay=$3
	case "$hay" in
		*"$needle"*) no "$label (不应出现: $needle)" ;;
		*) ok "$label" ;;
	esac
}

# 造一个假的 ImageBuilder 工作目录（apk 布局：repositories + packages/ + keys/）
make_ib_apk() {
	ib="$TMPROOT/ib-$1"
	mkdir -p "$ib/packages"
	printf '%s\n' \
		'# imagebuilder repositories' \
		'https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/packages/packages.adb' \
		> "$ib/repositories"
	: > "$ib/packages/nikki-2026.10.10-r1.apk"
	: > "$ib/packages/luci-app-nikki-1.26.2-r1.apk"
	: > "$ib/packages/mihomo-meta-1.19.32.apk"
	printf '%s\n' "$ib"
}

# 造一个假的"镜像站"：站点根 + <branch>/<arch>/nikki/packages.adb
make_mirror() {
	m="$TMPROOT/mirror-$1"
	mkdir -p "$m/openwrt-25.12/x86_64/nikki"
	printf 'key-material\n' > "$m/public-key.pem"
	printf 'adb-index\n' > "$m/openwrt-25.12/x86_64/nikki/packages.adb"
	printf '%s\n' "$m"
}

run() { OUT=$("$@" 2>&1); RC=$?; say "rc=$RC"; [ "$VERBOSE" = 1 ] && printf '%s\n' "$OUT" | sed 's/^/      . /'; return 0; }

printf '被测脚本: %s\n' "$SUBJECT"
if [ ! -f "$SUBJECT" ]; then
	printf '  RED  %s 尚不存在（TDD 第一步：先让它红）\n' "$SUBJECT"
	exit 1
fi

# ---------------------------------------------------------------- 用例 1
CASE="1. --fallback：强制离线，只用内置 apk"
printf '\n[%s]\n' "$CASE"
IB=$(make_ib_apk fallback)
BEFORE=$(cat "$IB/repositories")
run env NIKKI_BASE_URL="http://127.0.0.1:1" sh "$SUBJECT" --workdir "$IB" --fallback
assert_eq "退出码 0（必须可继续构建）" 0 "$RC"
assert_contains "日志说明将使用内置 apk" "内置 apk" "$OUT"
assert_eq "repositories 未被改动" "$BEFORE" "$(cat "$IB/repositories")"
if [ -f "$IB/keys/nikki.pem" ]; then no "不该下载公钥"; else ok "没有下载公钥"; fi

# ---------------------------------------------------------------- 用例 2
CASE="2. 源不可达（连接被拒）：优雅回退"
printf '\n[%s]\n' "$CASE"
IB=$(make_ib_apk unreachable)
BEFORE=$(cat "$IB/repositories")
run env NIKKI_BASE_URL="http://127.0.0.1:1" sh "$SUBJECT" --workdir "$IB"
assert_eq "退出码 0" 0 "$RC"
assert_contains "日志说明回退" "回退" "$OUT"
assert_contains "日志说明将使用内置 apk" "内置 apk" "$OUT"
assert_eq "repositories 未被改动" "$BEFORE" "$(cat "$IB/repositories")"
if [ -f "$IB/keys/nikki.pem" ]; then no "不该留下公钥"; else ok "没有留下公钥"; fi

# ---------------------------------------------------------------- 用例 3
CASE="3. 本地镜像可达：写入公钥 + 追加源"
printf '\n[%s]\n' "$CASE"
IB=$(make_ib_apk mirror)
MIRROR=$(make_mirror ok)
run env NIKKI_BASE_URL="$MIRROR" sh "$SUBJECT" --workdir "$IB"
assert_eq "退出码 0" 0 "$RC"
assert_eq "公钥落到 keys/nikki.pem" "key-material" "$(cat "$IB/keys/nikki.pem" 2>/dev/null)"
assert_contains "日志声明接入成功" "接入" "$OUT"
assert_not_contains "不应回退" "回退" "$OUT"
LINES=$(grep -c 'openwrt-25.12/x86_64/nikki/packages.adb' "$IB/repositories")
assert_eq "repositories 追加恰好 1 行" 1 "$LINES"
assert_contains "原有官方源保留" "downloads.immortalwrt.org" "$(cat "$IB/repositories")"

# ---------------------------------------------------------------- 用例 4
CASE="4. 重复执行幂等：不产生重复源"
printf '\n[%s]\n' "$CASE"
run env NIKKI_BASE_URL="$MIRROR" sh "$SUBJECT" --workdir "$IB"
assert_eq "第二次退出码 0" 0 "$RC"
LINES=$(grep -c 'openwrt-25.12/x86_64/nikki/packages.adb' "$IB/repositories")
assert_eq "repositories 仍然只有 1 行 nikki 源" 1 "$LINES"

# ---------------------------------------------------------------- 用例 5
CASE="5. 源可达但取不到公钥：整体回退，不追加无签名源"
printf '\n[%s]\n' "$CASE"
IB=$(make_ib_apk nokey)
MIRROR_NOKEY=$(make_mirror nokey)
rm -f "$MIRROR_NOKEY/public-key.pem"
BEFORE=$(cat "$IB/repositories")
run env NIKKI_BASE_URL="$MIRROR_NOKEY" sh "$SUBJECT" --workdir "$IB"
assert_eq "退出码 0" 0 "$RC"
assert_contains "日志点出公钥问题" "公钥" "$OUT"
assert_contains "日志说明将使用内置 apk" "内置 apk" "$OUT"
assert_eq "repositories 未被改动" "$BEFORE" "$(cat "$IB/repositories")"
if [ -f "$IB/keys/nikki.pem" ]; then no "不该留下公钥"; else ok "没有留下公钥"; fi

# ---------------------------------------------------------------- 用例 6
CASE="6. opkg 布局（只有 repositories.conf）：追加 src/gz 行"
printf '\n[%s]\n' "$CASE"
IB="$TMPROOT/ib-opkg"
mkdir -p "$IB/packages"
printf '%s\n' 'src/gz immortalwrt_core https://downloads.immortalwrt.org/releases/24.10.0/targets/x86/64/packages' > "$IB/repositories.conf"
run env NIKKI_BASE_URL="$MIRROR" sh "$SUBJECT" --workdir "$IB"
assert_eq "退出码 0" 0 "$RC"
assert_contains "沿用 opkg 的 src/gz 语法" "src/gz nikki" "$(cat "$IB/repositories.conf")"
assert_contains "来源是镜像地址" "openwrt-25.12/x86_64/nikki" "$(cat "$IB/repositories.conf")"
if [ -f "$IB/repositories" ]; then no "不该凭空造出 apk 布局文件"; else ok "没有造出多余文件"; fi

# ---------------------------------------------------------------- 用例 7
CASE="7. --strict：源不可达时返回非 0"
printf '\n[%s]\n' "$CASE"
IB=$(make_ib_apk strict)
run env NIKKI_BASE_URL="http://127.0.0.1:1" sh "$SUBJECT" --workdir "$IB" --strict
if [ "$RC" -ne 0 ]; then ok "退出码非 0"; else no "应当非 0（得到 ${RC}）"; fi
assert_contains "仍然解释回退原因" "内置 apk" "$OUT"

printf '\n---------------- 结果: %d 通过, %d 失败 ----------------\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
