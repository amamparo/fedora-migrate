#!/usr/bin/env bash
# =============================================================================
# Fedora Migration Audit Script
# Captures complete system state for reproduction on a fresh Fedora install.
# This script is READ-ONLY — it makes no changes to the system.
# =============================================================================

set -euo pipefail

SNAPSHOT_DIR="$(pwd)/snapshot"

# -- Colors & logging --------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "  ${BLUE}▸${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*" >&2; }
error()   { echo -e "  ${RED}✗${NC} $*" >&2; }
section() { echo -e "\n${BOLD}${GREEN}━━━ $* ━━━${NC}"; }

has_cmd() { command -v "$1" &>/dev/null; }

count_lines() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# -- Init --------------------------------------------------------------------

init_snapshot() {
    if [[ -d "$SNAPSHOT_DIR" ]]; then
        warn "Snapshot directory already exists — removing: $SNAPSHOT_DIR"
        rm -rf "$SNAPSHOT_DIR"
    fi

    mkdir -p "$SNAPSHOT_DIR"/{packages/{dnf-repos,copr-repos,flatpak-overrides},shell,desktop/{plasma-config,wallpapers,themes,icons,color-schemes,aurorae,fonts,konsole,sddm,cursors,kscreen},dotfiles/{config,local-share,gnupg},system/{sysctl.d,udev,modprobe.d,firewall,systemd/custom-units,networkmanager,cups,logind.conf.d,resolved.conf.d,journald.conf.d,sudoers.d},devtools,audio/{pipewire,wireplumber,udev-audio},thirdparty/{usr-local-bin,user-local-bin,opt,user-opt,applications,desktop-files},hardware}
}

# -- Manifest ----------------------------------------------------------------

capture_manifest() {
    section "System Manifest"

    local fedora_version
    fedora_version="$(rpm -E %fedora 2>/dev/null || echo unknown)"

    local display_server="unknown"
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        display_server="wayland"
    elif [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        display_server="x11"
    fi

    local plasma_version="unknown"
    if has_cmd plasmashell; then
        plasma_version="$(plasmashell --version 2>/dev/null | awk '{print $NF}' || echo unknown)"
    fi

    cat > "$SNAPSHOT_DIR/manifest.json" <<EOF
{
    "hostname": "$(hostname)",
    "username": "$USER",
    "home": "$HOME",
    "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "fedora_version": "$fedora_version",
    "kernel": "$(uname -r)",
    "arch": "$(uname -m)",
    "desktop": "${XDG_CURRENT_DESKTOP:-unknown}",
    "display_server": "$display_server",
    "plasma_version": "$plasma_version",
    "shell": "$(basename "${SHELL:-/bin/bash}")"
}
EOF
    success "Manifest created (Fedora $fedora_version, Plasma $plasma_version, $display_server)"
}

# -- Packages & Repos -------------------------------------------------------

capture_packages() {
    section "Packages & Repositories"
    local pkg_dir="$SNAPSHOT_DIR/packages"

    # Explicitly installed packages (not auto-deps)
    # dnf5 --qf needs explicit \n; also prevent stdin reads with < /dev/null
    info "Capturing explicitly installed packages..."
    dnf repoquery --userinstalled --qf '%{name}\n' < /dev/null 2>/dev/null | sort -u > "$pkg_dir/dnf-userinstalled.txt"
    success "$(count_lines "$pkg_dir/dnf-userinstalled.txt") user-installed packages"

    # Full installed package list with details
    info "Capturing full package manifest..."
    rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\t%{VENDOR}\n' < /dev/null | sort > "$pkg_dir/rpm-all.txt"
    success "$(count_lines "$pkg_dir/rpm-all.txt") total packages"

    # Enabled repos
    info "Capturing enabled repositories..."
    dnf repolist --enabled < /dev/null 2>/dev/null > "$pkg_dir/dnf-repos-enabled.txt"

    # Copy all .repo files
    cp /etc/yum.repos.d/*.repo "$pkg_dir/dnf-repos/" 2>/dev/null || true
    success "$(ls "$pkg_dir/dnf-repos/" 2>/dev/null | wc -l | tr -d ' ') repo files"

    # COPR repos (Fedora names these _copr:... or _copr_...)
    if compgen -G "/etc/yum.repos.d/_copr[_:]*" > /dev/null 2>&1; then
        cp /etc/yum.repos.d/_copr[_:]* "$pkg_dir/copr-repos/" 2>/dev/null || true
        for f in "$pkg_dir/copr-repos/"*; do
            [[ -f "$f" ]] || continue
            basename "$f" .repo | sed 's/^_copr[:_]copr\.fedorainfracloud\.org[:_]//' | tr ':_' '/'
        done > "$pkg_dir/copr-repos.txt"
        success "$(count_lines "$pkg_dir/copr-repos.txt") COPR repos"
    fi

    # RPM Fusion
    rpm -qa < /dev/null | grep -E "^rpmfusion-(free|nonfree)-release" > "$pkg_dir/rpmfusion.txt" 2>/dev/null || true
    if [[ -s "$pkg_dir/rpmfusion.txt" ]]; then
        success "RPM Fusion: $(tr '\n' ' ' < "$pkg_dir/rpmfusion.txt")"
    fi

    # Flatpak
    if has_cmd flatpak; then
        info "Capturing Flatpak apps and remotes..."
        flatpak list --app --columns=application,origin,arch 2>/dev/null > "$pkg_dir/flatpak-apps.txt" || true
        flatpak remotes --columns=name,url,options 2>/dev/null > "$pkg_dir/flatpak-remotes.txt" || true
        success "$(count_lines "$pkg_dir/flatpak-apps.txt") Flatpak apps"
    else
        warn "Flatpak not installed — skipping"
    fi

    # Imported GPG keys
    rpm -qa 'gpg-pubkey*' --qf '%{VERSION}-%{RELEASE}\t%{SUMMARY}\n' < /dev/null > "$pkg_dir/gpg-keys.txt" 2>/dev/null || true

    # Packages installed locally (not from any repo)
    dnf list installed < /dev/null 2>/dev/null | awk '$3 ~ /^@(commandline|anaconda)/ {print $1}' > "$pkg_dir/local-rpms.txt" || true
    if [[ -s "$pkg_dir/local-rpms.txt" ]]; then
        success "$(count_lines "$pkg_dir/local-rpms.txt") locally installed packages"
    fi

    # Flatpak permission overrides
    if [[ -d "$HOME/.local/share/flatpak/overrides" ]]; then
        for f in "$HOME/.local/share/flatpak/overrides"/*; do
            [[ -f "$f" ]] && cp "$f" "$pkg_dir/flatpak-overrides/" 2>/dev/null || true
        done
        local override_count
        override_count="$(ls "$pkg_dir/flatpak-overrides/" 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$override_count" -gt 0 ]] && success "$override_count Flatpak permission overrides"
    fi

    # Snap packages (unlikely on Fedora, but check)
    if has_cmd snap; then
        snap list 2>/dev/null | tail -n +2 > "$pkg_dir/snap-packages.txt" || true
        [[ -s "$pkg_dir/snap-packages.txt" ]] && success "$(count_lines "$pkg_dir/snap-packages.txt") Snap packages"
    fi

    # Default packages that were removed
    # Compare installed group default/mandatory packages against what's actually on the system
    # Batched: one dnf group info call for all groups, one rpm -q call for all packages
    info "Detecting removed default packages..."
    local removed_file="$pkg_dir/removed-defaults.txt"
    : > "$removed_file"

    # Get all installed group IDs in one call
    local group_ids
    group_ids="$(dnf group list --installed --hidden < /dev/null 2>/dev/null | tail -n +2 | awk 'NF {print $1}')"
    if [[ -n "$group_ids" ]]; then
        # Get all mandatory/default packages from all groups in one dnf call
        # dnf5 format: "Mandatory packages   : pkg-name" and continuation "                     : pkg-name"
        local all_pkgs
        all_pkgs="$(echo "$group_ids" | xargs dnf group info 2>/dev/null | \
            awk '/^(Mandatory|Default) [Pp]ackages\s*:/ {sub(/.*:\s*/, ""); if (NF) print; s=1; next}
                 s && /^\s+:/ {sub(/^\s+:\s*/, ""); if (NF) print; next}
                 {s=0}' | \
            sort -u)"
        if [[ -n "$all_pkgs" ]]; then
            # Check all packages against rpm via xargs — missing ones print "not installed"
            # rpm -q returns non-zero when packages are missing, so || true to avoid set -e exit
            { echo "$all_pkgs" | xargs rpm -q 2>/dev/null || true; } | \
                awk '/is not installed$/ {sub(/ is not installed$/, ""); gsub(/^package /, ""); print}' | \
                sort -u > "$removed_file"
        fi
    fi

    if [[ -s "$removed_file" ]]; then
        success "$(count_lines "$removed_file") removed default packages detected"
    fi
}

