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

# =====================================================================
# 步骤 1：安装第三方仓库的 Keyring (在 Root 容器中，创建 Builder 用户)
# =====================================================================
BUILDER_USER="builduser" # 新建一个用户用于 makepkg
KEYRING_NAME="alhp-keyring"
KEYRING_DIR=$(mktemp -d)
PKG_BUILD_DIR="$KEYRING_DIR/$KEYRING_NAME"

echo "-> 检查并安装 $KEYRING_NAME 从 AUR..."

# 1. **创建临时非 root 用户** builduser
useradd -m -s /bin/bash "$BUILDER_USER"
echo "-> 临时用户 $BUILDER_USER 创建成功。"

# 2. 克隆 AUR 仓库
git clone https://aur.archlinux.org/alhp-keyring.git "$PKG_BUILD_DIR"

# 3. **切换到新用户 ($BUILDER_USER) **运行 makepkg -s
echo "-> 切换到 $BUILDER_USER 用户构建 $KEYRING_NAME..."

# 将构建目录的所有权转移给 builduser，这样 makepkg 才能写入
chown -R "$BUILDER_USER:$BUILDER_USER" "$PKG_BUILD_DIR"

# 使用 su 切换用户
su "$BUILDER_USER" -c "
    set -euo pipefail # 确保构建过程中任一命令失败即退出
    cd \"$PKG_BUILD_DIR\" || exit 1
    # -s: 同步依赖, --noconfirm: 非交互式
    makepkg -s --noconfirm
"

# 4. 找到生成的包文件名
# 此时我们再次切换回 root
cd "$PKG_BUILD_DIR"
ALHP_PKG=$(ls alhp-keyring-*.pkg.tar.zst 2>/dev/null | head -n 1)

# 5. **Root 用户**运行 pacman -U 安装包
if [ -f "$ALHP_PKG" ]; then
    echo "-> 找到包: $ALHP_PKG，正在以 root 身份安装..."
    # pacman -U 安装到主机系统 (即容器本身)，导入 GPG 密钥
    pacman -U "$ALHP_PKG" --noconfirm --needed
else
    echo "错误: 未找到生成的 alhp-keyring 包！请检查 makepkg 输出。"
    exit 1
fi

# 6. 清理临时用户、目录和文件
cd - > /dev/null
userdel -r "$BUILDER_USER"
rm -rf "$KEYRING_DIR"
echo "-> $KEYRING_NAME 安装完成，GPG 密钥已导入到容器的 pacman 密钥环。"

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
