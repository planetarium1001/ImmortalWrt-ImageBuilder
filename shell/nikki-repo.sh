#!/bin/sh
# 把 nikki 的上游 apk 源接进 ImageBuilder（在 ImageBuilder 解压目录内执行）。
#
# 为什么要接第三方源：ImmortalWrt 25.12.2 官方源没有 mihomo，而 nikki 硬依赖 mihomo；
# 只有 nikki 自己的 feed 同时提供 nikki / luci-app-nikki / mihomo-meta。
#
# 为什么必须"失败也返回 0"：这是构建流水线里的旁路步骤，第三方站点挂了不能把整个固件
# 构建拖死；拿不到源就退回 packages/ 里预置的 apk，功能不变、版本旧一点。
#
# 为什么公钥拿不到也整体回退（而不是照样追加源）：
# apk 装包时强制校验签名，源追加了但公钥缺失，构建必在 install 阶段失败；
# 与其留下一个"看起来接好了、实际装不上"的源，不如立刻回退并说清原因。
#
# 用法：
#   sh shell/nikki-repo.sh                      # 默认动作：探测 → 导公钥 → 追加源（失败自动回退）
#   sh shell/nikki-repo.sh --workdir /path/ib   # 指定 ImageBuilder 工作目录（默认当前目录）
#   sh shell/nikki-repo.sh --fallback           # 强制离线：不联网，直接用内置 apk
#   sh shell/nikki-repo.sh --strict             # 源不可达时返回非 0（给 CI 的显式严格模式）
#   sh shell/nikki-repo.sh --print              # 只打印将写入的源行，不落盘
#   sh shell/nikki-repo.sh --check              # 只探测可达性，不落盘
#
# 环境变量：
#   NIKKI_BASE_URL   站点根，默认 https://nikkinikki.pages.dev（公钥在根上，feed 在其下派生）
#   NIKKI_FEED_URL   直接指定 feed 目录，优先于派生结果（自建镜像/内网镜像时用）
#   NIKKI_BRANCH     feed 分支目录，默认 openwrt-25.12（对应 ImmortalWrt 25.12.x）
#   NIKKI_ARCH       包架构目录，默认 x86_64（N5105 是 x86-64）
#   IB_DIR           等价于 --workdir，默认 .
#   OFFLINE=1        等价于 --fallback
#
# 退出码：0 成功或已回退到内置 apk；1 仅 --strict 下源不可达；2 参数错误。

set -u

# ------------------------------------------------------------------ 默认值
# 站点根与 feed 分开：上游 feed.sh 里公钥取自站点根 public-key.pem，
# 而 packages.adb 在 <branch>/<arch>/nikki/ 下，两者不是同一目录，必须分开拼。
BASE_URL="${NIKKI_BASE_URL:-https://nikkinikki.pages.dev}"
FEED_URL="${NIKKI_FEED_URL:-}"
BRANCH="${NIKKI_BRANCH:-openwrt-25.12}"
ARCH="${NIKKI_ARCH:-x86_64}"
IB_DIR="${IB_DIR:-.}"
PKG_DIR="${NIKKI_PACKAGES_DIR:-}"
ACTION="apply"
OFFLINE="${OFFLINE:-0}"
STRICT=0

log() { printf '[nikki-repo] %s\n' "$*"; }
die() { printf '[nikki-repo] 错误：%s（试试 --help）\n' "$*" >&2; exit 2; }

# ------------------------------------------------------------------ 参数
while [ $# -gt 0 ]; do
	case "$1" in
		--workdir|--ib-dir) IB_DIR="${2:-}"; [ -n "$IB_DIR" ] || die "$1 需要目录参数"; shift 2 ;;
		--base-url) BASE_URL="${2:-}"; [ -n "$BASE_URL" ] || die "$1 需要 URL"; shift 2 ;;
		--feed-url) FEED_URL="${2:-}"; [ -n "$FEED_URL" ] || die "$1 需要 URL"; shift 2 ;;
		--branch) BRANCH="${2:-}"; [ -n "$BRANCH" ] || die "$1 需要分支名"; shift 2 ;;
		--arch) ARCH="${2:-}"; [ -n "$ARCH" ] || die "$1 需要架构名"; shift 2 ;;
		--packages-dir) PKG_DIR="${2:-}"; [ -n "$PKG_DIR" ] || die "$1 需要目录参数"; shift 2 ;;
		--fallback|--offline) OFFLINE=1; shift ;;
		--strict) STRICT=1; shift ;;
		--print) ACTION="print"; shift ;;
		--check) ACTION="check"; shift ;;
		--apply) ACTION="apply"; shift ;;
		-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "未知参数 $1" ;;
	esac
