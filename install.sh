#!/usr/bin/env bash
# ==============================================================================
# Loaf Installation, Update, Uninstall & Run Script
#
# Official install:
#   curl -sSL https://raw.githubusercontent.com/m-uvex/loaf-fm/main/install.sh | bash
#
# Local:
#   ./install.sh [try|install|update|uninstall]
#
# Environment variables:
#   LOAF_OS_SPOOF  Override /etc/os-release ID for testing (e.g. LOAF_OS_SPOOF=ubuntu)
#   PREFIX         Install prefix for tarball installs (default: $HOME/.local)
#
# Release asset naming contract (v0.2.0 is the reference release):
#   deb:     loaf_<version>_<amd64|arm64>.deb
#   pacman:  loaf-<version>-1-<x86_64|aarch64>.pkg.tar.zst
#   rpm:     loaf-<version>-1.*.<x86_64|aarch64>.rpm
#   tarball: loaf-v<version>-linux-<x86_64|aarch64>.tar.gz
#   version = release tag without the leading "v"
# ==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "This installer requires bash. Run: curl -sSL ... | bash" >&2
    exit 1
fi

set -e

REPO="m-uvex/loaf-fm"
GITHUB="https://github.com"
API="https://api.github.com"

RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[38;5:38m'
AMBER='\033[38;5:214m'
GREEN='\033[38;5:78m'
RED='\033[38;5:203m'
MUTED='\033[38;5:246m'

print_banner() {
    echo -e "${AMBER}${BOLD}"
    echo "___       ________  ________  ________ "
    echo "|\  \     |\   __  \|\   __  \|\  _____\:"
    echo "\ \  \    \ \  \|\  \ \  \|\  \ \  \__/ "
    echo " \ \  \    \ \  \\\  \ \   __  \ \   __\ "
    echo "  \ \  \____\ \  \\\  \ \  \ \  \ \  \_| "
    echo "   \ \_______\ \_______\ \__\ \__\ \__\ "
    echo "    \|_______|\|_______|\|__|\|__|\|__| "
    echo -e "${RESET}${DIM} Loaf Package Manager${RESET}"
    echo -e "${MUTED} ----------------------------------------${RESET}"
}

# ==============================================================================
# Environment detection
# ==============================================================================
detect_os() {
    OS_LIKE=""
    if [ -n "$LOAF_OS_SPOOF" ]; then
        echo -e "${AMBER}[!] OS Spoofer active: spoofing ID as '$LOAF_OS_SPOOF'${RESET}"
        OS_ID="$LOAF_OS_SPOOF"
        OS_NAME="Spoofed $LOAF_OS_SPOOF"
        return
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-$ID}"
        OS_LIKE="${ID_LIKE:-}"
    elif [ "$(uname)" = "Darwin" ]; then
        OS_ID="macos"
        OS_NAME="macOS"
    else
        OS_ID="unknown"
        OS_NAME="Unknown OS"
    fi
}

check_nixos() {
    if [ "$OS_ID" = "nixos" ]; then
        echo -e "\n${RED}================================================================${RESET}"
        echo -e "${RED}${BOLD}  NixOS Detected (${OS_NAME})${RESET}"
        echo -e "${RED}================================================================${RESET}"
        echo -e "NixOS manages software declaratively and uses a read-only root file system."
        echo -e "Automated binary installation via curl scripts is not supported on NixOS."
        echo -e ""
        echo -e "To install Loaf on NixOS, please follow the NixOS installation guide"
        echo -e "in the repository README or add Loaf to your configuration.nix / flake.nix."
        echo -e "${RED}================================================================${RESET}"
        exit 1
    fi
}

detect_arch() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)  BINARY_ARCH="x86_64"; DEB_ARCH="amd64" ;;
        aarch64|arm64) BINARY_ARCH="aarch64"; DEB_ARCH="arm64" ;;
        *)
            echo -e "${RED}Error: Unsupported architecture: $ARCH${RESET}"
            exit 1
            ;;
    esac
}

