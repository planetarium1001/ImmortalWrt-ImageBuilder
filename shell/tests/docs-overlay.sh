#!/bin/sh
# ac-9：文档同步到 squashfs 只读根 + btrfs 子卷写层的现实。
#
# 断言的是**用户会照着做的字串**，不是含糊表述：产物名、首启重启、扩容作废、
# 升级约束、恢复出厂语义、/data 与 /mnt/data 分工。
# 这些点错一个字，真机上就是"照文档做结果全错"。
set -u
. "$(dirname "$0")/lib-assert.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALL=$ROOT/docs/install.md
OPS=$ROOT/docs/ops.md
README=$ROOT/README.md

for f in "$INSTALL" "$OPS" "$README"; do
	[ -s "$f" ] || { bad "缺少或为空: ${f#"$ROOT"/}"; finish DOCS-OVERLAY; }
done

txt() { cat "$1" 2>/dev/null; }
has() { contains "$2（$1）" "$2" "$(txt "$1")"; }
hasnt() { not_contains "$2（$1）" "$2" "$(txt "$1")"; }

echo "== 1. 产物与写层 =="
has "$INSTALL" 'squashfs-combined-efi'
hasnt "$INSTALL" 'ext4-combined-efi'
has "$README" 'squashfs-combined-efi'
hasnt "$README" 'ext4-combined-efi'
has "$INSTALL" '@overlay'
has "$INSTALL" 'btrfs'
has "$README" '@overlay'
has "$README" 'btrfs'

echo "== 2. 首启会重启一次 / 两次开机各做什么 =="
has "$INSTALL" '重启一次'
has "$INSTALL" '第二次开机'
has "$INSTALL" '95-overlay-setup.sh'
has "$INSTALL" 'overlay-setup.log'
has "$README" '重启一次'
# 三条已漂移的首启说法必须消失
hasnt "$INSTALL" 'wan.auto'
hasnt "$INSTALL" 'EEE'
hasnt "$INSTALL" 'n5105-router'
hasnt "$INSTALL" '扩根分区'

echo "== 3. 扩容章改成「不再需要 + 怎么确认 + 失败怎么重跑」=="
has "$INSTALL" '不需要扩容'
has "$INSTALL" 'df -h /overlay'
has "$INSTALL" 'btrfs subvolume list'
has "$INSTALL" 'overlay-setup --dry-run'
hasnt "$INSTALL" 'resizepart'
hasnt "$INSTALL" 'resize2fs'
hasnt "$README" 'resizepart'
hasnt "$README" 'resize2fs'
has "$README" '/mnt/data'

echo "== 4. 升级章（p3 是否保留）=="
has "$INSTALL" 'sysupgrade -T'
has "$INSTALL" 'Partition layout has changed'
has "$INSTALL" 'sysupgrade -p'
has "$INSTALL" 'luci-app-diskman'
has "$INSTALL" '不要再 resize'
has "$INSTALL" 'ROOTFS_PARTSIZE'

echo "== 5. 恢复出厂：firstboot/jffs2reset 作废，用 overlay-reset =="
has "$INSTALL" 'overlay-reset --yes'
has "$INSTALL" 'firstboot'
has "$INSTALL" 'jffs2reset'
has "$INSTALL" '无效'
has "$OPS" 'overlay-reset --yes'
has "$OPS" 'jffs2reset'
hasnt "$OPS" 'firstboot 那套不适用'
hasnt "$OPS" 'ext4 单分区根'

echo "== 6. 回滚四类 + 本期没有快照 =="
has "$OPS" '配置回滚'
has "$OPS" '固件回滚'
has "$OPS" '救砖'
has "$OPS" '清系统层'
has "$OPS" '本期没有快照'

echo "== 7. /data 与 /mnt/data 分工（池子共享、无配额）=="
has "$OPS" '/data'
has "$OPS" '/mnt/data'
has "$OPS" '@data'
has "$OPS" '配额'
has "$OPS" 'ENOSPC'
has "$README" '无配额'

echo "== 8. docker data_root 已在 @docker，不再教人 rsync =="
has "$OPS" 'data_root'
has "$OPS" '@docker'
has "$OPS" '不需要迁移'
hasnt "$OPS" 'rsync -a /opt/docker'

echo "== 9. 全文一致性：不再有 ext4 根/squashfs 产物二选一的旧说法 =="
hasnt "$README" '手工扩'
for f in "$INSTALL" "$OPS" "$README"; do
	hasnt "$f" '只读 squashfs 底层，所有写入落到 `/overlay` 分区'
done

finish DOCS-OVERLAY
