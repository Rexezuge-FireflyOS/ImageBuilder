#!/usr/bin/env bash
set -euo pipefail

# 配置区（按需修改）
ROOTFS_DIR=$(pwd)/out/rootfs
IMAGE_FILE=$(pwd)/out/rootfs.squashfs
PKG_LIST_FILE=config/package-list.txt
PACMAN_CONF=$(pwd)/pacman.conf.build

# 清理
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 安装基础包（使用 pacstrap）
## 关键：创建 pacman 数据库目录
## 必须使用 sudo/root 权限创建，以确保后续 pacman 运行时有权限写入
sudo mkdir -p "$ROOTFS_DIR/var/lib/pacman"
sudo pacman --noconfirm --noprogressbar -r "$ROOTFS_DIR" --config "$PACMAN_CONF" -Sy $(cat "$PKG_LIST_FILE")

# 基本配置：os-release, locales, hostname, systemd services（按需扩展）
cat > "$ROOTFS_DIR/etc/os-release" <<EOF
NAME="MyStableOS"
VERSION="$(date +%Y.%m)"
ID=mystable
EOF

echo "mystable" | sudo tee "$ROOTFS_DIR/etc/hostname"

# 清理 pacman 缓存以缩小镜像
# 注意：arch-chroot 仍然需要 CAP_SYS_ADMIN 权限，这在无特权容器中仍然是问题！
# 您需要用更安全的方式替换 arch-chroot。
# 替代方案（如果您无法使用 arch-chroot）：
sudo rm -rf "$ROOTFS_DIR/var/cache/pacman/pkg/*" # 直接删除缓存文件，无需 chroot

# # 移除 arch-chroot 步骤（因为它在无特权容器中会失败）
# # sudo arch-chroot "$ROOTFS_DIR" pacman -Scc --noconfirm || true

# # 可选：删除 /var/cache/pacman/pkg 下的包等（如果您没有使用上面的 Scc 步骤）
# sudo rm -rf "$ROOTFS_DIR/var/cache/pacman/pkg/*" 

# 生成 squashfs（zstd 压缩）
mkdir -p "$(dirname "$IMAGE_FILE")"
sudo mksquashfs "$ROOTFS_DIR" "$IMAGE_FILE" -comp zstd -b 1M -noappend -Xcompression-level 19

# GPG 签名（CI 中使用非交互式 gpg）
gpg --detach-sign --armor --local-user "$GPG_KEY" -o "${IMAGE_FILE}.sig" "$IMAGE_FILE"

echo "Built $IMAGE_FILE and signature ${IMAGE_FILE}.sig"