# Map the distro (ID, then ID_LIKE) to a native package family.
detect_pkg_family() {
    PKG_FAMILY="none"      # deb | rpm | pacman | none
    RPM_FRONTEND="dnf"     # dnf | zypper

    local probe
    for probe in "$OS_ID" $OS_LIKE; do
        case "$probe" in
            debian|ubuntu|linuxmint|pop|elementary|kali|raspbian|neon|zorin)
                PKG_FAMILY="deb"; break ;;
            arch|archlinux|manjaro|endeavouros|cachyos|artix|garuda)
                PKG_FAMILY="pacman"; break ;;
            fedora)
                PKG_FAMILY="rpm"; RPM_FRONTEND="dnf"; break ;;
            rhel|centos|rocky|almalinux|nobara)
                PKG_FAMILY="rpm"; RPM_FRONTEND="dnf"; break ;;
            opensuse*|sles|suse)
                PKG_FAMILY="rpm"; RPM_FRONTEND="zypper"; break ;;
        esac
    done
}

# TTY detection: piped via curl|bash means stdin IS the script, so we must
# never read choices from stdin. Prefer /dev/tty, else stdin if it is a
# terminal, else run non-interactively.
detect_tty() {
    TTY_FILE=""
    if (exec 3<>/dev/tty) 2>/dev/null; then
        TTY_FILE="/dev/tty"
    elif [ -t 0 ]; then
        TTY_FILE="/dev/stdin"
    fi
}

# Read one line from the TTY into REPLY. Returns 1 when non-interactive.
menu_read() {
    local prompt="$1"
    if [ -z "$TTY_FILE" ]; then
        return 1
    fi
    printf "%s" "$prompt"
    read -r REPLY < "$TTY_FILE" || return 1
}

determine_prefix() {
    if [ "$1" = "--system" ] || [ "$EUID" -eq 0 ]; then
        PREFIX="${PREFIX:-/usr/local}"
    else
        PREFIX="${PREFIX:-$HOME/.local}"
    fi
}

# Run a command with root rights (native packages live in /usr).
as_root() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo -e "${RED}Error: '$1' needs root rights, but neither root nor 'sudo' is available.${RESET}"
        exit 1
    fi
}

# True when Loaf is present via the native package manager or on disk.
check_installed() {
    case "$PKG_FAMILY" in
        deb)    command -v dpkg >/dev/null 2>&1 && dpkg -s loaf >/dev/null 2>&1 && return 0 ;;
        rpm)    command -v rpm >/dev/null 2>&1 && rpm -q loaf >/dev/null 2>&1 && return 0 ;;
        pacman) command -v pacman >/dev/null 2>&1 && pacman -Q loaf >/dev/null 2>&1 && return 0 ;;
    esac
    [ -f "$PREFIX/bin/loaf" ]
}

# ==============================================================================
# Interactive selection (arrow keys via gum when possible, numbered fallback)
# ==============================================================================
GUM_DIR=""
cleanup_gum() {
    [ -n "$GUM_DIR" ] && rm -rf "$GUM_DIR" 2>/dev/null
    return 0
}

setup_gum() {
    if command -v gum >/dev/null 2>&1; then
        GUM_BIN="$(command -v gum)"
        return 0
    fi

    local gum_os="linux" gum_arch="x86_64"
    [ "$(uname)" = "Darwin" ] && gum_os="darwin"
    case "$(uname -m)" in
        aarch64|arm64) gum_arch="arm64" ;;
    esac

    local gum_version="v0.14.0"
    local url="$GITHUB/charmbracelet/gum/releases/download/${gum_version}/gum_${gum_version#v}_${gum_os}_${gum_arch}.tar.gz"

    echo -e "${CYAN}[*] Fetching interactive menu tool (gum)...${RESET}"
    GUM_DIR="$(mktemp -d)"
    if curl -fsSL --max-time 30 "$url" -o "$GUM_DIR/gum.tar.gz" 2>/dev/null \
        && tar -xzf "$GUM_DIR/gum.tar.gz" -C "$GUM_DIR" 2>/dev/null; then
        GUM_BIN="$(find "$GUM_DIR" -type f -name gum 2>/dev/null | head -n 1)"
        if [ -n "$GUM_BIN" ] && [ -f "$GUM_BIN" ]; then
            return 0
        fi
    fi
    rm -rf "$GUM_DIR" 2>/dev/null
    GUM_DIR=""
    GUM_BIN=""
    return 1
}