done

# 去掉尾部斜杠，避免拼出 //packages.adb 这种会被 CDN 拒掉的地址
BASE_URL=$(printf '%s' "$BASE_URL" | sed 's#/*$##')
[ -n "$FEED_URL" ] && FEED_URL=$(printf '%s' "$FEED_URL" | sed 's#/*$##')
# 没人显式给 feed 时按上游目录规则派生；这层派生让别的目标（如 aarch64）只改 ARCH 即可复用
[ -n "$FEED_URL" ] || FEED_URL="$BASE_URL/$BRANCH/$ARCH/nikki"
[ -n "$PKG_DIR" ] || PKG_DIR="$IB_DIR/packages"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nikki-repo.XXXXXX") || die "无法创建临时目录"
# shellcheck disable=SC2064
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# ------------------------------------------------------------------ 取文件
# 只在这一处接触"网络"，且支持本地目录与 file://：离线构建和桩测试都靠它把外部依赖
# 收窄成一个点，测试里换成临时目录就能验证全流程，不必真的出网。
fetch() {
	src=$1
	dst=$2
	case "$src" in
		file://*) cp -f "${src#file://}" "$dst" 2>/dev/null ;;
		/*) cp -f "$src" "$dst" 2>/dev/null ;;
		*)
			if command -v curl >/dev/null 2>&1; then
				# 连接与总时长都封顶：构建机上不允许一个卡死的第三方站点拖几分钟
				curl -fsSL --connect-timeout 5 --max-time 30 -o "$dst" "$src" 2>/dev/null
			elif command -v wget >/dev/null 2>&1; then
				wget -q -T 30 -O "$dst" "$src" 2>/dev/null
			else
				return 127
			fi
			;;
	esac
}

# ------------------------------------------------------------------ 回退
# 回退不算失败：说清为什么回退、内置 apk 在不在，然后返回 0 让构建继续跑。
fallback() {
	reason=$1
	log "回退：$reason"
	if [ -d "$PKG_DIR" ]; then
		# 只报不拦：packages/ 由 shell/apk-prepare-packages.sh 或人工预置，
		# 缺哪个包属于上层决策，这里喊出来便于比对版本即可。
		for name in nikki luci-app-nikki luci-i18n-nikki-zh-cn mihomo-meta; do
			hit=$(ls "$PKG_DIR" 2>/dev/null | grep -m1 "^${name}-.*\.apk\$" || true)
			if [ -n "$hit" ]; then
				log "  内置 apk 命中：$hit"
			else
				# 变量一律加花括号：全角括号的多字节字节会被某些 sh 当成变量名的一部分
				log "  内置 apk 缺失：${name}（需预置到 ${PKG_DIR}）"
			fi
		done
	else
		log "  内置 apk 目录不存在：$PKG_DIR"
	fi
	log "本次构建将使用内置 apk（不追加上游源），功能不变、版本可能略旧"
	[ "$STRICT" = "1" ] && return 1
	return 0
}

# ------------------------------------------------------------------ 探测
# 探测 packages.adb 而不是首页：只有索引真的在，apk 才解析得动；
# "站点活着但目录 404"这种情况也能被这一条判死。
probe_feed() {
	[ "$OFFLINE" = "1" ] && return 1
	fetch "$FEED_URL/packages.adb" "$TMP_DIR/packages.adb" || return 1
	[ -s "$TMP_DIR/packages.adb" ] || return 1
	return 0
}

# ------------------------------------------------------------------ 目标文件
# 25.12 的 ImageBuilder 是 apk 体系，仓库清单叫 repositories（一行一个 URL）；
# 24.10 及更早是 opkg 体系，叫 repositories.conf（src/gz 语法）。
# 按目录里实际存在的文件决定写哪里，避免把 opkg 语法写进 apk 清单。
detect_repo_file() {
	if [ -f "$IB_DIR/repositories" ]; then
		printf '%s\t%s\n' "apk" "$IB_DIR/repositories"
	elif [ -f "$IB_DIR/repositories.conf" ]; then
		printf '%s\t%s\n' "opkg" "$IB_DIR/repositories.conf"
	else
		return 1
	fi
}

repo_line() {
	c=$1
	if [ "$c" = "opkg" ]; then
		# opkg 要的是 feed 目录，装上后自己去取索引
		printf 'src/gz nikki %s\n' "$FEED_URL"
	else
		# apk 这一行要指到 packages.adb 本体（与上游 feed.sh 的写法一致）
		printf '%s/packages.adb\n' "$FEED_URL"
	fi
}

# ------------------------------------------------------------------ 主流程
if ! detected=$(detect_repo_file); then
	# 找不到清单说明 --workdir 指错或不是 ImageBuilder 目录；这种情况同样不该硬失败，
	# 上层按既有 PACKAGES 装包，最多是版本旧。
	fallback "找不到 $IB_DIR/repositories 或 $IB_DIR/repositories.conf，怀疑 --workdir 指错"
	exit $?
fi
REPO_MODE=${detected%%	*}
REPO_FILE=${detected#*	}

if [ "$ACTION" = "print" ]; then
	repo_line "$REPO_MODE"
	exit 0
fi

if [ "$ACTION" = "check" ]; then
	if probe_feed; then
		log "源可达：$FEED_URL/packages.adb"
		exit 0
	fi
	fallback "源不可达：$FEED_URL"
	exit $?
fi

# apply：探测 → 公钥 → 追加源；任一步失败即整体回退，不留半成品
if [ "$OFFLINE" = "1" ]; then
	fallback "显式离线模式（--fallback / OFFLINE=1），不访问网络"
	exit $?
fi

if ! probe_feed; then
	fallback "源不可达：$FEED_URL/packages.adb"
	exit $?
fi
log "源可达：$FEED_URL"

mkdir -p "$IB_DIR/keys" || true
KEY_DST="$IB_DIR/keys/nikki.pem"
if [ -s "$KEY_DST" ]; then
	log "公钥已存在，跳过下载：$KEY_DST"
elif fetch "$BASE_URL/public-key.pem" "$KEY_DST" && [ -s "$KEY_DST" ]; then
	# apk 按目录里的 *.pem 识别公钥；文件名与上游 feed.sh 保持一致，便于对照排查
	log "公钥导入：$KEY_DST"
else
	rm -f "$KEY_DST" 2>/dev/null || true
	fallback "公钥下载失败：$BASE_URL/public-key.pem（没有公钥，追加的来源装不上包）"
	exit $?
fi

line=$(repo_line "$REPO_MODE")
[ -f "$REPO_FILE" ] || : >"$REPO_FILE"
# 先剔除所有 nikki 旧行再追加：重复执行、或上游换过目录时都不会留下两份源。
# 用临时文件而不是 sed -i：BSD sed 与 GNU sed 对 -i 的用法不同，本脚本要能同时在
# 构建机（Linux）和开发机（macOS）上跑。
tmp_file="$REPO_FILE.nikki.tmp"
grep -v 'nikki' "$REPO_FILE" >"$tmp_file" 2>/dev/null || : >"$tmp_file"
printf '%s\n' "$line" >>"$tmp_file"
mv -f "$tmp_file" "$REPO_FILE"

log "接入成功（$REPO_MODE 布局）：$REPO_FILE 已追加 $line"
log "预置配置随 FILES 打包：/etc/nikki/mixin.yaml（白名单 mixin）、/etc/config/nikki（默认关闭）"
exit 0
