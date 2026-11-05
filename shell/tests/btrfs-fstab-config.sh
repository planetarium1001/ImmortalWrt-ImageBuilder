#!/bin/sh
# ac-4：extroot 配置（files/etc/config/fstab）静态断言。
#
# 为什么这么严：block.c 用 `vlist_add(&mounts, &m->node, m->uuid|label|device)` 存段，
# 而 mounts_update() 是空函数 ⇒ 同 label/uuid/device 的第二段会**静默顶掉**第一段；
# mount_device() 对同一设备也只认一段 mount。所以 fstab 里只能有一段 mount。
# 另外 compress=/space_cache=/discard= 是**整个文件系统共享**的挂载参数
# （官方文档：shared among all mounts of the same filesystem），只有在 preinit
# 首次挂载（extroot 那一段）上写才有效，后续子卷挂载只能带 noatime,subvol=…
set -u
. "$(dirname "$0")/lib-assert.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
F=$ROOT/files/etc/config/fstab

if [ ! -f "$F" ]; then
	echo "BTRFS-FSTAB-CONFIG FAILED"
	echo "  缺少 $F"
	exit 1
fi

# 去掉注释与空行后的"生效文本"：注释里提到子卷名不算违规
live=$(grep -vE '^[[:space:]]*(#|$)' "$F")

# 输出 "段名<TAB>键<TAB>值"（只取 mount 段；去引号）
mount_opts() {
	awk -v q="'" '
		function clean(s) { gsub(q, "", s); gsub(/"/, "", s); return s }
		/^[ \t]*#/ { next }
		/^[ \t]*config[ \t]+/ {
			typ = clean($2); name = clean($3)
			inmount = (typ == "mount")
			cur = name
			next
		}
		inmount && $1 == "option" { print cur "\t" clean($2) "\t" clean($3) }
	' "$F"
}

# 某个 mount 段里某个键的值（同键多值时取最后一条，与 libuci 一致）
mval() { mount_opts | awk -F'\t' -v k="$2" '$2 == k { v = $3 } END { print v }'; }

# global 段的取值
gval() {
	awk -v q="'" -v k="$1" '
		function clean(s) { gsub(q, "", s); gsub(/"/, "", s); return s }
		/^[ \t]*#/ { next }
		/^[ \t]*config[ \t]+/ { ing = (clean($2) == "global"); next }
		ing && $1 == "option" { if (clean($2) == k) v = clean($3) }
		END { print v }
	' "$F"
}

echo "== 段结构 =="
nsec=$(printf '%s\n' "$live" | grep -cE '^[[:space:]]*config[[:space:]]+mount')
eq "config mount 恰有一段" '1' "$nsec"
eq "唯一 mount 段 target 是 /overlay" '/overlay' "$(mval overlay target)"
eq "用 label 定位（不写死 /dev/sdX）" 'wrt-overlay' "$(mval overlay label)"
eq "fstype 是 btrfs（block 白名单含 btrfs）" 'btrfs' "$(mval overlay fstype)"
eq "段已启用" '1' "$(mval overlay enabled)"
not_contains "不使用 /dev/ 设备路径（SATA/NVMe 命名不同、fs UUID 首启才有）" '/dev/' "$live"
not_contains "不引用文件系统 uuid（首启才生成，无法预烘）" 'option uuid' "$live"

echo "== fs 级参数只写在首次挂载这一段 =="
opts=$(mval overlay options)
contains "含 subvol=@overlay" 'subvol=@overlay' "$opts"
contains "含 noatime" 'noatime' "$opts"
contains "含 compress=zstd:1" 'compress=zstd:1' "$opts"
contains "含 space_cache=v2" 'space_cache=v2' "$opts"
contains "含 discard=async" 'discard=async' "$opts"
not_contains "不写挂载级 nodatacow（NOCOW 只能靠 chattr +C）" 'nodatacow' "$opts"
not_contains "不写 discard=async 之外的自定义 discard" 'discard=sync' "$opts"

echo "== 其余子卷不进 fstab（同设备只能一段 mount）=="
not_contains "不含 @docker" '@docker' "$live"
not_contains "不含 @swap" '@swap' "$live"
not_contains "不含 @data" '@data' "$live"

echo "== 段去重键（uuid|label|device）=="
dups=$(mount_opts |
	awk -F'\t' '$2 == "label" || $2 == "uuid" || $2 == "device" { print $2 "=" $3 }' |
	sort | uniq -d)
eq "任意两段不共用 label/uuid/device" '' "$dups"

echo "== global 段 =="
nglob=$(printf '%s\n' "$live" | grep -cE '^[[:space:]]*config[[:space:]]+global')
eq "有 config global 段" '1' "$nglob"
delay=$(gval delay_root)
case "$delay" in
''|*[!0-9]*) bad "delay_root 是数字（实际 [${delay}]）" ;;
*) [ "$delay" -ge 5 ] && ok "delay_root >= 5（${delay}）" || bad "delay_root 必须 >= 5（实际 ${delay}）" ;;
esac
eq "anon_mount 关闭（只认显式段）" '0' "$(gval anon_mount)"
eq "auto_mount 开启" '1' "$(gval auto_mount)"
eq "check_fs 关闭" '0' "$(gval check_fs)"

finish BTRFS-FSTAB-CONFIG
