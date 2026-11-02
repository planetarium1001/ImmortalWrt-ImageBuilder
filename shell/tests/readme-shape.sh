#!/bin/sh
# ac-5：README 含上游链接、关系声明与文档索引，且不夹带其它机型
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
R="$ROOT/README.md"
FAIL=0

[ -s "$R" ] || { echo "FAIL: README 缺失或为空"; exit 1; }

need() { if grep -q "$1" "$R"; then echo "ok: $2"; else echo "FAIL: 缺少 $2"; FAIL=1; fi; }
need "wukongdaily/AutoBuildImmortalWrt" "上游仓库链接"
need "README.upstream.md" "上游 README 链接"
need "ImmortalWrt" "ImmortalWrt 来源说明"
need "与 ImmortalWrt 官方无关" "责任边界声明"
need "x86-64/docs/n5105/" "文档索引"
need "内置软件" "内置软件章节"
need "packages.md" "内置软件文档链接"
need "GPL-2.0" "许可声明"
need "25.12.2" "固件版本"
need "i226" "目标网卡"

# 不允许出现其它机型/平台字样，防止裁剪回潮
for kw in 树莓派 Rockchip 全志 斐讯N1 GL.iNet MT798; do
	if grep -q "$kw" "$R"; then echo "FAIL: README 出现无关机型关键词 $kw"; FAIL=1; fi
done
[ "$FAIL" = "0" ] && echo "ok: 无无关机型关键词"

# 索引里的文档必须真实存在
for f in install ruijie network ops compliance packages README; do
	[ -s "$ROOT/x86-64/docs/n5105/$f.md" ] || { echo "FAIL: 文档缺失 $f.md"; FAIL=1; }
done
echo "ok: 文档索引指向的文件均存在"

[ "$FAIL" = "0" ] && echo "README OK" || echo "README FAILED"
exit $FAIL