# interactive_choose "Prompt" "Option A" "Option B" ...
# Sets SELECTED_INDEX / SELECTED_VALUE. Never fatal on tool failure.
interactive_choose() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    SELECTED_INDEX=-1
    SELECTED_VALUE=""

    if [ -n "$TTY_FILE" ] && setup_gum; then
        local select_cmd=("$GUM_BIN" choose --header="$prompt" "${options[@]}")
        if [ "$TTY_FILE" = "/dev/tty" ]; then
            SELECTED_VALUE="$("${select_cmd[@]}" < /dev/tty 2>/dev/null || true)"
        else
            SELECTED_VALUE="$("${select_cmd[@]}" 2>/dev/null || true)"
        fi
        cleanup_gum
        if [ -n "$SELECTED_VALUE" ]; then
            local i
            for i in "${!options[@]}"; do
                if [ "${options[$i]}" = "$SELECTED_VALUE" ]; then
                    SELECTED_INDEX=$i
                    return 0
                fi
            done
        fi
    fi
    cleanup_gum

    # Numbered fallback (also used when gum or a TTY is unavailable)
    echo -e "\n${BOLD}${CYAN}$prompt${RESET}"
    local i
    for i in "${!options[@]}"; do
        echo -e "  ${GREEN}$((i+1)))${RESET} ${options[$i]}"
    done
    echo ""

    local choice
    while true; do
        if ! menu_read "Enter selection [1-$count]: "; then
            echo -e "${RED}Error: no interactive terminal available. Use a command flag instead, e.g. --install or --uninstall.${RESET}"
            exit 1
        fi
        choice="$REPLY"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            SELECTED_INDEX=$((choice - 1))
            SELECTED_VALUE="${options[$SELECTED_INDEX]}"
            return 0
        fi
        echo -e "${RED}Invalid selection. Enter a number between 1 and $count.${RESET}"
    done
}

# prompt_text "Prompt" "default" -> sets PROMPT_VALUE
prompt_text() {
    local prompt="$1" def="${2:-}"
    PROMPT_VALUE=""
    if [ -n "$TTY_FILE" ] && setup_gum; then
        local cmd=("$GUM_BIN" input --header="$prompt")
        [ -n "$def" ] && cmd+=(--placeholder="$def")
        if [ "$TTY_FILE" = "/dev/tty" ]; then
            PROMPT_VALUE="$("${cmd[@]}" < /dev/tty 2>/dev/null || true)"
        else
            PROMPT_VALUE="$("${cmd[@]}" 2>/dev/null || true)"
        fi
        cleanup_gum
        if [ -n "$PROMPT_VALUE" ]; then
            return 0
        fi
    fi
    cleanup_gum
    if menu_read "$prompt "; then
        PROMPT_VALUE="$REPLY"
        [ -z "$PROMPT_VALUE" ] && PROMPT_VALUE="$def"
        return 0
    fi
    return 1
}

# Human name for the native package family, or empty.
pkg_family_label() {
    case "$PKG_FAMILY" in
        deb)    echo ".deb (apt)" ;;
        rpm)    if [ "$RPM_FRONTEND" = "zypper" ]; then echo ".rpm (zypper)"; else echo ".rpm (dnf)"; fi ;;
        pacman) echo ".pkg.tar.zst (pacman)" ;;
        *)      echo "" ;;
    esac
}

choose_version_and_source() {
    # Update flow: always latest stable, no prompting
    if [ -n "${SKIP_VERSION_PROMPT:-}" ]; then
        SOURCE_KIND="stable"
        return 0
    fi

    # Non-interactive (flag used without a TTY): default to the stable release
    if [ -z "$TTY_FILE" ]; then
        SOURCE_KIND="${SOURCE_KIND:-stable}"
        echo -e "${MUTED}(non-interactive: using $SOURCE_KIND)${RESET}"
        return 0
    fi

    local native_label=""
    if [ "$PKG_FAMILY" != "none" ]; then
        native_label=" — recommended for $(echo "$OS_NAME" | cut -d' ' -f1)"
    fi

    local options=(
        "Stable release, native package${native_label}"
        "Stable release, universal tarball (no package manager)"
        "Specific release version (choose a tag)"
        "Latest development commit (clone & build from source)"
        "Local source directory (current workspace)"
        "Cancel"
    )
    interactive_choose "Select installation source / version:" "${options[@]}"

    VERSION_TAG=""
    case "$SELECTED_INDEX" in
        0) SOURCE_KIND="stable" ;;
        1) SOURCE_KIND="tarball" ;;
        2)
            SOURCE_KIND="tag"
            if prompt_text "Enter release tag (e.g. v0.2.0):" "v0.2.0"; then
                VERSION_TAG="$PROMPT_VALUE"
            fi
            VERSION_TAG="${VERSION_TAG:-v0.2.0}"
            ;;
        3) SOURCE_KIND="dev" ;;
        4) SOURCE_KIND="local" ;;
        *) echo "Operation cancelled."; exit 0 ;;
    esac
}