# -- Shell Environment -------------------------------------------------------

capture_shell() {
    section "Shell Environment"
    local shell_dir="$SNAPSHOT_DIR/shell"

    # Zsh config files
    for f in .zshrc .zprofile .zshenv .zlogin .zlogout .zsh_aliases .zsh_functions; do
        if [[ -f "$HOME/$f" ]]; then
            cp "$HOME/$f" "$shell_dir/"
            info "Captured $f"
        fi
    done

    # Zsh custom directories
    for d in .zsh .zfunc .zsh.d; do
        if [[ -d "$HOME/$d" ]]; then
            local target_name
            target_name="$(echo "$d" | sed 's/^\./dot-/')"
            cp -r "$HOME/$d" "$shell_dir/$target_name"
            info "Captured ~/$d/"
        fi
    done

    # Detect plugin manager and capture user customizations
    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        echo "oh-my-zsh" > "$shell_dir/plugin-manager.txt"
        if [[ -d "$HOME/.oh-my-zsh/custom" ]]; then
            cp -r "$HOME/.oh-my-zsh/custom" "$shell_dir/omz-custom"
        fi
        # Record active plugins and theme
        grep -E '^\s*(plugins=|ZSH_THEME=)' "$HOME/.zshrc" > "$shell_dir/omz-active.txt" 2>/dev/null || true
        success "Detected oh-my-zsh"
    elif [[ -d "$HOME/.local/share/zinit" ]] || [[ -d "$HOME/.zinit" ]]; then
        echo "zinit" > "$shell_dir/plugin-manager.txt"
        success "Detected zinit"
    elif [[ -d "$HOME/.antigen" ]]; then
        echo "antigen" > "$shell_dir/plugin-manager.txt"
        cp -r "$HOME/.antigen" "$shell_dir/dot-antigen" 2>/dev/null || true
        success "Detected antigen"
    elif [[ -d "$HOME/.antidote" ]]; then
        echo "antidote" > "$shell_dir/plugin-manager.txt"
        [[ -f "$HOME/.zsh_plugins.txt" ]] && cp "$HOME/.zsh_plugins.txt" "$shell_dir/"
        success "Detected antidote"
    else
        echo "none" > "$shell_dir/plugin-manager.txt"
        warn "No known zsh plugin manager detected"
    fi

    # Starship prompt
    if [[ -f "$HOME/.config/starship.toml" ]]; then
        cp "$HOME/.config/starship.toml" "$shell_dir/"
        info "Captured starship.toml"
    fi

    # User scripts in PATH
    for d in "$HOME/bin" "$HOME/.local/bin"; do
        if [[ -d "$d" ]]; then
            local dir_name
            dir_name="$(basename "$d")"
            mkdir -p "$shell_dir/user-scripts/$dir_name"
            # Only copy regular files and symlinks, not subdirectories from pip etc.
            find "$d" -maxdepth 1 \( -type f -o -type l \) -exec cp -P {} "$shell_dir/user-scripts/$dir_name/" \; 2>/dev/null || true
            local count
            count="$(ls "$shell_dir/user-scripts/$dir_name/" 2>/dev/null | wc -l | tr -d ' ')"
            [[ "$count" -gt 0 ]] && info "Captured $count scripts from ~/$dir_name/"
        fi
    done
}

# -- KDE Desktop Environment ------------------------------------------------

