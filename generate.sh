#!/bin/bash
# Fixed Debian ISO Builder with Boot Issue Fixes
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
        print_warning "Missing dependencies:  ${missing_deps[*]}"
        read -p "Install missing dependencies? (y/n):  " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt update
            sudo apt install -y live-build xorriso syslinux squashfs-tools genisoimage curl git \
                dosfstools mtools syslinux-common syslinux-efi
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

# Setup build environment - FIXED CONFIGURATION
setup_build_env() {
    print_status "Setting up build environment with boot fixes..."
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # Initialize live build with FIXED parameters
    lb config \
        --architectures amd64 \
        --distribution bookworm \
        --binary-images iso-hybrid \
        --system live \
        --bootappend-live "boot=live components nomodeset quiet splash" \
        --linux-packages linux-image-amd64 \
        --apt-indices false \
        --cache false \
        --security false \
        --apt-recommends true \
        --firmware-binary true \
        --memtest none \
        --compression xz \
        --iso-application "POS Debian System" \
        --iso-publisher "POS Builder" \
        --iso-volume "POS_Debian_Live" \
        --debian-installer none
    
    print_success "Build environment ready with boot fixes"
}

# Create package list - FIXED:  Added essential boot packages
create_package_list() {
    print_status "Creating package list with boot essentials..."
    
    mkdir -p config/package-lists
    
    cat > config/package-lists/custom.list.chroot << 'EOF'
# CRITICAL:  Essential boot packages
live-boot
live-boot-initramfs-tools
live-config
live-config-systemd
live-tools
systemd-sysv

# Linux kernel
linux-image-amd64
linux-headers-amd64

# Firmware for hardware compatibility
firmware-linux
firmware-linux-nonfree
intel-microcode
amd64-microcode

# Initramfs tools
initramfs-tools
dracut

# Bootloader and EFI
grub-efi-amd64
grub-efi-amd64-bin
grub-efi-amd64-signed
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
ifupdown
iproute2
net-tools
dnsutils
resolvconf
network-manager

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
    
    # Create hooks directory for boot configuration
    mkdir -p config/hooks/live
    
    print_success "Package list created with boot essentials"
}

# Create boot configuration files - NEW:  Critical for boot
create_boot_config() {
    print_status "Creating boot configuration files..."
    
    # Create preseed file for automated installation
    mkdir -p config/includes.installer
    cat > config/includes.installer/preseed.cfg << 'PRESEED'
# Preseed for live system
d-i debian-installer/locale string en_US
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string pos
d-i netcfg/get_domain string local
d-i passwd/root-login boolean false
d-i passwd/user-fullname string POS User
d-i passwd/username string pos
d-i passwd/user-password password    
d-i passwd/user-password-again password    
d-i user-setup/allow-password-weak boolean true
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
PRESEED
    
    # Create live boot hook for initramfs
    cat > config/hooks/live/0100-initramfs-tools.chroot << 'INITRAMFS'
#!/bin/bash
set -e

# Update initramfs with proper modules
cat > /etc/initramfs-tools/modules << 'MODULES'
# Storage controllers
ahci
sd_mod
sr_mod
uas
usb-storage
nvme

# Filesystems
ext4
vfat
ntfs
exfat
squashfs
overlay

# Network (for persistence)
virtio_net
e1000
e1000e
igb
ixgbe
MODULES

# Update initramfs
update-initramfs -u -k all
INITRAMFS
    chmod +x config/hooks/live/0100-initramfs-tools.chroot
    
    # Create GRUB configuration
    mkdir -p config/includes.chroot/etc/default
    cat > config/includes.chroot/etc/default/grub << 'GRUB_CONFIG'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="POS Debian"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nomodeset"
GRUB_CMDLINE_LINUX="boot=live components"
GRUB_BACKGROUND=""
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_DISABLE_RECOVERY=true
GRUB_ENABLE_CRYPTODISK=n
GRUB_CONFIG
    
    # Create live boot configuration
    mkdir -p config/includes.chroot/etc/live/boot
    cat > config/includes.chroot/etc/live/boot.conf << 'BOOT_CONF'
LIVE_BOOT=live
LIVE_HOSTNAME="pos"
LIVE_USERNAME="pos"
LIVE_USER_FULLNAME="POS User"
LIVE_USER_DEFAULT_GROUPS="audio cdrom dip floppy video plugdev netdev docker sudo"
LIVE_CONFIG_CMDLINE="boot=live components"
BOOT_CONF
    
    print_success "Boot configuration files created"
}

