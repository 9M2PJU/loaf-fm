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
#   PREFIX         Custom install prefix (default: $HOME/.local, or /usr/local with --system)
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
        x86_64|amd64)   BINARY_ARCH="x86_64" ;;
        aarch64|arm64)  BINARY_ARCH="aarch64" ;;
        *)
            echo -e "${RED}Error: Unsupported architecture: $ARCH${RESET}"
            exit 1
            ;;
    esac
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

check_installed() {
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

choose_version_and_source() {
    # Update flow: always latest stable, no prompting
    if [ -n "${SKIP_VERSION_PROMPT:-}" ]; then
        VERSION_CHOICE="stable"
        return 0
    fi

    # Non-interactive (flag used without a TTY): default to the stable release
    if [ -z "$TTY_FILE" ]; then
        VERSION_CHOICE="${VERSION_CHOICE:-stable}"
        echo -e "${MUTED}(non-interactive: using $VERSION_CHOICE)${RESET}"
        return 0
    fi

    local version_options=(
        "Latest Stable Release (precompiled binary)"
        "Specific Release Version (choose a version tag)"
        "Latest Development Commit (clone & build from source)"
        "Local Source Directory (current workspace)"
        "Cancel"
    )
    interactive_choose "Select installation source / version:" "${version_options[@]}"

    case "$SELECTED_INDEX" in
        0) VERSION_CHOICE="stable" ;;
        1)
            VERSION_CHOICE="tag"
            if prompt_text "Enter release tag (e.g. v0.1.0):" "v0.1.0"; then
                VERSION_TAG="$PROMPT_VALUE"
            fi
            VERSION_TAG="${VERSION_TAG:-v0.1.0}"
            ;;
        2) VERSION_CHOICE="dev" ;;
        3) VERSION_CHOICE="local" ;;
        *) echo "Operation cancelled."; exit 0 ;;
    esac
}

# ==============================================================================
# Release downloading
# ==============================================================================
# Download a release tarball for $BINARY_ARCH into $1. Uses "latest" when
# VERSION_TAG is empty. Returns 1 if no matching asset exists.
download_release() {
    local dest="$1" api_url asset_url

    if [ -z "${VERSION_TAG:-}" ] || [ "$VERSION_TAG" = "latest" ]; then
        api_url="$API/repos/$REPO/releases/latest"
    else
        api_url="$API/repos/$REPO/releases/tags/$VERSION_TAG"
    fi

    local json
    json="$(curl -fsSL --max-time 30 "$api_url" 2>/dev/null || true)"
    [ -z "$json" ] && return 1

    asset_url="$(printf '%s' "$json" \
        | grep -o '"browser_download_url": *"[^"]*linux-'"$BINARY_ARCH"'\.tar\.gz"' \
        | head -n 1 | sed 's/.*"\(https[^"]*\)".*/\1/')"
    [ -z "$asset_url" ] && return 1

    echo -e "${CYAN}[*] Downloading $(basename "$asset_url")...${RESET}"
    curl -fSL --max-time 300 "$asset_url" -o "$dest/loaf-release.tar.gz" || return 1
    tar -xzf "$dest/loaf-release.tar.gz" -C "$dest" || return 1

    # Tarballs extract to loaf-<version>/; locate it
    SRC_ROOT="$(find "$dest" -maxdepth 3 -type f -path '*/bin/loaf' 2>/dev/null | head -n 1 | xargs -r dirname | xargs -r dirname)"
    [ -n "$SRC_ROOT" ] && [ -f "$SRC_ROOT/bin/loaf" ]
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
# Actions
# ==============================================================================
do_install() {
    determine_prefix "$@"
    check_nixos
    detect_arch
    choose_version_and_source

    echo -e "\n${CYAN}[*] Preparing installation of Loaf ($VERSION_CHOICE) to $PREFIX...${RESET}"

    mkdir -p "$PREFIX/bin" \
             "$PREFIX/share/applications" \
             "$PREFIX/share/icons/hicolor"

    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT

    case "$VERSION_CHOICE" in
        local)
            if [ -f "./target/release/loaf" ]; then
                echo -e "${GREEN}[+] Using locally built binary (./target/release/loaf)...${RESET}"
                install_from_tree "."
            elif [ -f "./Cargo.toml" ]; then
                require_build_tools
                echo -e "${AMBER}[!] Building from local source with cargo...${RESET}"
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
            build_from_source "$WORKDIR/loaf-dev"
            ;;
        stable|tag|*)
            if download_release "$WORKDIR"; then
                install_from_tree "$SRC_ROOT"
            else
                # No prebuilt asset for this architecture/tag: fall back to local source
                if [ -f "./target/release/loaf" ]; then
                    echo -e "${AMBER}[!] No release asset found; using local build instead...${RESET}"
                    install -m 755 "./target/release/loaf" "$PREFIX/bin/loaf"
                    if [ -f "./packaging/assets/loaf.desktop" ]; then
                        install -m 644 "./packaging/assets/loaf.desktop" "$PREFIX/share/applications/loaf.desktop"
                    fi
                    if [ -d "./packaging/assets/icons/hicolor" ]; then
                        cp -r ./packaging/assets/icons/hicolor/. "$PREFIX/share/icons/hicolor/" 2>/dev/null || true
                    fi
                elif [ -f "./Cargo.toml" ]; then
                    require_build_tools
                    echo -e "${AMBER}[!] No release asset found; building from source instead...${RESET}"
                    build_from_source "."
                else
                    echo -e "${RED}Error: no release asset available for ${BINARY_ARCH} and no source fallback is possible here.${RESET}"
                    echo -e "See the README for manual installation options (deb / rpm / pacman / Nix)."
                    exit 1
                fi
            fi
            ;;
    esac

    # Fix Exec path for non-standard prefixes
    if [ "$PREFIX" != "/usr" ] && [ -f "$PREFIX/share/applications/loaf.desktop" ]; then
        sed -i "s|^Exec=loaf|Exec=$PREFIX/bin/loaf|" "$PREFIX/share/applications/loaf.desktop"
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true
    fi

    echo -e "\n${GREEN}[✔] Loaf successfully installed to $PREFIX/bin/loaf!${RESET}"
    if ! echo ":$PATH:" | grep -q ":$PREFIX/bin:"; then
        echo -e "Add it to your PATH:  ${CYAN}export PATH=\"$PREFIX/bin:\$PATH\"${RESET}"
    fi
}

