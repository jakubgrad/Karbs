#!/bin/bash
set -e  # Exit on error

dotfilesrepo="https://github.com/jakubgrad/wayrice"
progsfile="https://raw.githubusercontent.com/jakubgrad/Karbs/master/progs_ubuntu.csv"
repobranch="master"
REPODIR="$HOME/.local/src"

# --- Color definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Pre-flight checks ---
echo -e "${RED}[REQUIREMENTS]${NC} This script is meant to be run as a regular user with sudo privileges."
echo -e "${YELLOW}It is recommended to run it on a fresh user as it may overwrite config files.${NC}"

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}[ERROR]${NC} You are running as root. Please run as a normal user."
    exit 1
fi

if ! sudo -v; then
    echo -e "${RED}[ERROR]${NC} User does not have sudo privileges."
    exit 1
fi

# --- Temporary sudo passwordless ---
echo -e "${BLUE}[INFO]${NC} Temporarily disabling sudo password prompts for installation..."
trap 'sudo rm -f /etc/sudoers.d/karbs-installer-temp' EXIT
echo "%sudo ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/karbs-installer-temp > /dev/null

# --- Update package list ---
echo -e "${BLUE}[INFO]${NC} Updating package list..."
sudo apt update -y

# --- Functions ---

# Install from apt - now reads ubuntu package directly from CSV
install_apt() {
    local arch_pkg="$1"
    local ubuntu_pkg="$2"
    echo -e "${BLUE}[INFO]${NC} Installing $arch_pkg (→ $ubuntu_pkg)..."
    sudo apt install -y "$ubuntu_pkg" || echo -e "${YELLOW}[WARN]${NC} Failed to install $arch_pkg"
}

# Build and install from source (for 'S' tag)
install_source() {
    local repo_url="$1"
    local repo_name="$2"
    echo -e "${BLUE}[INFO]${NC} Building $repo_name from source..."
    mkdir -p "$REPODIR"
    cd "$REPODIR"
    
    # Get the actual repo name from the URL (e.g., xdg-desktop-portal-wlr-plus-filechooser)
    actual_repo_name=$(basename "$repo_url" .git)
    
    # Delete existing directory if it exists
    if [ -d "$actual_repo_name" ]; then
        echo -e "${YELLOW}[WARN]${NC} $actual_repo_name already exists. Deleting and re-cloning..."
        rm -rf "$actual_repo_name"
    fi
    
    # Fresh clone
    git clone --depth 1 "$repo_url"
    cd "$actual_repo_name"
    
    # Build
    if [ -f "meson.build" ]; then
        meson setup build || meson setup build --reconfigure
        ninja -C build
        sudo ninja -C build install
    elif [ -f "Makefile" ]; then
        make
        sudo make install
    else
        echo -e "${YELLOW}[WARN]${NC} No known build system for $repo_name"
    fi
    sudo ldconfig
    cd "$HOME"
}

# Install special cases (e.g., keyd, wlroots) - now reads arch package name
install_special() {
    local arch_pkg="$1"
    case "$arch_pkg" in
        "keyd-git")
            echo -e "${BLUE}[INFO]${NC} Building keyd from source..."
            cd "$REPODIR"
            git clone --depth 1 https://github.com/rvaiya/keyd.git || (cd keyd && git pull)
            cd keyd
            make
            sudo make install
            sudo systemctl enable keyd
            sudo systemctl start keyd
            cd "$HOME"
            ;;
            "atuin")
            echo -e "${BLUE}[INFO]${NC} Installing atuin via snap..."
            sudo snap install atuin
            ;;
        "wlroots-git")
            echo -e "${BLUE}[INFO]${NC} Installing wlroots 0.20 from source..."
            cd "$REPODIR"
            wget -q https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/0.20.0/wlroots-0.20.0.tar.gz
            tar -xzf wlroots-0.20.0.tar.gz
            cd wlroots-0.20.0
            meson setup build/ --prefix=/usr/local
            ninja -C build/
            sudo ninja -C build/ install
            sudo ldconfig
            cd "$HOME"
            ;;
        *)
            echo -e "${YELLOW}[WARN]${NC} No special handler for $arch_pkg"
            ;;
    esac
}

# Clone and set up dotfiles
putgitrepo() {
    echo -e "${BLUE}[INFO]${NC} Cloning dotfiles..."
    local tmpdir=$(mktemp -d)
    git clone --depth 1 --recursive -b "$repobranch" "$dotfilesrepo" "$tmpdir"
    cp -rfT "$tmpdir" "$HOME"
    rm -rf "$tmpdir"
    rm -f "$HOME/README.md" "$HOME/LICENSE" "$HOME/FUNDING.yml"
}

# Install default wallpapers
installdefaultwallpapers() {
    local wallpaperspath="$HOME/.local/share/wallpapers"
    mkdir -p "$wallpaperspath"
    for img in wallpaper_dark.jpg wallpaper_light.jpg lock_wallpaper_light.jpg lock_wallpaper_dark.jpg; do
        curl -Ls "https://raw.githubusercontent.com/jakubgrad/Karbs/master/wallpapers/$img" > "$wallpaperspath/$img"
    done
}