capture_desktop() {
    section "KDE Desktop Environment"
    local desk_dir="$SNAPSHOT_DIR/desktop"

    # -- Plasma config files from ~/.config/ --
    info "Capturing KDE/Plasma configuration..."
    local kde_configs=(
        kdeglobals kwinrc plasmarc plasmashellrc
        plasma-org.kde.plasma.desktop-appletsrc
        khotkeysrc kglobalshortcutsrc kxkbrc
        kscreenlockerrc ksplashrc
        kwinrulesrc klaunchrc
        dolphinrc konsolerc
        breezerc oxygenrc
        krunnerrc ksmserverrc
        kactivitymanagerdrc kactivitymanagerd-statsrc
        kded5rc kded6rc
        baloofilerc
        Trolltech.conf
        powermanagementprofilesrc
        kscreenlockerrc
        systemsettingsrc
        kiorc kiaborc
        katerc katevirc
        yakuakerc
        lattedockrc
        klipperrc
    )
    local captured=0
    for cfg in "${kde_configs[@]}"; do
        if [[ -f "$HOME/.config/$cfg" ]]; then
            cp "$HOME/.config/$cfg" "$desk_dir/plasma-config/"
            ((captured++)) || true
        fi
    done
    success "$captured KDE config files"

    # Plasma 6 nested config dirs
    for d in plasma-workspace kwinrc.d; do
        if [[ -d "$HOME/.config/$d" ]]; then
            cp -r "$HOME/.config/$d" "$desk_dir/plasma-config/"
            info "Captured ~/.config/$d/"
        fi
    done

    # GTK theme settings (KDE applies these for GTK apps)
    for gtk_dir in gtk-3.0 gtk-4.0; do
        if [[ -f "$HOME/.config/$gtk_dir/settings.ini" ]]; then
            mkdir -p "$desk_dir/plasma-config/$gtk_dir"
            cp "$HOME/.config/$gtk_dir/settings.ini" "$desk_dir/plasma-config/$gtk_dir/"
        fi
    done

    # -- Wallpapers --
    info "Capturing wallpapers..."
    local applets_rc="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "$applets_rc" ]]; then
        # Extract wallpaper image paths (both file:// URIs and plain paths)
        grep -oP '(?:Image|image)=file://\K[^\s]+' "$applets_rc" 2>/dev/null | while IFS= read -r wp; do
            [[ -f "$wp" ]] && cp "$wp" "$desk_dir/wallpapers/" && info "Wallpaper: $(basename "$wp")"
        done || true
        grep -oP '(?:Image|image)=(?!file://)\K/[^\s]+' "$applets_rc" 2>/dev/null | while IFS= read -r wp; do
            [[ -f "$wp" ]] && cp "$wp" "$desk_dir/wallpapers/" && info "Wallpaper: $(basename "$wp")"
        done || true
    fi
    # User wallpapers collection
    if [[ -d "$HOME/.local/share/wallpapers" ]]; then
        cp -r "$HOME/.local/share/wallpapers/"* "$desk_dir/wallpapers/" 2>/dev/null || true
        info "Captured ~/.local/share/wallpapers/"
    fi

    # -- Themes, icons, cursors, color schemes, window decorations --
    info "Capturing themes and visual assets..."

    # Color schemes
    if [[ -d "$HOME/.local/share/color-schemes" ]]; then
        cp -r "$HOME/.local/share/color-schemes/"* "$desk_dir/color-schemes/" 2>/dev/null || true
        success "Color schemes captured"
    fi

    # Window decorations (Aurorae)
    if [[ -d "$HOME/.local/share/aurorae" ]]; then
        cp -r "$HOME/.local/share/aurorae/"* "$desk_dir/aurorae/" 2>/dev/null || true
        success "Window decorations captured"
    fi

    # Plasma themes
    if [[ -d "$HOME/.local/share/plasma" ]]; then
        cp -r "$HOME/.local/share/plasma" "$desk_dir/themes/plasma" 2>/dev/null || true
    fi
    if [[ -d "$HOME/.local/share/plasma/desktoptheme" ]]; then
        success "Plasma themes captured"
    fi

    # Icon themes (user-installed only — skip package-provided ones)
    if [[ -d "$HOME/.local/share/icons" ]]; then
        for icon_dir in "$HOME/.local/share/icons"/*/; do
            [[ -d "$icon_dir" ]] || continue
            local icon_name
            icon_name="$(basename "$icon_dir")"
            cp -r "$icon_dir" "$desk_dir/icons/"
            info "Icon theme: $icon_name"
        done
    fi

    # Record active cursor theme
    if [[ -f "$HOME/.config/kcminputrc" ]]; then
        grep -oP 'cursorTheme=\K.*' "$HOME/.config/kcminputrc" > "$desk_dir/cursors/active-cursor-theme.txt" 2>/dev/null || true
        cp "$HOME/.config/kcminputrc" "$desk_dir/plasma-config/"
    fi
    # User-installed cursor themes
    if [[ -d "$HOME/.local/share/icons" ]]; then
        for cursor_dir in "$HOME/.local/share/icons"/*/cursors; do
            [[ -d "$cursor_dir" ]] || continue
            local theme_name
            theme_name="$(basename "$(dirname "$cursor_dir")")"
            # Already copied above with icons; just note it
            info "Cursor theme: $theme_name"
        done
    fi

    # -- Fonts --
    info "Capturing user fonts..."
    if [[ -d "$HOME/.local/share/fonts" ]]; then
        cp -r "$HOME/.local/share/fonts/"* "$desk_dir/fonts/" 2>/dev/null || true
        local font_count
        font_count="$(find "$desk_dir/fonts/" -type f 2>/dev/null | wc -l | tr -d ' ')"
        success "$font_count font files"
    fi
    if [[ -d "$HOME/.fonts" ]]; then
        cp -r "$HOME/.fonts/"* "$desk_dir/fonts/" 2>/dev/null || true
    fi
    # Font config
    [[ -f "$HOME/.config/fontconfig/fonts.conf" ]] && cp "$HOME/.config/fontconfig/fonts.conf" "$desk_dir/fonts/"
    [[ -d "$HOME/.config/fontconfig/conf.d" ]] && cp -r "$HOME/.config/fontconfig/conf.d" "$desk_dir/fonts/conf.d"

    # -- Konsole profiles --
    if [[ -d "$HOME/.local/share/konsole" ]]; then
        cp -r "$HOME/.local/share/konsole/"* "$desk_dir/konsole/" 2>/dev/null || true
        success "Konsole profiles captured"
    fi

    # -- SDDM (login screen) --
    info "Capturing SDDM configuration..."
    [[ -f /etc/sddm.conf ]] && cp /etc/sddm.conf "$desk_dir/sddm/" 2>/dev/null || true
    [[ -d /etc/sddm.conf.d ]] && cp -r /etc/sddm.conf.d/* "$desk_dir/sddm/" 2>/dev/null || true
    # SDDM theme dir (if custom)
    if [[ -d /usr/share/sddm/themes ]]; then
        ls /usr/share/sddm/themes/ > "$desk_dir/sddm/installed-themes.txt" 2>/dev/null || true
    fi

    # -- KScreen display profiles --
    if [[ -d "$HOME/.local/share/kscreen" ]]; then
        cp -r "$HOME/.local/share/kscreen/"* "$desk_dir/kscreen/" 2>/dev/null || true
        success "KScreen display profiles captured"
    fi

    # -- KWin scripts --
    if [[ -d "$HOME/.local/share/kwin/scripts" ]]; then
        cp -r "$HOME/.local/share/kwin" "$desk_dir/kwin" 2>/dev/null || true
        info "KWin scripts captured"
    fi

    # -- KDE Store downloads --
    if [[ -d "$HOME/.local/share/knewstuff3" ]]; then
        cp -r "$HOME/.local/share/knewstuff3" "$desk_dir/knewstuff3" 2>/dev/null || true
        info "KNewStuff metadata captured"
    fi
}

# -- User Dotfiles & App Configs --------------------------------------------

capture_dotfiles() {
    section "User Dotfiles & App Configs"
    local dot_dir="$SNAPSHOT_DIR/dotfiles"

    # ~/.config/ — copy with exclusions for caches, browser data, huge app data
    info "Capturing ~/.config/ (excluding caches and browser data)..."
    rsync -a \
        --exclude='BraveSoftware/' \
        --exclude='chromium/' \
        --exclude='google-chrome*/' \
        --exclude='firefox/' \
        --exclude='microsoft-edge*/' \
        --exclude='vivaldi*/' \
        --exclude='opera*/' \
        --exclude='**/cache/' \
        --exclude='**/Cache/' \
        --exclude='**/*cache*/' \
        --exclude='**/*Cache*/' \
        --exclude='**/GPUCache/' \
        --exclude='**/ShaderCache/' \
        --exclude='**/Service Worker/' \
        --exclude='**/blob_storage/' \
        --exclude='**/databases/' \
        --exclude='**/Local Storage/' \
        --exclude='**/IndexedDB/' \
        --exclude='**/Session Storage/' \
        --exclude='**/Code/' \
        --exclude='**/Code - OSS/' \
        --exclude='**/codium/' \
        --exclude='Trash/' \
        --exclude='thumbnails/' \
        --exclude='pulse/' \
        --exclude='pipewire/' \
        --exclude='gvfs-metadata/' \
        --exclude='discord/' \
        --exclude='Slack/' \
        --exclude='spotify/' \
        --exclude='teams*/' \
        --exclude='libreoffice/' \
        --exclude='*.log' \
        --exclude='*.sock' \
        --exclude='*.lock' \
        --exclude='session/' \
        --exclude='sessions/' \
        --exclude='crash*/' \
        --exclude='akonadi*/' \
        --exclude='baloo/' \
        "$HOME/.config/" "$dot_dir/config/" 2>/dev/null || true
    success "~/.config/ captured"

    # VS Code / Codium settings (just the important config, not extensions/data)
    for vsc_dir in Code "Code - OSS" codium; do
        if [[ -d "$HOME/.config/$vsc_dir/User" ]]; then
            mkdir -p "$dot_dir/config/$vsc_dir/User"
            for f in settings.json keybindings.json snippets locale.json; do
                [[ -e "$HOME/.config/$vsc_dir/User/$f" ]] && \
                    cp -r "$HOME/.config/$vsc_dir/User/$f" "$dot_dir/config/$vsc_dir/User/"
            done
            info "Captured $vsc_dir settings"
        fi
    done

    # ~/.local/share/ — selective (heavy directories already captured by desktop section)
    info "Capturing selected ~/.local/share/ data..."
    local share_dirs=(
        applications    # .desktop files
        mime            # MIME type associations
        kservices5      # KDE service definitions
        kservices6
        kxmlgui5        # KDE XML GUI definitions
    )
    for d in "${share_dirs[@]}"; do
        if [[ -d "$HOME/.local/share/$d" ]]; then
            cp -r "$HOME/.local/share/$d" "$dot_dir/local-share/" 2>/dev/null || true
        fi
    done

    # Record what's in ~/.local/share for reference
    ls -1 "$HOME/.local/share/" > "$dot_dir/local-share-listing.txt" 2>/dev/null || true

    # Top-level dotfiles
    for f in .gitconfig .gitignore_global .editorconfig .inputrc .dir_colors .tmux.conf .wgetrc .curlrc; do
        if [[ -f "$HOME/$f" ]]; then
            cp "$HOME/$f" "$dot_dir/"
            info "Captured $f"
        fi
    done

    # Git config (alternate location)
    if [[ -f "$HOME/.config/git/config" ]]; then
        mkdir -p "$dot_dir/config/git"
        cp "$HOME/.config/git/config" "$dot_dir/config/git/"
    fi

    # SSH config (NOT private keys)
    if [[ -f "$HOME/.ssh/config" ]]; then
        cp "$HOME/.ssh/config" "$dot_dir/ssh-config"
        info "Captured SSH config (NOT private keys)"
    fi
    # SSH known_hosts for convenience
    if [[ -f "$HOME/.ssh/known_hosts" ]]; then
        cp "$HOME/.ssh/known_hosts" "$dot_dir/ssh-known_hosts"
    fi
    # SSH authorized_keys (public, safe to capture)
    if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
        cp "$HOME/.ssh/authorized_keys" "$dot_dir/ssh-authorized_keys"
        info "Captured SSH authorized_keys"
    fi

    # GPG public keyring
    if has_cmd gpg; then
        gpg --list-keys --keyid-format long > "$dot_dir/gnupg/gpg-public-keys.txt" 2>/dev/null || true
        gpg --export --armor > "$dot_dir/gnupg/pubring.asc" 2>/dev/null || true
        gpg --export-ownertrust > "$dot_dir/gnupg/ownertrust.txt" 2>/dev/null || true
        if [[ -s "$dot_dir/gnupg/pubring.asc" ]]; then
            success "GPG public keyring exported"
        fi
        # GPG agent config
        [[ -f "$HOME/.gnupg/gpg.conf" ]] && cp "$HOME/.gnupg/gpg.conf" "$dot_dir/gnupg/" 2>/dev/null || true
        [[ -f "$HOME/.gnupg/gpg-agent.conf" ]] && cp "$HOME/.gnupg/gpg-agent.conf" "$dot_dir/gnupg/" 2>/dev/null || true
    fi

    # Default applications / MIME associations
    if [[ -f "$HOME/.config/mimeapps.list" ]]; then
        cp "$HOME/.config/mimeapps.list" "$dot_dir/mimeapps.list"
        info "Captured MIME default applications"
    fi

    # XDG user directories
    [[ -f "$HOME/.config/user-dirs.dirs" ]] && cp "$HOME/.config/user-dirs.dirs" "$dot_dir/user-dirs.dirs"
}