# ==============================================================================
# Release downloading
# ==============================================================================
RELEASE_JSON=""
release_json() {
    if [ -z "$RELEASE_JSON" ]; then
        local url
        if [ -z "${VERSION_TAG:-}" ] || [ "$VERSION_TAG" = "latest" ]; then
            url="$API/repos/$REPO/releases/latest"
        else
            url="$API/repos/$REPO/releases/tags/$VERSION_TAG"
        fi
        RELEASE_JSON="$(curl -fsSL --max-time 30 "$url" 2>/dev/null || true)"
    fi
    [ -n "$RELEASE_JSON" ]
}

# Extract the download URL of the first asset matching a grep pattern.
release_asset_url() {
    local pattern="$1"
    printf '%s' "$RELEASE_JSON" \
        | grep -o '"browser_download_url": *"[^"]*'"$pattern"'"' \
        | head -n 1 | sed 's/.*"\(https[^"]*\)".*/\1/'
}

# The asset pattern for the current family/kind/version. Version is the tag
# without the leading "v"; tarballs keep the "v" in their filename. With no
# tag set (latest release) the version part becomes a wildcard, since the
# release JSON already points at a single release.
asset_pattern() {
    local kind="$1"   # native | tarball
    local ver="${VERSION_TAG#v}"
    local vpat
    if [ -z "$ver" ] || [ "$ver" = "latest" ]; then
        vpat='[^"]*'
    else
        vpat="$ver"
    fi
    case "$PKG_FAMILY-$kind" in
        deb-native)      printf 'loaf_%s_%s\\.deb' "$vpat" "$DEB_ARCH" ;;
        pacman-native)   printf 'loaf-%s-1-%s\\.pkg\\.tar\\.zst' "$vpat" "$BINARY_ARCH" ;;
        rpm-native)      printf 'loaf-%s-1[^"]*\\.%s\\.rpm' "$vpat" "$BINARY_ARCH" ;;
        *)               printf 'loaf-v%s-linux-%s\\.tar\\.gz' "$vpat" "$BINARY_ARCH" ;;
    esac
}

# Download a release asset into $1 and unpack tarballs there.
# Sets ASSET_FILE (and SRC_ROOT for tarballs). Returns 1 when not found.
download_asset() {
    local dest="$1" kind="$2"
    ASSET_FILE=""
    SRC_ROOT=""

    release_json || return 1
    local url
    url="$(release_asset_url "$(asset_pattern "$kind")")"
    [ -z "$url" ] && return 1

    local filename
    filename="$(basename "$url")"
    echo -e "${CYAN}[*] Downloading $filename...${RESET}"
    curl -fSL --max-time 300 "$url" -o "$dest/$filename" >/dev/null 2>&1 || return 1
    ASSET_FILE="$dest/$filename"

    if [ "$kind" = "tarball" ]; then
        tar -xzf "$ASSET_FILE" -C "$dest" || return 1
        # Tarballs extract to loaf-<version>/; locate it
        SRC_ROOT="$(find "$dest" -maxdepth 3 -type f -path '*/bin/loaf' 2>/dev/null | head -n 1 | xargs -r dirname | xargs -r dirname)"
        [ -n "$SRC_ROOT" ] && [ -f "$SRC_ROOT/bin/loaf" ] || return 1
    fi
    return 0
}

# Copy binary, desktop entry and icons from an extracted/available source tree
install_from_tree() {
    local tree="$1"
    install -m 755 "$tree/bin/loaf" "$PREFIX/bin/loaf"
    if [ -f "$tree/share/applications/loaf.desktop" ]; then
        install -m 644 "$tree/share/applications/loaf.desktop" "$PREFIX/share/applications/loaf.desktop"
    fi
    if [ -d "$tree/share/icons/hicolor" ]; then
        cp -r "$tree/share/icons/hicolor/." "$PREFIX/share/icons/hicolor/" 2>/dev/null || true
    fi
}