do_update() {
    determine_prefix "$@"
    check_nixos

    if ! check_installed; then
        echo -e "${AMBER}[!] Loaf is not installed in $PREFIX. Running installation instead...${RESET}"
        do_install "$@"
        return
    fi

    echo -e "${CYAN}[*] Updating Loaf in $PREFIX...${RESET}"
    VERSION_TAG=""            # updates always target the latest stable release
    SKIP_VERSION_PROMPT=1
    do_install "$@"
    unset SKIP_VERSION_PROMPT
    echo -e "${GREEN}[✔] Loaf successfully updated!${RESET}"
}

do_uninstall() {
    determine_prefix "$@"
    check_nixos

    echo -e "${CYAN}[*] Uninstalling Loaf from $PREFIX...${RESET}"

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

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PREFIX/share/applications" 2>/dev/null || true
    fi

    echo -e "${GREEN}[✔] Loaf uninstalled successfully.${RESET}"
}

do_try() {
    check_nixos
    detect_arch
    echo -e "\n${CYAN}[*] Preparing a temporary, ephemeral run of Loaf...${RESET}"

    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT

    run_bin=""
    VERSION_TAG=""
    if [ -f "./target/release/loaf" ]; then
        echo -e "${GREEN}[+] Using local workspace binary...${RESET}"
        run_bin="./target/release/loaf"
    elif download_release "$WORKDIR"; then
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
    echo -e "Detected OS: ${CYAN}${OS_NAME}${RESET} (ID: ${OS_ID})"
    echo -e "Target Arch: ${CYAN}$(uname -m)${RESET}"
    echo ""

    if check_installed; then
        echo -e "Status: ${GREEN}Loaf is already installed${RESET} at $PREFIX/bin/loaf"
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
        --try|try)        shift; do_try "$@" ;;
        --install|install) shift; do_install "$@" ;;
        --update|update)   shift; do_update "$@" ;;
        --uninstall|uninstall) shift; do_uninstall "$@" ;;
        --help|-h)
            print_banner
            echo "Usage: curl -sSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash [command]"
            echo ""
            echo "Commands:"
            echo "  try          Try Loaf ephemerally without installing"
            echo "  install      Install Loaf"
            echo "  update       Update Loaf to the latest stable release"
            echo "  uninstall    Uninstall Loaf"
            echo "  --help       Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  LOAF_OS_SPOOF  Spoof OS ID (e.g. LOAF_OS_SPOOF=nixos) for testing"
            echo "  PREFIX         Install prefix (default: \$HOME/.local)"
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