# -- System-Level Customizations ---------------------------------------------

capture_system() {
    section "System Configuration"
    local sys_dir="$SNAPSHOT_DIR/system"

    # /etc/fstab
    cp /etc/fstab "$sys_dir/fstab" 2>/dev/null || true
    info "Captured /etc/fstab"

    # /etc/hosts
    cp /etc/hosts "$sys_dir/hosts" 2>/dev/null || true

    # /etc/hostname
    cp /etc/hostname "$sys_dir/hostname" 2>/dev/null || true

    # /etc/environment
    [[ -f /etc/environment ]] && cp /etc/environment "$sys_dir/environment"

    # sysctl customizations
    if [[ -d /etc/sysctl.d ]]; then
        local sysctl_count=0
        for f in /etc/sysctl.d/*.conf; do
            [[ -f "$f" ]] || continue
            cp "$f" "$sys_dir/sysctl.d/"
            ((sysctl_count++)) || true
        done
        [[ $sysctl_count -gt 0 ]] && success "$sysctl_count sysctl configs"
    fi

    # udev rules
    if [[ -d /etc/udev/rules.d ]]; then
        local udev_count=0
        for f in /etc/udev/rules.d/*.rules; do
            [[ -f "$f" ]] || continue
            cp "$f" "$sys_dir/udev/"
            ((udev_count++)) || true
        done
        [[ $udev_count -gt 0 ]] && success "$udev_count udev rules"
    fi

    # modprobe.d
    if [[ -d /etc/modprobe.d ]]; then
        for f in /etc/modprobe.d/*.conf; do
            [[ -f "$f" ]] || continue
            cp "$f" "$sys_dir/modprobe.d/"
        done
    fi

    # Firewall (firewalld)
    if has_cmd firewall-cmd; then
        info "Capturing firewall configuration..."
        firewall-cmd --list-all > "$sys_dir/firewall/firewall-list-all.txt" 2>/dev/null || true
        firewall-cmd --get-active-zones > "$sys_dir/firewall/active-zones.txt" 2>/dev/null || true
        firewall-cmd --list-all-zones > "$sys_dir/firewall/all-zones.txt" 2>/dev/null || true
        # Direct rules
        firewall-cmd --direct --get-all-rules > "$sys_dir/firewall/direct-rules.txt" 2>/dev/null || true
        # Rich rules per zone
        for zone in $(firewall-cmd --get-zones 2>/dev/null); do
            local rules
            rules="$(firewall-cmd --zone="$zone" --list-rich-rules 2>/dev/null)" || true
            if [[ -n "$rules" ]]; then
                echo "# Zone: $zone" >> "$sys_dir/firewall/rich-rules.txt"
                echo "$rules" >> "$sys_dir/firewall/rich-rules.txt"
            fi
        done
        success "Firewall config captured"
    fi

    # Systemd services
    info "Capturing systemd service states..."
    systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend \
        | awk '{print $1}' | sort > "$sys_dir/systemd/system-enabled.txt" 2>/dev/null || true
    systemctl list-unit-files --type=service --state=disabled --no-pager --no-legend \
        | awk '{print $1}' | sort > "$sys_dir/systemd/system-disabled.txt" 2>/dev/null || true
    # User services
    systemctl --user list-unit-files --type=service --state=enabled --no-pager --no-legend \
        | awk '{print $1}' | sort > "$sys_dir/systemd/user-enabled.txt" 2>/dev/null || true
    # User timers
    systemctl --user list-unit-files --type=timer --state=enabled --no-pager --no-legend \
        | awk '{print $1}' | sort > "$sys_dir/systemd/user-timers.txt" 2>/dev/null || true
    success "Systemd services captured"

    # Custom systemd unit files
    for unit_dir in /etc/systemd/system "$HOME/.config/systemd/user"; do
        if [[ -d "$unit_dir" ]]; then
            find "$unit_dir" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.mount' -o -name '*.path' \) \
                -exec cp {} "$sys_dir/systemd/custom-units/" \; 2>/dev/null || true
        fi
    done

    # GRUB
    if [[ -f /etc/default/grub ]]; then
        cp /etc/default/grub "$sys_dir/grub-defaults"
        info "Captured GRUB defaults"
    fi
    # Current kernel command line
    cat /proc/cmdline > "$sys_dir/kernel-cmdline.txt" 2>/dev/null || true

    # NetworkManager connections (contain wifi passwords — warn later)
    if [[ -d /etc/NetworkManager/system-connections ]]; then
        local nm_count=0
        for f in /etc/NetworkManager/system-connections/*; do
            [[ -f "$f" ]] || continue
            cp "$f" "$sys_dir/networkmanager/" 2>/dev/null || true
            ((nm_count++)) || true
        done
        if [[ $nm_count -gt 0 ]]; then
            success "$nm_count NetworkManager profiles (may contain passwords)"
        fi
    fi

    # DNF configuration
    [[ -f /etc/dnf/dnf.conf ]] && cp /etc/dnf/dnf.conf "$sys_dir/dnf.conf"

    # CUPS printers
    if [[ -f /etc/cups/printers.conf ]]; then
        cp /etc/cups/printers.conf "$sys_dir/cups/" 2>/dev/null || true
        # PPD files for each printer
        if [[ -d /etc/cups/ppd ]]; then
            cp /etc/cups/ppd/*.ppd "$sys_dir/cups/" 2>/dev/null || true
        fi
        local printer_count
        printer_count="$(grep -c '<Printer' "$sys_dir/cups/printers.conf" 2>/dev/null || echo 0)"
        success "$printer_count printer(s) captured"
    fi

    # Locale & timezone
    localectl status > "$sys_dir/locale.txt" 2>/dev/null || true
    timedatectl status > "$sys_dir/timezone.txt" 2>/dev/null || true

    # Crontab
    if crontab -l &>/dev/null; then
        crontab -l > "$sys_dir/crontab.txt" 2>/dev/null || true
        if [[ -s "$sys_dir/crontab.txt" ]]; then
            success "User crontab captured ($(count_lines "$sys_dir/crontab.txt") lines)"
        fi
    fi

    # logind.conf (lid/button behavior)
    [[ -f /etc/systemd/logind.conf ]] && cp /etc/systemd/logind.conf "$sys_dir/logind.conf" 2>/dev/null || true
    if [[ -d /etc/systemd/logind.conf.d ]]; then
        for f in /etc/systemd/logind.conf.d/*.conf; do
            [[ -f "$f" ]] && cp "$f" "$sys_dir/logind.conf.d/" 2>/dev/null || true
        done
    fi

    # resolved.conf.d (custom DNS)
    if [[ -d /etc/systemd/resolved.conf.d ]]; then
        for f in /etc/systemd/resolved.conf.d/*.conf; do
            [[ -f "$f" ]] && cp "$f" "$sys_dir/resolved.conf.d/" 2>/dev/null || true
        done
    fi
    [[ -f /etc/systemd/resolved.conf ]] && cp /etc/systemd/resolved.conf "$sys_dir/resolved.conf" 2>/dev/null || true

    # journald.conf.d (custom logging)
    if [[ -d /etc/systemd/journald.conf.d ]]; then
        for f in /etc/systemd/journald.conf.d/*.conf; do
            [[ -f "$f" ]] && cp "$f" "$sys_dir/journald.conf.d/" 2>/dev/null || true
        done
    fi

    # sudoers.d (custom sudo rules — may not be readable without root)
    if [[ -d /etc/sudoers.d ]]; then
        for f in /etc/sudoers.d/*; do
            [[ -f "$f" ]] && cp "$f" "$sys_dir/sudoers.d/" 2>/dev/null || true
        done
        local sudoers_count
        sudoers_count="$(ls "$sys_dir/sudoers.d/" 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$sudoers_count" -gt 0 ]]; then
            success "$sudoers_count sudoers.d entries"
        else
            info "sudoers.d not readable (run as root to capture)"
        fi
    fi

    # alternatives (java, python, etc.)
    if has_cmd alternatives; then
        alternatives --list > "$sys_dir/alternatives.txt" 2>/dev/null || true
        [[ -s "$sys_dir/alternatives.txt" ]] && info "System alternatives captured"
    fi
}

# -- Development Tools -------------------------------------------------------

capture_devtools() {
    section "Development Tools"
    local dev_dir="$SNAPSHOT_DIR/devtools"

    # pip user packages
    if has_cmd pip; then
        pip list --user --format=freeze > "$dev_dir/pip-user.txt" 2>/dev/null || true
        [[ -s "$dev_dir/pip-user.txt" ]] && success "$(count_lines "$dev_dir/pip-user.txt") pip user packages"
    elif has_cmd pip3; then
        pip3 list --user --format=freeze > "$dev_dir/pip-user.txt" 2>/dev/null || true
        [[ -s "$dev_dir/pip-user.txt" ]] && success "$(count_lines "$dev_dir/pip-user.txt") pip user packages"
    fi

    # pipx
    if has_cmd pipx; then
        pipx list --json > "$dev_dir/pipx.json" 2>/dev/null || true
        pipx list --short > "$dev_dir/pipx.txt" 2>/dev/null || true
        [[ -s "$dev_dir/pipx.txt" ]] && success "$(count_lines "$dev_dir/pipx.txt") pipx packages"
    fi

    # npm global packages
    if has_cmd npm; then
        npm list -g --depth=0 --json > "$dev_dir/npm-globals.json" 2>/dev/null || true
        npm list -g --depth=0 --parseable 2>/dev/null | tail -n +2 | xargs -I{} basename {} > "$dev_dir/npm-globals.txt" 2>/dev/null || true
        [[ -s "$dev_dir/npm-globals.txt" ]] && success "$(count_lines "$dev_dir/npm-globals.txt") npm global packages"
    fi

    # Cargo installed crates
    if has_cmd cargo; then
        cargo install --list > "$dev_dir/cargo-installs.txt" 2>/dev/null || true
        # Extract just crate names (lines without leading whitespace)
        grep -v '^\s' "$dev_dir/cargo-installs.txt" | awk '{print $1}' > "$dev_dir/cargo-crates.txt" 2>/dev/null || true
        [[ -s "$dev_dir/cargo-crates.txt" ]] && success "$(count_lines "$dev_dir/cargo-crates.txt") cargo crates"
    fi

    # Go binaries
    if [[ -d "$HOME/go/bin" ]]; then
        ls -1 "$HOME/go/bin/" > "$dev_dir/go-binaries.txt" 2>/dev/null || true
        [[ -s "$dev_dir/go-binaries.txt" ]] && success "$(count_lines "$dev_dir/go-binaries.txt") Go binaries"
    fi

    # Rustup
    if has_cmd rustup; then
        rustup show > "$dev_dir/rustup-show.txt" 2>/dev/null || true
        rustup toolchain list > "$dev_dir/rustup-toolchains.txt" 2>/dev/null || true
        rustup component list --installed > "$dev_dir/rustup-components.txt" 2>/dev/null || true
        info "Captured rustup configuration"
    fi

    # Version managers
    local vm_detected=()
    has_cmd pyenv && vm_detected+=("pyenv") && pyenv versions > "$dev_dir/pyenv-versions.txt" 2>/dev/null || true
    has_cmd nvm && vm_detected+=("nvm")
    [[ -d "$HOME/.nvm" ]] && vm_detected+=("nvm") && ls "$HOME/.nvm/versions/node/" > "$dev_dir/nvm-versions.txt" 2>/dev/null || true
    has_cmd fnm && vm_detected+=("fnm") && fnm list > "$dev_dir/fnm-versions.txt" 2>/dev/null || true
    has_cmd rbenv && vm_detected+=("rbenv") && rbenv versions > "$dev_dir/rbenv-versions.txt" 2>/dev/null || true
    has_cmd sdkman && vm_detected+=("sdkman")
    [[ -d "$HOME/.sdkman" ]] && vm_detected+=("sdkman")
    has_cmd asdf && vm_detected+=("asdf") && asdf list > "$dev_dir/asdf-versions.txt" 2>/dev/null || true
    has_cmd mise && vm_detected+=("mise") && mise list > "$dev_dir/mise-list.txt" 2>/dev/null || true

    if [[ ${#vm_detected[@]} -gt 0 ]]; then
        printf '%s\n' "${vm_detected[@]}" | sort -u > "$dev_dir/version-managers.txt"
        success "Version managers: ${vm_detected[*]}"
    fi

    # Gem (Ruby)
    if has_cmd gem; then
        gem list --local --no-versions > "$dev_dir/gem-packages.txt" 2>/dev/null || true
    fi

    # VS Code / Codium extensions
    for vsc_cmd in code code-oss codium; do
        if has_cmd "$vsc_cmd"; then
            "$vsc_cmd" --list-extensions > "$dev_dir/${vsc_cmd}-extensions.txt" 2>/dev/null || true
            [[ -s "$dev_dir/${vsc_cmd}-extensions.txt" ]] && \
                success "$(count_lines "$dev_dir/${vsc_cmd}-extensions.txt") $vsc_cmd extensions"
        fi
    done

    # Docker
    if has_cmd docker; then
        docker info > "$dev_dir/docker-info.txt" 2>/dev/null || true
        docker images --format '{{.Repository}}:{{.Tag}}' > "$dev_dir/docker-images.txt" 2>/dev/null || true
        [[ -s "$dev_dir/docker-images.txt" ]] && success "$(count_lines "$dev_dir/docker-images.txt") Docker images"
        [[ ! -s "$dev_dir/docker-images.txt" ]] && info "Docker detected"
    fi
    if has_cmd podman; then
        podman info > "$dev_dir/podman-info.txt" 2>/dev/null || true
        podman images --format '{{.Repository}}:{{.Tag}}' > "$dev_dir/podman-images.txt" 2>/dev/null || true
        [[ -s "$dev_dir/podman-images.txt" ]] && success "$(count_lines "$dev_dir/podman-images.txt") Podman images"
        [[ ! -s "$dev_dir/podman-images.txt" ]] && info "Podman detected"
    fi
}

# -- Audio / Music Production ------------------------------------------------

capture_audio() {
    section "Audio Configuration"
    local audio_dir="$SNAPSHOT_DIR/audio"

    # PipeWire
    if [[ -d "$HOME/.config/pipewire" ]]; then
        cp -r "$HOME/.config/pipewire/"* "$audio_dir/pipewire/" 2>/dev/null || true
        success "PipeWire user config captured"
    fi
    if [[ -d /etc/pipewire ]]; then
        # Only capture if files differ from defaults (user has customized)
        for f in /etc/pipewire/*.conf /etc/pipewire/*.conf.d/*; do
            [[ -f "$f" ]] && cp "$f" "$audio_dir/pipewire/" 2>/dev/null || true
        done
    fi

    # WirePlumber
    if [[ -d "$HOME/.config/wireplumber" ]]; then
        cp -r "$HOME/.config/wireplumber/"* "$audio_dir/wireplumber/" 2>/dev/null || true
        success "WirePlumber config captured"
    fi

    # JACK (if present alongside PipeWire)
    [[ -f "$HOME/.jackdrc" ]] && cp "$HOME/.jackdrc" "$audio_dir/"

    # Realtime scheduling
    if [[ -f /etc/security/limits.d/99-realtime.conf ]] || [[ -f /etc/security/limits.d/audio.conf ]]; then
        cp /etc/security/limits.d/*realtime* "$audio_dir/" 2>/dev/null || true
        cp /etc/security/limits.d/*audio* "$audio_dir/" 2>/dev/null || true
        success "Realtime scheduling config captured"
    fi
    # Check if user is in audio/realtime groups
    groups > "$audio_dir/user-groups.txt" 2>/dev/null || true

    # Audio-specific udev rules
    for f in /etc/udev/rules.d/*audio* /etc/udev/rules.d/*sound* /etc/udev/rules.d/*midi*; do
        [[ -f "$f" ]] && cp "$f" "$audio_dir/udev-audio/" 2>/dev/null || true
    done

    # Audio plugin paths (VST, LV2, etc.)
    {
        echo "# Audio plugin environment variables"
        echo "VST_PATH=${VST_PATH:-}"
        echo "VST3_PATH=${VST3_PATH:-}"
        echo "LV2_PATH=${LV2_PATH:-}"
        echo "LADSPA_PATH=${LADSPA_PATH:-}"
        echo "DSSI_PATH=${DSSI_PATH:-}"
        echo "CLAP_PATH=${CLAP_PATH:-}"
    } > "$audio_dir/plugin-paths.txt"

    # List installed audio software (from packages)
    rpm -qa | grep -iE '(jack|pipewire|pulseaudio|alsa|ardour|audacity|carla|hydrogen|lmms|musescore|reaper|bitwig|lv2|vst|ladspa|dssi|clap)' \
        | sort > "$audio_dir/audio-packages.txt" 2>/dev/null || true
    [[ -s "$audio_dir/audio-packages.txt" ]] && info "$(count_lines "$audio_dir/audio-packages.txt") audio-related packages"
}

# -- Third-Party / Manually Installed Software -------------------------------

capture_thirdparty() {
    section "Third-Party Software"
    local tp_dir="$SNAPSHOT_DIR/thirdparty"

    # /usr/local/bin contents
    if [[ -d /usr/local/bin ]]; then
        for f in /usr/local/bin/*; do
            [[ -f "$f" ]] || continue
            local fname
            fname="$(basename "$f")"
            local ftype
            ftype="$(file -b "$f" 2>/dev/null | head -c 80)"
            echo -e "$fname\t$ftype" >> "$tp_dir/usr-local-bin/listing.txt"
        done
        [[ -s "$tp_dir/usr-local-bin/listing.txt" ]] && \
            success "$(count_lines "$tp_dir/usr-local-bin/listing.txt") files in /usr/local/bin"
    fi

    # ~/.local/bin contents (user-installed binaries)
    if [[ -d "$HOME/.local/bin" ]]; then
        for f in "$HOME/.local/bin"/*; do
            [[ -f "$f" ]] || continue
            local fname
            fname="$(basename "$f")"
            local ftype
            ftype="$(file -b "$f" 2>/dev/null | head -c 80)"
            echo -e "$fname\t$ftype" >> "$tp_dir/user-local-bin/listing.txt"
            # Copy actual binary — user-owned, can be restored directly
            cp -p "$f" "$tp_dir/user-local-bin/"
        done
        [[ -s "$tp_dir/user-local-bin/listing.txt" ]] && \
            success "$(count_lines "$tp_dir/user-local-bin/listing.txt") files in ~/.local/bin"
    fi

    # /opt contents
    if [[ -d /opt ]]; then
        ls -1 /opt/ > "$tp_dir/opt/listing.txt" 2>/dev/null || true
        # Get more details for each entry
        for d in /opt/*/; do
            [[ -d "$d" ]] || continue
            local dname
            dname="$(basename "$d")"
            local size
            size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
            echo -e "$dname\t$size" >> "$tp_dir/opt/details.txt"
        done
    fi

    # ~/opt contents (user-installed packages like REAPER)
    if [[ -d "$HOME/opt" ]]; then
        ls -1 "$HOME/opt/" > "$tp_dir/user-opt/listing.txt" 2>/dev/null || true
        for d in "$HOME/opt"/*/; do
            [[ -d "$d" ]] || continue
            local dname
            dname="$(basename "$d")"
            local size
            size="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
            echo -e "$dname\t$size" >> "$tp_dir/user-opt/details.txt"
        done
        # Copy actual contents — user-owned, can be restored directly
        cp -r "$HOME/opt"/* "$tp_dir/user-opt/" 2>/dev/null || true
        [[ -s "$tp_dir/user-opt/details.txt" ]] && \
            success "$(count_lines "$tp_dir/user-opt/details.txt") items in ~/opt"
    fi

    # ~/Applications (AppImages, etc.)
    if [[ -d "$HOME/Applications" ]]; then
        find "$HOME/Applications" -maxdepth 2 -type f -executable \
            -exec basename {} \; > "$tp_dir/applications/listing.txt" 2>/dev/null || true
        [[ -s "$tp_dir/applications/listing.txt" ]] && \
            success "$(count_lines "$tp_dir/applications/listing.txt") items in ~/Applications"
    fi

    # AppImages anywhere in home
    info "Scanning for AppImages..."
    find "$HOME" -maxdepth 4 -name '*.AppImage' -type f 2>/dev/null \
        | sed "s|^$HOME|~|" > "$tp_dir/appimages.txt" || true
    [[ -s "$tp_dir/appimages.txt" ]] && \
        success "$(count_lines "$tp_dir/appimages.txt") AppImages found"

    # Custom .desktop files (user-created, not from packages)
    if [[ -d "$HOME/.local/share/applications" ]]; then
        for desktop_file in "$HOME/.local/share/applications"/*.desktop; do
            [[ -f "$desktop_file" ]] || continue
            local df_name
            df_name="$(basename "$desktop_file")"
            # Check if an RPM owns this file — if not, it's custom
            if ! rpm -qf "$desktop_file" &>/dev/null; then
                cp "$desktop_file" "$tp_dir/desktop-files/"
            fi
        done
        local custom_count
        custom_count="$(ls "$tp_dir/desktop-files/" 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$custom_count" -gt 0 ]] && success "$custom_count custom .desktop files"
    fi

    # Try to identify sources for third-party software
    info "Identifying third-party software sources..."
    local id_file="$tp_dir/identification.json"
    echo '[' > "$id_file"
    local first=true
    for f in /usr/local/bin/* "$HOME/.local/bin"/*; do
        [[ -f "$f" ]] || continue
        local fname
        fname="$(basename "$f")"
        local version=""
        # Try common version flags
        version="$("$f" --version 2>/dev/null | head -1 || true)"
        [[ -z "$version" ]] && version="$("$f" -v 2>/dev/null | head -1 || true)"
        [[ -z "$version" ]] && version="$("$f" version 2>/dev/null | head -1 || true)"

        $first || echo ',' >> "$id_file"
        first=false
        cat >> "$id_file" <<EOF
    {
        "name": "$fname",
        "path": "$f",
        "version": "$(echo "$version" | sed 's/"/\\"/g' | head -c 200)"
    }
EOF
    done
    echo ']' >> "$id_file"
}

# -- Hardware ----------------------------------------------------------------

capture_hardware() {
    section "Hardware Configuration"
    local hw_dir="$SNAPSHOT_DIR/hardware"

    # CPU info
    lscpu > "$hw_dir/cpu-info.txt" 2>/dev/null || true
    info "CPU: $(grep 'Model name' "$hw_dir/cpu-info.txt" 2>/dev/null | sed 's/.*:\s*//')"

    # PCI devices
    lspci > "$hw_dir/lspci.txt" 2>/dev/null || true

    # USB devices
    lsusb > "$hw_dir/lsusb.txt" 2>/dev/null || true

    # Loaded kernel modules
    lsmod | sort > "$hw_dir/loaded-modules.txt" 2>/dev/null || true

    # Current kernel command line (also captured in system, but convenient here)
    cat /proc/cmdline > "$hw_dir/kernel-cmdline.txt" 2>/dev/null || true

    # GRUB defaults
    [[ -f /etc/default/grub ]] && cp /etc/default/grub "$hw_dir/grub-defaults"

    # TLP / power management
    if has_cmd tlp-stat; then
        tlp-stat -s > "$hw_dir/tlp-status.txt" 2>/dev/null || true
        info "TLP detected"
    fi
    [[ -f /etc/tlp.conf ]] && cp /etc/tlp.conf "$hw_dir/"
    [[ -d /etc/tlp.d ]] && cp -r /etc/tlp.d "$hw_dir/tlp.d" 2>/dev/null || true

    # Power profiles daemon (alternative to TLP)
    if has_cmd powerprofilesctl; then
        powerprofilesctl list > "$hw_dir/power-profiles.txt" 2>/dev/null || true
        info "power-profiles-daemon detected"
    fi

    # Disk info
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT > "$hw_dir/lsblk.txt" 2>/dev/null || true

    # GPU info
    if has_cmd glxinfo; then
        glxinfo | grep -E '(OpenGL vendor|OpenGL renderer|OpenGL version)' > "$hw_dir/gpu-info.txt" 2>/dev/null || true
    fi

    # Firmware/microcode status
    journalctl -k --no-pager | grep -i microcode > "$hw_dir/microcode-log.txt" 2>/dev/null || true

    # Battery info (if laptop)
    if [[ -d /sys/class/power_supply/BAT0 ]]; then
        cat /sys/class/power_supply/BAT0/status > "$hw_dir/battery-status.txt" 2>/dev/null || true
    fi
}

