#!/bin/bash
# Complete Debian ISO Builder with Auto-Deploy to /home/pos/
# Includes ISO generation and deployment automation

set -e

# Configuration
ISO_NAME="sixthkendra"
BUILD_DIR="$HOME/debian-pos-iso"
VERSION="1.0"
HOSTNAME="pos"
POS_USER="pos"
POS_PASSWORD="    "  # 4 spaces
APP_DIR="/home/$POS_USER"

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
            sudo apt install -y live-build xorriso syslinux squashfs-tools genisoimage curl git
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

# Setup build environment
setup_build_env() {
    print_status "Setting up build environment..."
    
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    # Initialize live build
    lb config \
        --architectures amd64 \
        --distribution bookworm \
        --binary-images iso-hybrid \
        --system live \
        --apt-indices false \
        --cache false \
        --security false \
        --apt-recommends false \
        --firmware-binary false \
        --memtest none \
        --compression xz
    
    print_success "Build environment ready"
}

# Create package list
create_package_list() {
    print_status "Creating package list..."
    
    mkdir -p config/package-lists
    
    cat > config/package-lists/custom.list.chroot << 'EOF'
# Core system
linux-image-amd64
live-boot
systemd-sysv

# Networking
ifupdown
iproute2
net-tools
dnsutils
resolvconf

# Required tools
nano
sudo
curl
git
ca-certificates
gnupg
lsb-release

# Build essentials for Node.js
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
    
    print_success "Package list created"
}