# Build from a source checkout at $1 (requires cargo)
build_from_source() {
    local tree="$1"
    ( cd "$tree" && cargo build --release ) || {
        echo -e "${RED}Error: cargo build failed.${RESET}"
        exit 1
    }
    install -m 755 "$tree/target/release/loaf" "$PREFIX/bin/loaf"
    if [ -f "$tree/packaging/assets/loaf.desktop" ]; then
        install -m 644 "$tree/packaging/assets/loaf.desktop" "$PREFIX/share/applications/loaf.desktop"
    fi
    if [ -d "$tree/packaging/assets/icons/hicolor" ]; then
        cp -r "$tree/packaging/assets/icons/hicolor/." "$PREFIX/share/icons/hicolor/" 2>/dev/null || true
    fi
}

require_build_tools() {
    local missing=0
    command -v cargo >/dev/null 2>&1 || { echo -e "${RED}Error: 'cargo' is required to build Loaf from source.${RESET}"; missing=1; }
    command -v git >/dev/null 2>&1 || { echo -e "${RED}Error: 'git' is required to clone the repository.${RESET}"; missing=1; }
    [ "$missing" -eq 0 ] || exit 1
}

# ==============================================================================
# Native package install / remove
# ==============================================================================
install_native_package() {
    local pkgfile="$1"
    echo -e "${CYAN}[*] Installing $(basename "$pkgfile") with the system package manager...${RESET}"
    case "$PKG_FAMILY" in
        deb)
            if command -v apt-get >/dev/null 2>&1; then
                # apt resolves the Qt and runtime dependencies for us
                as_root apt-get install -y "$pkgfile" || {
                    as_root dpkg -i "$pkgfile" || true
                    as_root apt-get install -f -y
                }
            else
                as_root dpkg -i "$pkgfile" || {
                    echo -e "${RED}Error: dpkg reported missing dependencies and apt-get is unavailable.${RESET}"
                    exit 1
                }
            fi
            ;;
        pacman)
            as_root pacman -U --noconfirm "$pkgfile"
            ;;
        rpm)
            if [ "$RPM_FRONTEND" = "zypper" ]; then
                as_root zypper --non-interactive install "$pkgfile"
            else
                as_root dnf install -y "$pkgfile"
            fi
            ;;
        *)
            echo -e "${RED}Error: no native package manager for this distro.${RESET}"
            exit 1
            ;;
    esac
}

remove_native_package() {
    echo -e "${CYAN}[*] Removing the Loaf package with the system package manager...${RESET}"
    case "$PKG_FAMILY" in
        deb)     as_root apt-get remove -y loaf ;;
        pacman)  as_root pacman -R --noconfirm loaf ;;
        rpm)
            if [ "$RPM_FRONTEND" = "zypper" ]; then
                as_root zypper --non-interactive remove loaf
            else
                as_root dnf remove -y loaf
            fi
            ;;
    esac
}

# True when Loaf was installed through the native package manager.
installed_via_pkg_manager() {
    case "$PKG_FAMILY" in
        deb)    command -v dpkg >/dev/null 2>&1 && dpkg -s loaf >/dev/null 2>&1 ;;
        rpm)    command -v rpm >/dev/null 2>&1 && rpm -q loaf >/dev/null 2>&1 ;;
        pacman) command -v pacman >/dev/null 2>&1 && pacman -Q loaf >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# Remove the tarball-style files from PREFIX.
remove_tarball_files() {
    rm -f "$PREFIX/bin/loaf"
    rm -f "$PREFIX/share/applications/loaf.desktop"
    find "$PREFIX/share/icons/hicolor" -name "loaf.png" -delete 2>/dev/null || true
    find "$PREFIX/share/icons/hicolor" -name "loaf.svg" -delete 2>/dev/null || true

    # Remove icon size dirs / cache if nothing else lives in them
    if [ -d "$PREFIX/share/icons/hicolor" ]; then
        find "$PREFIX/share/icons/hicolor" -mindepth 2 -maxdepth 2 -type d -empty -delete 2>/dev/null || true
        if [ -z "$(find "$PREFIX/share/icons/hicolor" -mindepth 2 -type f 2>/dev/null | head -n 1)" ]; then
            rm -rf "$PREFIX/share/icons/hicolor"
        fi
    fi
    rmdir "$PREFIX/share/icons" "$PREFIX/share/applications" "$PREFIX/share" "$PREFIX/bin" 2>/dev/null || true
}