# -- Summary & Warnings -----------------------------------------------------

print_summary() {
    section "Audit Complete"

    local total_size
    total_size="$(du -sh "$SNAPSHOT_DIR" 2>/dev/null | awk '{print $1}')"
    local total_files
    total_files="$(find "$SNAPSHOT_DIR" -type f | wc -l | tr -d ' ')"

    echo ""
    echo -e "  ${BOLD}Snapshot:${NC} $SNAPSHOT_DIR"
    echo -e "  ${BOLD}Size:${NC}     $total_size"
    echo -e "  ${BOLD}Files:${NC}    $total_files"
    echo ""
}

print_security_warning() {
    echo -e "${BOLD}${YELLOW}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YELLOW}│  ⚠  SECURITY WARNING                                      │${NC}"
    echo -e "${BOLD}${YELLOW}│                                                            │${NC}"
    echo -e "${BOLD}${YELLOW}│  The snapshot directory contains sensitive data:            │${NC}"
    echo -e "${BOLD}${YELLOW}│  • SSH configuration                                       │${NC}"
    echo -e "${BOLD}${YELLOW}│  • Network credentials (WiFi passwords)                    │${NC}"
    echo -e "${BOLD}${YELLOW}│  • Shell history and environment variables                  │${NC}"
    echo -e "${BOLD}${YELLOW}│  • Potentially API tokens in config files                   │${NC}"
    echo -e "${BOLD}${YELLOW}│                                                            │${NC}"
    echo -e "${BOLD}${YELLOW}│  DO NOT commit this directory to version control.           │${NC}"
    echo -e "${BOLD}${YELLOW}│  DO NOT upload it to any public service.                    │${NC}"
    echo -e "${BOLD}${YELLOW}│  Transfer it directly to the target machine via rsync/scp.  │${NC}"
    echo -e "${BOLD}${YELLOW}└────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# -- Main --------------------------------------------------------------------

main() {
    echo -e "${BOLD}Fedora Migration Audit${NC}"
    echo -e "Host: $(hostname) | User: $USER | $(date)"
    echo -e "Snapshot: $SNAPSHOT_DIR"

    # Pre-flight checks
    if [[ "$(id -u)" -eq 0 ]]; then
        error "Do not run this script as root. Run as your normal user."
        error "The script will read system files that are world-readable."
        error "Some captures (NetworkManager, SDDM) may be incomplete without root."
        exit 1
    fi

    init_snapshot
    capture_manifest
    capture_packages
    capture_shell
    capture_desktop
    capture_dotfiles
    capture_system
    capture_devtools
    capture_audio
    capture_thirdparty
    capture_hardware
    print_summary
    print_security_warning
}

main "$@"
