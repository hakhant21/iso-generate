#!/bin/bash
# Fixed Debian ISO Builder with Corrected Package Names
# Includes ISO generation and deployment automation

set -e

# Configuration
ISO_NAME="sixthkendra"
BUILD_DIR="$HOME/debian-pos-iso"
VERSION="1.0"
HOSTNAME="pos"
POS_USER="pos"
POS_PASSWORD="    "  # 4 spaces

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions
print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# Check dependencies
check_dependencies() {
    print_status "Checking dependencies..."
    
    local missing_deps=()
    for cmd in sudo lb xorriso mkisofs curl git; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_warning "Missing dependencies: ${missing_deps[*]}"
        read -p "Install missing dependencies? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt update
            sudo apt install -y live-build xorriso syslinux squashfs-tools genisoimage curl git \
                dosfstools mtools syslinux-common syslinux-efi grub-efi-amd64-bin grub-pc-bin
        else
            print_error "Cannot proceed without dependencies"
            exit 1
        fi
    fi
    print_success "All dependencies satisfied"
}

# Cleanup
cleanup() {
    print_status "Cleaning up previous build..."
    if [[ -d "$BUILD_DIR" ]]; then
        cd "$BUILD_DIR"
        if [[ -f .lb_build_lock ]]; then
            sudo lb clean --all 2>/dev/null || true
        fi
        cd ..
        rm -rf "$BUILD_DIR"
    fi
    print_success "Cleanup complete"
}

# Setup build environment - SIMPLIFIED CONFIGURATION
setup_build_env() {
    print_status "Setting up build environment..."
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # SIMPLIFIED lb config - minimal options first
    lb config \
        --architectures amd64 \
        --distribution bookworm \
        --binary-images iso-hybrid \
        --system live \
        --bootappend-live "boot=live components nomodeset" \
        --apt-indices false \
        --cache false \
        --security false \
        --apt-recommends true \
        --memtest none \
        --compression gzip
    
    print_success "Build environment ready"
}

# Create package list - CORRECTED PACKAGE NAMES
create_package_list() {
    print_status "Creating package list with correct package names..."
    
    mkdir -p config/package-lists
    
    cat > config/package-lists/custom.list.chroot << 'EOF'
# CRITICAL: Essential boot packages (CORRECTED NAMES)
live-boot
live-boot-initramfs-tools
live-config
live-config-systemd
systemd-sysv

# Linux kernel (CORRECT NAME)
linux-image-amd64

# Firmware (CORRECT NAMES - Debian 12 uses different names)
firmware-linux-free
firmware-linux-nonfree
intel-microcode
amd64-microcode

# Initramfs tools
initramfs-tools

# Bootloader (CORRECT NAMES)
grub-efi-amd64
grub-efi-amd64-bin
grub-pc-bin
grub2-common
efibootmgr

# Filesystem support
dosfstools
mtools
squashfs-tools

# Core system
sudo
curl
git
ca-certificates
gnupg
lsb-release

# Networking
network-manager
net-tools
dnsutils
resolvconf

# Required tools
nano
build-essential
python3
python3-pip

# WireGuard
wireguard
wireguard-tools

# System tools
procps
htop
ufw
jq
unzip
tree
EOF
    
    # Create minimal boot configuration
    mkdir -p config/includes.chroot/etc/default
    
    cat > config/includes.chroot/etc/default/grub << 'GRUB_CONFIG'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="POS Debian"
GRUB_CMDLINE_LINUX_DEFAULT="quiet nomodeset"
GRUB_CMDLINE_LINUX="boot=live components"
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=true
GRUB_CONFIG
    
    print_success "Package list created with correct names"
}

