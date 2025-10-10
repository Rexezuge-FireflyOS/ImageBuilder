#!/usr/bin/env bash
set -euo pipefail

# 配置区（按需修改）
ROOTFS_DIR=$(pwd)/out/rootfs
# 移除了 IMAGE_FILE, IMAGE_SIZE_MB, MOUNT_POINT 等变量
PKG_LIST_FILE=config/package-list.txt
PACMAN_CONF=$(pwd)/pacman.conf.build

# 清理
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# =====================================================================
# 步骤 1：安装第三方仓库的 Keyring (不变)
# =====================================================================
BUILDER_USER="builduser"
KEYRING_NAME="alhp-keyring"
KEYRING_DIR=$(mktemp -d)
PKG_BUILD_DIR="$KEYRING_DIR/$KEYRING_NAME"

echo "-> 检查并安装 $KEYRING_NAME 从 AUR..."

useradd -m -s /bin/bash "$BUILDER_USER"
echo "-> 临时用户 $BUILDER_USER 创建成功。"

git clone https://aur.archlinux.org/alhp-keyring.git "$PKG_BUILD_DIR"
chown -R "$BUILDER_USER:$BUILDER_USER" "$KEYRING_DIR"

echo "-> 切换到 $BUILDER_USER 用户构建 $KEYRING_NAME..."
ALHP_SIGNING_KEY="8CA32F8BF3BC8088"
su "$BUILDER_USER" -c "
    set -euo pipefail; 
    cd \"$PKG_BUILD_DIR\" || exit 1; 
    echo '导入源码签名公钥 $ALHP_SIGNING_KEY...';
    gpg --keyserver keyserver.ubuntu.com --recv-keys $ALHP_SIGNING_KEY 2>/dev/null || \
    gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $ALHP_SIGNING_KEY || true;
    makepkg -s --noconfirm
"

cd "$PKG_BUILD_DIR"
ALHP_PKG=$(ls alhp-keyring-*.pkg.tar.zst 2>/dev/null | head -n 1)

if [ -f "$ALHP_PKG" ]; then
    echo "-> 找到包: $ALHP_PKG，正在以 root 身份安装..."
    pacman-key --init || true
    pacman -U "$ALHP_PKG" --noconfirm --needed
    ALHP_MAIN_KEY="BC3993A9EBDD40E5C242D72F0FE58E8D1B980E51"
    echo "-> 明确信任 ALHP GPG 密钥 $ALHP_MAIN_KEY..."
    pacman-key --lsign-key "$ALHP_MAIN_KEY"
else
    echo "错误: 未找到生成的 alhp-keyring 包！请检查 makepkg 输出。"
    exit 1
fi

cd - > /dev/null
userdel -r "$BUILDER_USER"
rm -rf "$KEYRING_DIR"
echo "-> $KEYRING_NAME 安装完成，GPG 密钥已导入到容器的 pacman 密钥环。"

# ==========================================================
# 步骤 2: 创建 RootFS (不变)
# ==========================================================
sudo mkdir -p "$ROOTFS_DIR/var/lib/pacman"
sudo pacman --noconfirm --noprogressbar -r "$ROOTFS_DIR" --config "$PACMAN_CONF" -Sy $(cat "$PKG_LIST_FILE")

# ==========================================================
# 步骤 3: 配置目标系统 (不变)
# ==========================================================
echo "==> Configuring the target system..."
sudo mkdir -p "$ROOTFS_DIR/etc"
sudo tee "$ROOTFS_DIR/etc/os-release" > /dev/null <<'EOF'
NAME="FireflyOS"
VERSION="$(date +%Y.%m)"
ID=arch
EOF
echo "mystable" | sudo tee "$ROOTFS_DIR/etc/hostname"

# ==========================================================
# 步骤 4: 清理 (移除打包和签名)
# ==========================================================
echo "==> Cleaning up package cache..."
# 清理 pacman 缓存以缩小镜像
sudo rm -rf "$ROOTFS_DIR/var/cache/pacman/pkg/*"

echo "RootFS directory is ready at $ROOTFS_DIR. Moving to host runner for disk image creation."
# 移除了 mksquashfs 和 GPG 签名步骤