# ==============================================================================
# Actions
# ==============================================================================
do_install() {
    determine_prefix "$@"
    check_nixos
    detect_arch
    detect_pkg_family
    choose_version_and_source

    echo -e "\n${CYAN}[*] Preparing Loaf ($SOURCE_KIND) for $OS_NAME...${RESET}"

    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT

    # Prepare the target dirs once for tarball-style installs
    prepare_prefix_dirs() {
        mkdir -p "$PREFIX/bin" "$PREFIX/share/applications" "$PREFIX/share/icons/hicolor"
    }

    # Decide between the native package and the tarball for stable/tag installs
    local kind="$SOURCE_KIND"
    if [ "$kind" = "stable" ] || [ "$kind" = "tag" ]; then
        if [ "$PKG_FAMILY" = "none" ]; then
            kind="tarball"
            echo -e "${MUTED}(no native package format known for this distro; using the universal tarball)${RESET}"
        else
            kind="native"
        fi
    fi

    case "$SOURCE_KIND" in
        local)
            if [ -f "./target/release/loaf" ]; then
                echo -e "${GREEN}[+] Using locally built binary (./target/release/loaf)...${RESET}"
                prepare_prefix_dirs
                install_from_tree "."
            elif [ -f "./Cargo.toml" ]; then
                require_build_tools
                echo -e "${AMBER}[!] Building from local source with cargo...${RESET}"
                prepare_prefix_dirs
                build_from_source "."
            else
                echo -e "${RED}Error: no local build found and this is not a source checkout.${RESET}"
                exit 1
            fi
            ;;
        dev)
            require_build_tools
            echo -e "${CYAN}[*] Cloning latest development commit...${RESET}"
            git clone --depth 1 "$GITHUB/$REPO.git" "$WORKDIR/loaf-dev"
            echo -e "${CYAN}[*] Building development commit in release mode...${RESET}"
            prepare_prefix_dirs
            build_from_source "$WORKDIR/loaf-dev"
            ;;
        stable|tag|*)
            local installed=0
            if [ "$kind" = "native" ] && download_asset "$WORKDIR" native; then
                install_native_package "$ASSET_FILE"
                installed=1
            elif [ "$kind" = "native" ]; then
                echo -e "${AMBER}[!] No native package asset for $OS_NAME / $BINARY_ARCH in this release; trying the tarball...${RESET}"
            fi
            if [ "$installed" -eq 0 ] && download_asset "$WORKDIR" tarball; then
                prepare_prefix_dirs
                install_from_tree "$SRC_ROOT"
                installed=1
            fi
            if [ "$installed" -eq 0 ]; then
                # Last resort when we are sitting in a source checkout
                if [ -z "${VERSION_TAG:-}" ] && [ -f "./target/release/loaf" ]; then
                    echo -e "${AMBER}[!] No release asset found; using the local build instead...${RESET}"
                    prepare_prefix_dirs
                    install_from_tree "."
                elif [ -f "./Cargo.toml" ]; then
                    require_build_tools
                    echo -e "${AMBER}[!] No release asset found; building from source instead...${RESET}"
                    prepare_prefix_dirs
                    build_from_source "."
                else
                    echo -e "${RED}Error: no release asset available for ${BINARY_ARCH} and no source fallback is possible here.${RESET}"
                    echo -e "See the README for manual installation options (deb / rpm / pacman / Nix)."
                    exit 1
                fi
            fi
            ;;
    esac

    # Desktop/icon cache refresh and Exec fix apply to tarball installs only;
    # native packages ship their own integration.
    if ! installed_via_pkg_manager; then
        if [ "$PREFIX" != "/usr" ] && [ -f "$PREFIX/share/applications/loaf.desktop" ]; then
            sed -i "s|^Exec=loaf|Exec=$PREFIX/bin/loaf|" "$PREFIX/share/applications/loaf.desktop"
        fi
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
        fi
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true
        fi
    fi

    echo -e "\n${GREEN}[✔] Loaf installed successfully!${RESET}"
    echo -e "Run it with: ${CYAN}loaf${RESET}"
    if ! installed_via_pkg_manager && ! echo ":$PATH:" | grep -q ":$PREFIX/bin:"; then
        echo -e "Add it to your PATH:  ${CYAN}export PATH=\"$PREFIX/bin:\$PATH\"${RESET}"
    fi
}