# Firefox extensions setup
browsersetup() {
    echo -e "${BLUE}[INFO]${NC} Setting up Firefox extensions..."
    local browserdir="$HOME/.mozilla/firefox"
    local profilesini="$browserdir/profiles.ini"
    mkdir -p "$browserdir"
    firefox --headless &
    sleep 3
    pkill firefox
    local profile=$(sed -n "/Default=.*.default-\(default\|release\)/ s/.*=//p" "$profilesini" 2>/dev/null || echo "")
    if [ -z "$profile" ]; then
        echo -e "${YELLOW}[WARN]${NC} Could not find Firefox profile. Skipping extensions."
        return
    fi
    local pdir="$browserdir/$profile"
    local addonlist="ublock-origin localcdn-fork-of-decentraleyes istilldontcareaboutcookies libredirect darkreader"
    local addontmp=$(mktemp -d)
    mkdir -p "$pdir/extensions/"
    for addon in $addonlist; do
        local addonurl=$(curl -s "https://addons.mozilla.org/en-US/firefox/addon/${addon}/" | grep -o 'https://addons.mozilla.org/firefox/downloads/file/[^"]*' | head -1)
        if [ -n "$addonurl" ]; then
            local file="${addonurl##*/}"
            curl -Lso "$addontmp/$file" "$addonurl"
            local id=$(unzip -p "$addontmp/$file" manifest.json | grep '"id"' | head -1 | sed 's/.*"id": "\(.*\)".*/\1/')
            mv "$addontmp/$file" "$pdir/extensions/$id.xpi"
        fi
    done
    rm -rf "$addontmp"
}

# --- Main installation loop ---
installationloop() {
    echo -e "${BLUE}[INFO]${NC} Downloading program list..."
    curl -Ls "$progsfile" | sed '/^#/d' > /tmp/progs.csv
    local total=$(wc -l < /tmp/progs.csv)
    local n=0
    while IFS=, read -r tag program comment; do
        n=$((n + 1))
        comment=$(echo "$comment" | sed -E 's/^"|"$//g')
        
        # Split program field to get arch package and ubuntu package
        arch_pkg=$(echo "$program" | cut -d'|' -f1)
        ubuntu_pkg=$(echo "$program" | cut -d'|' -f2)
        
        echo -e "${GREEN}[$n/$total]${NC} Processing: $arch_pkg ($comment)"
        
        case "$tag" in
            "A")
                # AUR package: try apt with ubuntu_pkg, fallback to special build
                if [ -n "$ubuntu_pkg" ] && [ "$ubuntu_pkg" != "$arch_pkg" ]; then
                    install_apt "$arch_pkg" "$ubuntu_pkg"
                else
                    install_special "$arch_pkg"
                fi
                ;;
            "S")
                # Source package: use the ubuntu_pkg as the repo name (since it's a git URL)
                install_source "$arch_pkg" "$ubuntu_pkg"
                ;;
            *)
                # Regular package: install from apt
                install_apt "$arch_pkg" "$ubuntu_pkg"
                ;;
        esac
    done < /tmp/progs.csv
    rm -f /tmp/progs.csv
}

# --- Run the installation ---

echo -e "${BLUE}[INFO]${NC} Installing core dependencies..."
sudo apt install -y curl ca-certificates build-essential git ntp \
    meson ninja-build pkg-config libwayland-dev wayland-protocols \
    libegl1-mesa-dev libgles2-mesa-dev libdrm-dev libgbm-dev \
    libinput-dev libxkbcommon-dev libudev-dev libpixman-1-dev \
    libseat-dev libliftoff-dev libdisplay-info-dev \
    libxcb1-dev libxcb-icccm4-dev libxcb-xfixes0-dev \
    libxcb-composite0-dev libxcb-ewmh-dev libxcb-res0-dev \
    libxcb-xinput-dev libxcb-xkb-dev

# Clone dotfiles
putgitrepo

# Create directories
mkdir -p "$HOME/.cache/zsh" \
         "$HOME/.config/abook" \
         "$HOME/.local/share/captures/rec" \
         "$HOME/atm" "$HOME/doc" "$HOME/edu" "$HOME/inc" \
         "$HOME/med/movies" "$HOME/med/music" "$HOME/med/pics" "$HOME/med/series" \
         "$HOME/src"

# Wallpapers
installdefaultwallpapers

# Prepare source directory
mkdir -p "$REPODIR"

# Run the main installation loop
installationloop | tee -a karbs-install.log

# Firefox extensions
browsersetup

# Keyd configuration (if installed)
if command -v keyd >/dev/null 2>&1; then
    sudo mkdir -p /etc/keyd
    sudo ln -sf "$HOME/.config/keyd/default.conf" /etc/keyd/default.conf
fi

# Set default editor
echo "Defaults editor=/usr/bin/nvim" | sudo tee /etc/sudoers.d/01-karbs-visudo-editor > /dev/null

# Change default shell to zsh
if command -v zsh >/dev/null 2>&1; then
    echo -e "${BLUE}[INFO]${NC} Changing default shell to zsh..."
    sudo chsh -s "$(which zsh)" "$(whoami)"
fi

# Cleanup
sudo rm -f /etc/sudoers.d/karbs-installer-temp

echo -e "${GREEN}========================================="
echo "✅ karbs for Ubuntu installation complete!"
echo "=========================================${NC}"
echo ""
echo -e "${YELLOW}Please log out and log back in for all changes to take effect.${NC}"
echo "Then start dwl from a TTY with: dwl"