# Create boot configuration
create_boot_config() {
    print_status "Creating boot configuration files..."
    
    # Create syslinux configuration for BIOS boot
    mkdir -p config/bootloaders/syslinux
    cat > config/bootloaders/syslinux/syslinux.cfg << 'SYSLINUX_CFG'
DEFAULT live
LABEL live
  MENU LABEL Live System
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components nomodeset quiet
  TIMEOUT 50
SYSLINUX_CFG
    
    # Create simple preseed for automation
    mkdir -p config/includes.installer
    cat > config/includes.installer/preseed.cfg << 'PRESEED'
# Minimal preseed for live system
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i passwd/root-login boolean false
d-i passwd/user-fullname string POS User
d-i passwd/username string pos
d-i passwd/user-password password    
d-i passwd/user-password-again password    
d-i user-setup/allow-password-weak boolean true
PRESEED
    
    print_success "Boot configuration created"
}

# Create installation scripts
create_install_scripts() {
    print_status "Creating installation scripts..."
    
    mkdir -p config/hooks
    
    # 1. First hook - basic system setup
    cat > config/hooks/001-basic-setup.chroot << 'BASIC_SETUP'
#!/bin/bash
set -e
echo "[*] Running basic system setup..."

# Set hostname
echo "pos" > /etc/hostname
hostname pos

# Update package list
apt-get update

# Create pos user
if ! id -u pos >/dev/null 2>&1; then
    useradd -m -s /bin/bash pos
    echo "pos:      " | chpasswd
    usermod -aG sudo pos
fi

echo "[+] Basic setup complete"
BASIC_SETUP

    # 2. Docker installation (simplified)
    cat > config/hooks/010-install-docker.chroot << 'DOCKER_SCRIPT'
#!/bin/bash
set -e
echo "[*] Installing Docker..."
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker pos
echo "[+] Docker installed"
DOCKER_SCRIPT

    # 3. Node.js installation (direct, no nvm)
    cat > config/hooks/020-install-nodejs.chroot << 'NODE_SCRIPT'
#!/bin/bash
set -e
echo "[*] Installing Node.js..."
# Use NodeSource repository for Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
npm install -g npm@latest
npm install -g pm2
# Install pnpm
corepack enable
corepack prepare pnpm@latest --activate
echo "[+] Node.js installed"
NODE_SCRIPT

    # 4. Tailscale installation
    cat > config/hooks/030-install-tailscale.chroot << 'TAILSCALE_SCRIPT'
#!/bin/bash
set -e
echo "[*] Installing Tailscale..."
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" | tee /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale
echo "[+] Tailscale installed"
TAILSCALE_SCRIPT

    # 5. Final setup - GRUB and cleanup
    cat > config/hooks/900-final-setup.chroot << 'FINAL_SETUP'
#!/bin/bash
set -e
echo "[*] Running final setup..."

# Update GRUB
update-grub 2>/dev/null || true

# Enable Docker
systemctl enable docker

# Create motd
cat > /etc/motd << 'MOTD_EOF'
╔═════════════════════════════════�════════╗
║          POS Debian System               ║
╚══════════════════════════════════════════╝

User: pos (password: 4 spaces)

Quick commands:
  docker ps      - List containers
  pm2 list       - List Node.js apps
  tailscale up   - Connect to Tailscale
MOTD_EOF

# Cleanup
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[+] Final setup complete"
FINAL_SETUP

    chmod +x config/hooks/*.chroot
    print_success "Installation scripts created"
}

# Create deployment script (simplified)
create_deployment_script() {
    print_status "Creating deployment scripts..."
    
    cat > config/hooks/800-deploy-apps.chroot << 'DEPLOY_SCRIPT'
#!/bin/bash
set -e
echo "[*] Setting up deployment..."

# Create deployment directory
mkdir -p /home/pos/deploy
chown -R pos:pos /home/pos

# Create simple setup script
cat > /home/pos/setup.sh << 'SETUP_EOF'
#!/bin/bash
echo "POS System Setup"
echo "================"
echo ""
echo "1. Docker is installed and running"
echo "2. Node.js 22 is installed"
echo "3. Tailscale is ready"
echo ""
echo "To deploy your apps:"
echo "  cd /home/pos"
echo "  git clone "
echo ""
SETUP_EOF

chmod +x /home/pos/setup.sh
chown pos:pos /home/pos/setup.sh

echo "[+] Deployment setup complete"
DEPLOY_SCRIPT

    chmod +x config/hooks/800-deploy-apps.chroot
    print_success "Deployment scripts created"
}

# Build ISO function
build_iso() {
    print_status "Starting ISO build process..."
    print_warning "This may take 15-30 minutes"
    echo ""
    
    local start_time=$(date +%s)
    
    # Build the ISO
    if sudo lb build 2>&1 | tee build.log; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local minutes=$((duration / 60))
        local seconds=$((duration % 60))
        
        if [[ -f "live-image-amd64.hybrid.iso" ]]; then
            local iso_size=$(du -h live-image-amd64.hybrid.iso | cut -f1)
            
            print_success "═══════════════════════════════════════════════════════════"
            print_success "                    ISO BUILD SUCCESSFUL                    "
            print_success "═══════════════════════════════════════════════════════════"
            echo ""
            print_success "ISO Name:        $ISO_NAME"
            print_success "ISO Size:        $iso_size"
            print_success "Build Time:      ${minutes}m ${seconds}s"
            print_success "Location:        $BUILD_DIR/live-image-amd64.hybrid.iso"
            echo ""
            
            # Create checksum
            sha256sum live-image-amd64.hybrid.iso > "$ISO_NAME.sha256"
            
            # Test ISO structure
            print_status "Verifying ISO structure..."
            if command -v isoinfo >/dev/null 2>&1; then
                if isoinfo -i live-image-amd64.hybrid.iso -l | grep -q "live/vmlinuz"; then
                    print_success "✓ Boot kernel found"
                else
                    print_warning "⚠ Kernel not found in ISO"
                fi
            fi
            
            # Create test instructions
            cat > TEST_INSTRUCTIONS.txt << 'INSTRUCTIONS'
TEST INSTRUCTIONS:
==================

1. Test in QEMU:
   qemu-system-x86_64 -cdrom live-image-amd64.hybrid.iso -m 2048 -boot d

2. Create USB:
   sudo dd if=live-image-amd64.hybrid.iso of=/dev/sdX bs=4M status=progress
   sudo sync

3. Boot troubleshooting:
   - If blinking cursor: Try different USB port (USB 2.0)
   - In BIOS: Disable Secure Boot, enable Legacy/CSM if needed
   - At boot menu: Press Tab, add "nomodeset" to kernel parameters

ISO INFO:
- User: pos
- Password: 4 spaces
- Installed: Docker, Node.js 22, Tailscale
INSTRUCTIONS
            
            print_success "Test instructions saved to TEST_INSTRUCTIONS.txt"
        else
            print_error "ISO file not created"
            exit 1
        fi
    else
        print_error "ISO build failed!"
        echo ""
        print_status "Last 20 lines of build log:"
        tail -20 build.log
        exit 1
    fi
}

# Main execution
main() {
    echo "╔══════════════════════════════════════════╗"
    echo "║   POS Debian ISO Builder (Fixed)         ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    
    # Step 1: Check dependencies
    check_dependencies
    
    # Step 2: Cleanup
    cleanup
    
    # Step 3: Setup build environment
    setup_build_env
    
    # Step 4: Create package list
    create_package_list
    
    # Step 5: Create boot config
    create_boot_config
    
    # Step 6: Create install scripts
    create_install_scripts
    
    # Step 7: Create deployment script
    create_deployment_script
    
    # Step 8: Build ISO
    build_iso
    
    echo ""
    print_success "Build complete! Next steps:"
    echo "  1. Test ISO: qemu-system-x86_64 -cdrom '$BUILD_DIR/live-image-amd64.hybrid.iso' -m 2048"
    echo "  2. Create USB: sudo dd if='$BUILD_DIR/live-image-amd64.hybrid.iso' of=/dev/sdX bs=4M status=progress"
    echo "  3. Boot from USB and login as 'pos' (password: 4 spaces)"
    echo ""
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