# Create installation scripts
create_install_scripts() {
    print_status "Creating installation scripts..."
    
    mkdir -p config/hooks
    
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
    print_success "Installation scripts created"
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
    echo "pos:    " | chpasswd  # 4 spaces password
    usermod -aG sudo pos
    usermod -aG docker pos
    print_success "Created pos user with password: 4 spaces"
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
    print_warning "For private repositories, you need a GitHub Personal Access Token"
    print_warning "Create one at: https://github.com/settings/tokens"
    echo ""
    print_warning "Token must have 'repo' scope for private repositories"
    echo ""
    
    while true; do
        read -p "GitHub Username: " GITHUB_USER
        read -sp "GitHub Personal Access Token: " GITHUB_TOKEN
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
            read -p "Try again? (y/n): " -n 1 -r
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
    echo "Example: https://github.com/username/repository.git"
    echo ""
    
    read -p "Frontend Repository URL: " FRONTEND_REPO
    read -p "Backend Repository URL: " BACKEND_REPO
    
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
            print_warning "Please edit frontend .env file: nano /home/pos/frontend/.env"
        fi
        
        if [[ -f "entrypoint.sh" ]]; then
            chmod +x entrypoint.sh
            read -p "Run frontend entrypoint.sh? (y/n): " -n 1 -r
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
        print_warning "Please edit backend .env file: nano /home/pos/backend/.env"
        
        if [[ -f "entrypoint.sh" ]]; then
            chmod +x entrypoint.sh
            read -p "Run backend entrypoint.sh? (y/n): " -n 1 -r
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
  apps: [{
    name: 'pos-frontend',
    script: 'npm',
    args: 'start',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      PORT: 3000
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
                echo "Usage: $0 logs [frontend|backend]"
                ;;
        esac
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        ;;
esac
CONTROL_SCRIPT
    
    chmod +x /home/pos/control.sh
    
    print_success "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "1. Edit environment files:"
    [[ -d "/home/pos/frontend" ]] && echo "   nano /home/pos/frontend/.env"
    [[ -d "/home/pos/backend" ]] && echo "   nano /home/pos/backend/.env"
    echo "2. Start applications: /home/pos/control.sh start"
    echo "3. Check status: /home/pos/control.sh status"
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
    echo "pos:    " | chpasswd
    usermod -aG sudo pos
    usermod -aG docker pos
    print_success "Created user: pos (password: 4 spaces)"
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
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
DOCKER_CONFIG

# Create version check script
cat > /usr/local/bin/check-versions << 'CHECK_VERSIONS'
#!/bin/bash
echo "=== POS Debian System ==="
echo ""
echo "=== Versions ==="
echo "Node.js:     $(node --version 2>/dev/null || echo 'N/A')"
echo "npm:         $(npm --version 2>/dev/null || echo 'N/A')"
echo "pnpm:        $(pnpm --version 2>/dev/null || echo 'N/A')"
echo "Docker:      $(docker --version 2>/dev/null | awk '{print $3}' | head -1 || echo 'N/A')"
echo "Docker Compose:  $(docker-compose --version 2>/dev/null | awk '{print $3}' | head -1 || echo 'N/A')"
echo "WireGuard:   $(wg --version 2>/dev/null | awk '{print $1}' || echo 'N/A')"
echo "Tailscale:   $(tailscale version 2>/dev/null | head -1 | awk '{print $1}' || echo 'N/A')"
echo ""
echo "=== Services ==="
echo "Docker:      $(systemctl is-active docker)"
echo ""
echo "=== User Info ==="
echo "pos user:    pos/\"    \" (4 spaces)"
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
 • Node.js 22, npm, pnpm, PM2
 • Docker, Docker Compose
 • WireGuard, Tailscale

 Applications in: /home/pos/

 Quick Commands:
   deploy       - Run first-time setup
   check-versions - Show installed versions
   app-start    - Start applications
   app-status   - Check status

 User: pos (password: 4 spaces)

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

# Add system configurations
add_system_configs() {
    print_status "Adding system configurations..."
    
    # Hostname
    mkdir -p config/includes.chroot/etc
    echo "pos" > config/includes.chroot/etc/hostname
    
    # Hosts file
    cat > config/includes.chroot/etc/hosts << 'HOSTS'
127.0.0.1       localhost
127.0.1.1       pos

# IPv6
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS

    print_success "System configurations added"
}

# ISO GENERATION STEP
build_iso() {
    print_status "Starting ISO build process..."
    print_warning "This will take 20-40 minutes depending on your internet speed"
    echo ""
    
    # Start timer
    local start_time=$(date +%s)
    
    # Create lock file
    touch .lb_build_lock
    
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
        print_success "ISO Name:       $ISO_NAME"
        print_success "ISO Size:       $iso_size"
        print_success "Build Time:     ${minutes}m ${seconds}s"
        print_success "ISO Location:   $BUILD_DIR/live-image-amd64.hybrid.iso"
        echo ""
        
        # Create checksum
        sha256sum live-image-amd64.hybrid.iso > "$ISO_NAME.sha256"
        print_success "Checksum saved: $BUILD_DIR/$ISO_NAME.sha256"
        
        # Display ISO info
        echo ""
        print_status "ISO Information:"
        echo "──────────────────────────────────────────────────────"
        file live-image-amd64.hybrid.iso
        echo ""
        
        # Create test instructions
        cat > TEST_INSTRUCTIONS.md << 'INSTRUCTIONS'
# POS Debian ISO - Test Instructions

## ISO Details
- **Name**: $ISO_NAME
- **Size**: $iso_size
- **Built**: $(date)
- **Build Time**: ${minutes}m ${seconds}s

## Quick Test with QEMU
\`\`\`bash
# Install QEMU if needed
sudo apt install qemu-system-x86

# Test the ISO
qemu-system-x86_64 \
  -cdrom $BUILD_DIR/live-image-amd64.hybrid.iso \
  -m 2048 \
  -boot d \
  -nographic \
  -serial mon:stdio \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::2222-:22
\`\`\`
INSTRUCTIONS

    else
        print_error "ISO build failed"
        exit 1
    fi
}

# Main execution
main() {
    check_dependencies
    cleanup
    setup_build_env
    create_package_list
    create_install_scripts
    create_deployment_script
    create_firstboot_script
    add_system_configs
    build_iso
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