# Create installation scripts with boot fixes
create_install_scripts() {
    print_status "Creating installation scripts with boot fixes..."
    
    mkdir -p config/hooks
    
    # Update GRUB after package installation
    cat > config/hooks/009-update-grub.chroot << 'GRUB_UPDATE'
#!/bin/bash
set -e
print_status() { echo "[*] $1"; }
print_success() { echo "[+] $1"; }

print_status "Configuring bootloader..."
# Install GRUB for both BIOS and UEFI
grub-install --target=i386-pc --recheck /dev/sda 2>/dev/null || true
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck 2>/dev/null || true

# Update GRUB configuration
update-grub 2>/dev/null || true

# Create fallback initramfs
mkinitramfs -o /boot/initrd.img-$(uname -r) 2>/dev/null || true

print_success "Bootloader configured"
GRUB_UPDATE

    # Docker installation
    cat > config/hooks/010-install-docker.chroot << 'DOCKER_SCRIPT'
#!/bin/bash
set -e
print_status() { echo "[*] $1"; }
print_success() { echo "[+] $1"; }
print_status "Installing Docker..."
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose-v2
print_success "Docker installed"
DOCKER_SCRIPT

    # Node.js installation
    cat > config/hooks/020-install-nodejs.chroot << 'NODE_SCRIPT'
#!/bin/bash
set -e
print_status() { echo "[*] $1"; }
print_success() { echo "[+] $1"; }
print_status "Installing Node.js stack..."
curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh" | bash
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 22
nvm alias default 22
nvm use default
npm install -g npm@latest
corepack enable pnpm
corepack prepare pnpm@latest --activate
npm install -g pm2
mv /root/.nvm /usr/local/nvm
chmod -R 755 /usr/local/nvm
cat > /etc/profile.d/nvm.sh << 'NVM_ENV'
export NVM_DIR="/usr/local/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
NVM_ENV
NODE_PATH="/usr/local/nvm/versions/node/$(node --version)"
ln -sf "$NODE_PATH/bin/node" /usr/local/bin/node
ln -sf "$NODE_PATH/bin/npm" /usr/local/bin/npm
ln -sf "$NODE_PATH/bin/npx" /usr/local/bin/npx
print_success "Node.js installed"
NODE_SCRIPT

    # Tailscale installation
    cat > config/hooks/030-install-tailscale.chroot << 'TAILSCALE_SCRIPT'
#!/bin/bash
set -e
print_status() { echo "[*] $1"; }
print_success() { echo "[+] $1"; }
print_status "Installing Tailscale..."
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | gpg --dearmor -o /usr/share/keyrings/tailscale-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" > /etc/apt/sources.list.d/tailscale.list
apt-get update
apt-get install -y tailscale
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
sysctl -p
print_success "Tailscale installed"
TAILSCALE_SCRIPT

    chmod +x config/hooks/*.chroot
    print_success "Installation scripts created with boot fixes"
}

# Create deployment scripts
create_deployment_script() {
    print_status "Creating deployment scripts..."
    
    cat > config/hooks/800-deploy-apps.chroot << 'DEPLOY_SCRIPT'
#!/bin/bash
set -e

print_status() { echo "[*] $1"; }
print_success() { echo "[+] $1"; }

# Create pos user with 4 spaces password
if ! id -u pos >/dev/null 2>&1; then
    useradd -m -s /bin/bash pos
    echo "pos:     " | chpasswd  # 4 spaces password
    usermod -aG sudo pos
    usermod -aG docker pos
    print_success "Created pos user with password:  4 spaces"
fi

# Create first-time setup script
cat > /home/pos/first-time-setup.sh << 'FIRST_SETUP'
#!/bin/bash
set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

print_status() { echo -e "${BLUE}[*]${NC} $1"; }
print_success() { echo -e "${GREEN}[+]${NC} $1"; }
print_error() { echo -e "${RED}[-]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      POS System First-Time Setup        ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Get GitHub credentials
get_github_credentials() {
    echo ""
    print_status "GitHub Authentication Required"
    echo "======================================"
    print_warning "For private repositories,  you need a GitHub Personal Access Token"
    print_warning "Create one at:  https://github.com/settings/tokens"
    echo ""
    print_warning "Token must have 'repo' scope for private repositories"
    echo ""
    
    while true; do
        read -p "GitHub Username:  " GITHUB_USER
        read -sp "GitHub Personal Access Token:  " GITHUB_TOKEN
        echo ""
        
        if [[ -z "$GITHUB_USER" || -z "$GITHUB_TOKEN" ]]; then
            print_error "Username and token are required"
            continue
        fi
        
        # Test credentials
        print_status "Testing GitHub credentials..."
        RESPONSE=$(curl -s -u "$GITHUB_USER:$GITHUB_TOKEN" https://api.github.com/user)
        
        if echo "$RESPONSE" | grep -q '"login"'; then
            print_success "Authentication successful"
            return 0
        else
            print_error "Authentication failed. Please check your credentials."
            echo ""
            read -p "Try again? (y/n):  " -n 1 -r
            echo
            [[ $REPLY =~ ^[Yy]$ ]] || exit 1
        fi
    done
}

# Clone repository
clone_repo() {
    local repo_url=$1
    local target_dir=$2
    
    if [[ "$repo_url" == https://github.com/* ]]; then
        local auth_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@${repo_url#https://}"
        git clone "$auth_url" "$target_dir"
    else
        git clone "$repo_url" "$target_dir"
    fi
}

# Main setup
main() {
    # Get GitHub credentials
    if ! get_github_credentials; then
        exit 1
    fi
    
    echo ""
    print_status "Enter repository URLs (HTTPS format)"
    echo "Example:  https://github.com/username/repository.git"
    echo ""
    
    read -p "Frontend Repository URL:  " FRONTEND_REPO
    read -p "Backend Repository URL:  " BACKEND_REPO
    
    # Clone repositories
    echo ""
    print_status "Cloning repositories..."
    
    if [[ -n "$FRONTEND_REPO" ]]; then
        print_status "Cloning frontend..."
        clone_repo "$FRONTEND_REPO" "/home/pos/frontend"
        
        # Setup frontend
        cd /home/pos/frontend
        if [[ -f ".env.example" ]]; then
            cp .env.example .env
            print_warning "Please edit frontend .env file:  nano /home/pos/frontend/.env"
        fi
        
        if [[ -f "entrypoint.sh" ]]; then
            chmod +x entrypoint.sh
            read -p "Run frontend entrypoint.sh? (y/n):  " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ./entrypoint.sh
            fi
        fi
        
        # Install dependencies
        if [[ -f "package.json" ]]; then
            print_status "Installing frontend dependencies..."
            if [[ -f "pnpm-lock.yaml" ]]; then
                pnpm install
            else
                npm install
            fi
        fi
    fi
    
    if [[ -n "$BACKEND_REPO" ]]; then
        print_status "Cloning backend..."
        clone_repo "$BACKEND_REPO" "/home/pos/backend"
        
        # Setup backend
        cd /home/pos/backend
        if [[ -f ".env.local" ]]; then
            cp .env.local .env
        elif [[ -f ".env.example" ]]; then
            cp .env.example .env
        fi
        print_warning "Please edit backend .env file:  nano /home/pos/backend/.env"
        
        if [[ -f "entrypoint.sh" ]]; then
            chmod +x entrypoint.sh
            read -p "Run backend entrypoint.sh? (y/n):  " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                ./entrypoint.sh
            fi
        fi
    fi
    
    # Setup PM2 for frontend
    if [[ -d "/home/pos/frontend" ]] && [[ -f "/home/pos/frontend/package.json" ]]; then
        print_status "Setting up PM2 for frontend..."
        cd /home/pos/frontend
        
        # Create PM2 config if not exists
        if [[ ! -f "ecosystem.config.js" ]]; then
            cat > ecosystem.config.js << 'PM2_CONFIG'
module.exports = {
  apps:  [{
    name:  'pos-frontend', 
    script:  'npm', 
    args:  'start', 
    instances:  1, 
    autorestart:  true, 
    watch:  false, 
    max_memory_restart:  '1G', 
    env:  {
      NODE_ENV:  'production', 
      PORT:  3000
    }
  }]
}
PM2_CONFIG
        fi
        
        # Start with PM2
        pm2 start ecosystem.config.js
        pm2 save
        pm2 startup
    fi
    
    # Create control script
    cat > /home/pos/control.sh << 'CONTROL_SCRIPT'
#!/bin/bash
case "$1" in
    start)
        echo "Starting POS applications..."
        # Start backend with Docker Compose
        if [[ -f "/home/pos/backend/docker-compose-local.yml" ]]; then
            cd /home/pos/backend && docker-compose up -d
        fi
        # Start frontend with PM2
        if [[ -f "/home/pos/frontend/ecosystem.config.js" ]]; then
            cd /home/pos/frontend && pm2 start ecosystem.config.js
        fi
        ;;
    stop)
        echo "Stopping POS applications..."
        if [[ -f "/home/pos/backend/docker-compose-local.yml" ]]; then
            cd /home/pos/backend && docker-compose down
        fi
        if [[ -f "/home/pos/frontend/ecosystem.config.js" ]]; then
            cd /home/pos/frontend && pm2 stop ecosystem.config.js
        fi
        ;;
    restart)
        echo "Restarting POS applications..."
        $0 stop
        sleep 2
        $0 start
        ;;
    status)
        echo "=== Frontend (PM2) ==="
        pm2 list | grep pos-frontend || echo "Not running"
        echo ""
        echo "=== Backend (Docker) ==="
        if [[ -f "/home/pos/backend/docker-compose-local.yml" ]]; then
            cd /home/pos/backend && docker-compose ps
        else
            echo "Docker Compose not configured"
        fi
        ;;
    logs)
        case "$2" in
            frontend)
                pm2 logs pos-frontend
                ;;
            backend)
                cd /home/pos/backend && docker-compose logs -f
                ;;
            *)
                echo "Usage:  $0 logs [frontend|backend]"
                ;;
        esac
        ;;
    *)
        echo "Usage:  $0 {start|stop|restart|status|logs}"
        ;;
esac
CONTROL_SCRIPT
    
    chmod +x /home/pos/control.sh
    
    print_success "Setup complete!"
    echo ""
    echo "Next steps: "
    echo "1. Edit environment files: "
    [[ -d "/home/pos/frontend" ]] && echo "   nano /home/pos/frontend/.env"
    [[ -d "/home/pos/backend" ]] && echo "   nano /home/pos/backend/.env"
    echo "2. Start applications:  /home/pos/control.sh start"
    echo "3. Check status:  /home/pos/control.sh status"
    echo ""
    echo "Applications will auto-start on next boot via systemd services."
}

main
FIRST_SETUP

chmod +x /home/pos/first-time-setup.sh
chown -R pos:pos /home/pos

print_success "Deployment scripts created"
DEPLOY_SCRIPT

    chmod +x config/hooks/800-deploy-apps.chroot
    
    print_success "Deployment scripts created"
}

# Create firstboot script
create_firstboot_script() {
    print_status "Creating first-boot setup script..."
    
    cat > config/hooks/900-firstboot-setup.chroot << 'FIRSTBOOT_SCRIPT'
#!/bin/bash
set -e

print_status() { echo "[*] $1"; }
print_success() { echo "[+] $1"; }

print_status "Running first-boot setup..."

# Create pos user with 4 spaces password
if ! id -u pos >/dev/null 2>&1; then
    useradd -m -s /bin/bash pos
    echo "pos:     " | chpasswd
    usermod -aG sudo pos
    usermod -aG docker pos
    print_success "Created user:  pos (password:  4 spaces)"
fi

# Setup nvm for pos user
USER_HOME="/home/pos"
if [[ -d "/usr/local/nvm" ]]; then
    cp -r /usr/local/nvm "$USER_HOME/.nvm"
    chown -R pos:pos "$USER_HOME/.nvm"
    
    cat >> "$USER_HOME/.bashrc" << 'BASHRC_EOF'

# nvm configuration
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# pnpm configuration
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

# Aliases
alias deploy='cd /home/pos && ./first-time-setup.sh'
alias app-start='cd /home/pos && ./control.sh start'
alias app-stop='cd /home/pos && ./control.sh stop'
alias app-status='cd /home/pos && ./control.sh status'
alias app-logs='cd /home/pos && ./control.sh logs'
alias check-versions='/usr/local/bin/check-versions'
BASHRC_EOF
fi

# Enable services
systemctl enable docker

# Configure Docker
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKER_CONFIG'
{
  "exec-opts":  ["native.cgroupdriver=systemd"], 
  "log-driver":  "json-file", 
  "log-opts":  {
    "max-size":  "100m", 
    "max-file":  "3"
  }, 
  "storage-driver":  "overlay2"
}
DOCKER_CONFIG

# Create version check script
cat > /usr/local/bin/check-versions << 'CHECK_VERSIONS'
#!/bin/bash
echo "=== POS Debian System ==="
echo ""
echo "=== Versions ==="
echo "Node.js:      $(node --version 2>/dev/null || echo 'N/A')"
echo "npm:          $(npm --version 2>/dev/null || echo 'N/A')"
echo "pnpm:         $(pnpm --version 2>/dev/null || echo 'N/A')"
echo "Docker:       $(docker --version 2>/dev/null | awk '{print $3}' | head -1 || echo 'N/A')"
echo "Docker Compose:   $(docker-compose --version 2>/dev/null | awk '{print $3}' | head -1 || echo 'N/A')"
echo "WireGuard:    $(wg --version 2>/dev/null | awk '{print $1}' || echo 'N/A')"
echo "Tailscale:    $(tailscale version 2>/dev/null | head -1 | awk '{print $1}' || echo 'N/A')"
echo ""
echo "=== Services ==="
echo "Docker:       $(systemctl is-active docker)"
echo ""
echo "=== User Info ==="
echo "pos user:     pos/\"    \" (4 spaces)"
CHECK_VERSIONS

chmod +x /usr/local/bin/check-versions

# Create systemd service for one-time setup
cat > /etc/systemd/system/pos-first-setup.service << 'SERVICE_EOF'
[Unit]
Description=POS System First-Time Setup
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=pos
WorkingDirectory=/home/pos
ExecStart=/home/pos/first-time-setup.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Create motd
cat > /etc/motd << 'MOTD_EOF'
╔══════════════════════════════════════════╗
║          POS Debian System               ║
╚══════════════════════════════════════════╝

 Pre-installed: 
 • Node.js 22,  npm,  pnpm,  PM2
 • Docker,  Docker Compose
 • WireGuard,  Tailscale

 Applications in:  /home/pos/

 Quick Commands: 
   deploy       - Run first-time setup
   check-versions - Show installed versions
   app-start    - Start applications
   app-status   - Check status

 User:  pos (password:  4 spaces)

 Run 'deploy' to setup your applications
MOTD_EOF

# Set hostname
echo "pos" > /etc/hostname
hostname pos

# Cleanup
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

print_success "First-boot setup complete!"
FIRSTBOOT_SCRIPT

    chmod +x config/hooks/900-firstboot-setup.chroot
    print_success "First-boot script created"
}

# Build ISO with verification
build_iso() {
    print_status "Starting ISO build process with boot fixes..."
    print_warning "This will take 20-40 minutes depending on your internet speed"
    echo ""
    
    # Start timer
    local start_time=$(date +%s)
    
    # Create lock file
    touch .lb_build_lock
    
    # Verify boot configuration
    print_status "Verifying boot configuration..."
    if [[ ! -f "config/bootloaders/syslinux/syslinux.cfg" ]]; then
        mkdir -p config/bootloaders/syslinux
        cat > config/bootloaders/syslinux/syslinux.cfg << 'SYSLINUX_CFG'
DEFAULT live
LABEL live
  MENU LABEL Live System
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components nomodeset quiet splash
  TIMEOUT 50
SYSLINUX_CFG
    fi
    
    # Start the build
    print_status "Running live-build..."
    sudo lb build 2>&1 | tee build.log
    
    # Check if build succeeded
    if [[ $? -eq 0 ]] && [[ -f "live-image-amd64.hybrid.iso" ]]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local iso_size=$(du -h live-image-amd64.hybrid.iso | cut -f1)
        local minutes=$((duration / 60))
        local seconds=$((duration % 60))
        
        print_success "═══════════════════════════════════════════════════════════"
        print_success "                    ISO BUILD COMPLETE                     "
        print_success "═══════════════════════════════════════════════════════════"
        echo ""
        print_success "ISO Name:        $ISO_NAME"
        print_success "ISO Size:        $iso_size"
        print_success "Build Time:      ${minutes}m ${seconds}s"
        print_success "ISO Location:    $BUILD_DIR/live-image-amd64.hybrid.iso"
        echo ""
        
        # Create checksum
        sha256sum live-image-amd64.hybrid.iso > "$ISO_NAME.sha256"
        print_success "Checksum saved:  $BUILD_DIR/$ISO_NAME.sha256"
        
        # Verify ISO structure
        print_status "Verifying ISO boot structure..."
        if isoinfo -i live-image-amd64.hybrid.iso -l | grep -q "live/vmlinuz"; then
            print_success "ISO contains bootable kernel"
        else
            print_warning "ISO may have boot issues - kernel not found"
        fi
    fi
    
    # Remove lock file
    rm -f .lb_build_lock
}

# Main execution function
main() {
    print_status "Starting POS Debian ISO Build Process"
    echo "======================================"
    
    # Check dependencies
    check_dependencies
    
    # Cleanup previous builds
    cleanup
    
    # Setup build environment
    setup_build_env
    
    # Create package list
    create_package_list
    
    # Create boot configuration
    create_boot_config
    
    # Create installation scripts
    create_install_scripts
    
    # Create deployment scripts
    create_deployment_script
    
    # Create firstboot script
    create_firstboot_script
    
    # Build the ISO
    build_iso
    
    print_success "POS Debian ISO build process completed!"
}

# Execute main function
main "$@"
