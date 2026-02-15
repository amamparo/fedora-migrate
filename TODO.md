# TODO: Ansible Playbook for Fedora Laptop Migration

## Goal

Replicate a fully configured Fedora KDE workstation onto a fresh Fedora install — as close to a system clone as possible without being a literal disk clone. Every visual, functional, and behavioral aspect of the source machine should be reproduced on the target.

- Source: Lenovo ThinkPad, AMD CPU, Fedora, fully configured
- Target: Same ThinkPad model, Intel CPU, fresh Fedora install (same version)
- Shell: zsh
- Desktop: KDE Plasma

---

## Part 1: Audit Script (`audit.sh`)

A read-only bash script that runs on the source machine and captures **everything** needed to reproduce the system. It should output a structured snapshot directory.

### What to capture (by intent, not exhaustive file lists)

**Packages & repos** — Every explicitly installed package (not auto-dependencies), every enabled repo (RPM Fusion, COPR, third-party), every Flatpak app and remote. Also capture packages that were installed from local RPM files or outside any repo.

**Shell environment** — Full zsh setup including plugin manager, plugins, themes, all rc/profile/env files, aliases, functions, and any sourced dependencies.

**Entire desktop environment** — The full KDE Plasma visual and functional state: panel layout, widgets, wallpapers (the actual image files, not just config references), themes, icon packs, cursor theme, window decorations, fonts/rendering, color schemes, keyboard shortcuts, login screen (SDDM), lock screen, splash screen, Konsole/terminal profiles. If the user would notice a difference after migration, it should be captured.

**User dotfiles & app configs** — Everything in `~/.config/` and `~/.local/share/` that represents user customization. Git config, SSH config (not private keys), editor configs, terminal configs, file manager settings, etc.

**System-level customizations** — Anything the user has changed from Fedora defaults: custom fstab entries, sysctl tuning, udev rules, module configs, firewall rules, enabled/disabled systemd services (both system and user level), GRUB config, /etc/hosts, NetworkManager profiles, power management.

**Development tools** — Language-specific package managers (pip user packages, npm globals, cargo installs, go binaries), version managers (pyenv, nvm, rustup, sdkman, etc.).

**Audio/music production setup** — PipeWire/JACK config, realtime scheduling, audio plugin paths, any udev rules for audio hardware.

**Third-party / manually installed software** — Anything in /usr/local/bin, /opt, ~/Applications, AppImages, or custom .desktop files that isn't managed by a package manager. For each, try to identify the source (GitHub release, website, etc.). Flag anything that can't be automatically reproduced for human review.

**Hardware-specific config** — Kernel parameters, GRUB customizations, TLP/power management settings.

### Output

A `laptop-snapshot/` directory with a logical structure and a `manifest.json` containing metadata (hostname, date, Fedora version, kernel version). The structure should make it easy for the Ansible populate step to consume.

---

## Part 2: Ansible Playbook

### Architecture

Role-based playbook that consumes the audit snapshot and applies it to a fresh Fedora install.

Include a `populate.sh` bridge script that reads from `./laptop-snapshot/` and fills in the Ansible variables and copies config files into the playbook's `files/` directory.

### Key principles

- **Completeness over elegance** — if the user would notice something missing, it's a bug
- **Idempotent** — safe to re-run without side effects
- **Tagged roles** — every role should be independently runnable via `--tags`
- **Least privilege** — only use `become: true` for system-level tasks
- **Variables over hardcoding** — package lists, repo URLs, etc. should be in `group_vars/all.yml`
- **Clear separation** — what can be automated vs. what needs manual intervention
- **`--check --diff` compatible** for dry runs
- **Target Ansible 2.15+**, prefer `ansible.builtin` modules over shell/command

### Roles (organize as makes sense, but cover these concerns)

1. **Repos & package sources** — get all repos configured first so packages can install
2. **Packages** — DNF, Flatpak, anything else. Handle missing/unavailable packages gracefully
3. **Shell** — zsh, plugin manager, dotfiles, user scripts
4. **Desktop environment** — full KDE Plasma state restoration (visual + functional)
5. **System config** — sysctl, udev, fstab, firewall, services, GRUB, network
6. **Dev tools** — language package managers, version managers (run as user, not root)
7. **Audio** — PipeWire config, realtime scheduling, audio plugins
8. **Third-party software** — automate what's possible, generate `MANUAL_STEPS.md` for the rest
9. **Hardware** — Intel microcode, power management, AMD→Intel specific adjustments

### Generate these supplementary docs

- **`README.md`** — project overview with two distinct setup sections:
  1. **Source machine requirements** — what needs to be installed/available on the source machine before running `audit.sh` (e.g., any tools the audit script depends on that might not be present by default on Fedora)
  2. **Target machine setup** — pre-Ansible bootstrap steps assuming a completely bare fresh Fedora install. Walk through everything needed before `ansible-playbook site.yml` can run: installing Ansible itself, cloning the repo, **transferring the snapshot from the source machine via `rsync` over the local network**, running `populate.sh`, etc. Assume the user is starting from a terminal on a fresh Fedora KDE live session or first boot. Both machines will be on the same LAN.
- **`MANUAL_STEPS.md`** — things the playbook can't automate: SSH key migration, browser logins, Bluetooth re-pairing, API tokens, third-party apps that need manual install, etc.
- **`POST_INSTALL.md`** — verification checklist to run after the playbook completes to confirm everything works

---

## Implementation Notes

- Build the audit script first — the playbook depends on its output
- The playbook should work with placeholder values that get filled in by `populate.sh`
- The audit script must be completely non-destructive / read-only
- Don't over-specify file paths in the playbook — discover them dynamically where possible
- The AMD→Intel transition is mostly transparent on Fedora, but ensure correct microcode and firmware packages are installed

### Security — this repo is intended to be public

- **The `laptop-snapshot/` directory must be `.gitignored`** — it contains sensitive data (SSH config, network credentials, hostnames, email addresses, potentially API tokens in shell configs)
- **The `files/` directory (populated by `populate.sh`) should also be `.gitignored`** — it contains copies of the user's actual configs
- Only the playbook structure, roles, templates, and placeholder variables should be committed
- The audit script should warn the user at completion that the snapshot contains sensitive data and should not be shared or committed
- `group_vars/all.yml` after population will contain user-specific package lists — this is generally fine to commit but the user should review it first
- Include a `.gitignore` in the project root that covers all of this by default