do_update() {
    determine_prefix "$@"
    check_nixos
    detect_pkg_family

    if ! check_installed; then
        echo -e "${AMBER}[!] Loaf is not installed. Running installation instead...${RESET}"
        do_install "$@"
        return
    fi

    echo -e "${CYAN}[*] Updating Loaf...${RESET}"
    VERSION_TAG=""
    SKIP_VERSION_PROMPT=1
    do_install "$@"
    unset SKIP_VERSION_PROMPT
    echo -e "${GREEN}[✔] Loaf updated successfully!${RESET}"
}

do_uninstall() {
    determine_prefix "$@"
    check_nixos
    detect_arch
    detect_pkg_family

    echo -e "${CYAN}[*] Uninstalling Loaf...${RESET}"

    if installed_via_pkg_manager; then
        remove_native_package
    fi
    if [ -f "$PREFIX/bin/loaf" ] || [ -f "$PREFIX/share/applications/loaf.desktop" ]; then
        remove_tarball_files
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
    fi

    echo -e "${GREEN}[✔] Loaf uninstalled successfully.${RESET}"
}

do_try() {
    check_nixos
    detect_arch
    detect_pkg_family
    VERSION_TAG=""
    echo -e "\n${CYAN}[*] Preparing a temporary, ephemeral run of Loaf...${RESET}"

    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT

    run_bin=""
    if [ -f "./target/release/loaf" ]; then
        echo -e "${GREEN}[+] Using local workspace binary...${RESET}"
        run_bin="./target/release/loaf"
    elif download_asset "$WORKDIR" tarball; then
        run_bin="$SRC_ROOT/bin/loaf"
    elif [ -f "./Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
        echo -e "${AMBER}[!] Building temporary binary...${RESET}"
        cargo build --release
        run_bin="./target/release/loaf"
    else
        echo -e "${RED}Error: could not obtain a Loaf binary to run. Check your network or build locally.${RESET}"
        exit 1
    fi

    echo -e "${GREEN}[✔] Launching Loaf ephemerally (nothing is installed; Ctrl+C to quit)...${RESET}\n"
    "$run_bin"
}

interactive_menu() {
    print_banner
    detect_os
    detect_tty
    determine_prefix
    detect_arch
    detect_pkg_family
    echo -e "Detected OS: ${CYAN}${OS_NAME}${RESET} (ID: ${OS_ID})"
    echo -e "Target Arch: ${CYAN}$BINARY_ARCH${RESET}"
    if [ "$PKG_FAMILY" != "none" ]; then
        echo -e "Native packages: ${CYAN}$(pkg_family_label)${RESET}"
    else
        echo -e "Native packages: ${MUTED}none (tarball install)${RESET}"
    fi
    echo ""

    if check_installed; then
        echo -e "Status: ${GREEN}Loaf is already installed${RESET}"
    else
        echo -e "Status: ${AMBER}Loaf is not installed${RESET}"
    fi

    interactive_choose "Select an action:" \
        "Try Loaf (ephemeral run, no installation)" \
        "Install Loaf" \
        "Update Loaf" \
        "Uninstall Loaf" \
        "Exit"

    case "$SELECTED_INDEX" in
        0) do_try ;;
        1) do_install ;;
        2) do_update ;;
        3) do_uninstall ;;
        *) echo "Exiting."; exit 0 ;;
    esac
}

main() {
    detect_os
    detect_tty

    case "$1" in
        --try|try)           shift; do_try "$@" ;;
        --install|install)   shift; do_install "$@" ;;
        --update|update)     shift; do_update "$@" ;;
        --uninstall|uninstall) shift; do_uninstall "$@" ;;
        --help|-h)
            print_banner
            echo "Usage: curl -sSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash [command]"
            echo ""
            echo "Commands:"
            echo "  try          Try Loaf ephemerally without installing"
            echo "  install      Install Loaf (native package for your distro when available)"
            echo "  update       Update Loaf to the latest stable release"
            echo "  uninstall    Uninstall Loaf"
            echo "  --help       Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  LOAF_OS_SPOOF  Spoof OS ID (e.g. LOAF_OS_SPOOF=ubuntu) for testing"
            echo "  PREFIX         Install prefix for tarball installs (default: \$HOME/.local)"
            ;;
        "")
            interactive_menu
            ;;
        *)
            echo -e "${RED}Unknown command: $1 (use --help)${RESET}"
            exit 1
            ;;
    esac
}

main "$@"
