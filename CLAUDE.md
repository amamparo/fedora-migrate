# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Fedora laptop migration toolkit designed to replicate a fully configured Fedora KDE workstation onto a fresh install. The goal is to achieve near-perfect system cloning without literal disk cloning.

**Components:**
1. **`audit.sh`** - Bash script that captures complete system state from source machine (read-only)
2. **Ansible Playbook** - Role-based playbook that applies captured state to target machine
3. **`populate.sh`** - Bridge script that transforms audit snapshot into Ansible variables and files

## Architecture

### Audit Script (`audit.sh`)
- Must be completely read-only and non-destructive
- Outputs to `laptop-snapshot/` directory with structured data
- Generates `manifest.json` with metadata (hostname, date, Fedora version, kernel)
- Captures: packages, repos, shell config, KDE Plasma state, dotfiles, system customizations, dev tools, audio setup, third-party software, hardware configs

### Ansible Playbook
- Role-based structure with independent, tagged roles
- Consumes `laptop-snapshot/` via `populate.sh` preprocessing
- Target Ansible 2.15+, prefer `ansible.builtin` modules
- Must be idempotent and `--check --diff` compatible
- Uses `group_vars/all.yml` for variables, `files/` for config files

### Expected Roles
1. `repos` - Configure package sources before anything else
2. `packages` - DNF, Flatpak installations
3. `shell` - zsh, plugins, dotfiles
4. `desktop` - Full KDE Plasma state restoration
5. `system` - sysctl, udev, fstab, firewall, services, GRUB
6. `devtools` - Language package managers, version managers (run as user)
7. `audio` - PipeWire config, realtime scheduling
8. `thirdparty` - Third-party software (generate MANUAL_STEPS.md for non-automatable items)
9. `hardware` - Microcode, power management, AMD→Intel adjustments

## Key Principles

- **Completeness over elegance** - If the user would notice it missing, it's a bug
- **Least privilege** - Only use `become: true` when necessary for system-level tasks
- **Variables over hardcoding** - Keep package lists and configs in variables
- **Tagged execution** - Every role must support `--tags` for independent runs
- **Clear separation** - Distinguish what can be automated vs. requires manual intervention

## Security (This repo is PUBLIC)

**CRITICAL:** The following directories contain sensitive user data and MUST be `.gitignored`:
- `laptop-snapshot/` - Contains SSH configs, network credentials, hostnames, emails, API tokens
- `files/` - Contains copies of actual user configs (populated by `populate.sh`)

Only commit: playbook structure, roles, templates, placeholder variables

The audit script must warn users that the snapshot contains sensitive data.

## Common Commands

### Running the Audit (on source machine)
```bash
./audit.sh
# Outputs to laptop-snapshot/
```

### Preparing the Playbook (on target machine, after transferring snapshot via rsync)
```bash
./populate.sh
# Reads from laptop-snapshot/, populates group_vars/all.yml and files/
```

### Running the Playbook
```bash
# Full run
ansible-playbook site.yml

# Dry run
ansible-playbook site.yml --check --diff

# Specific role
ansible-playbook site.yml --tags repos
ansible-playbook site.yml --tags packages,shell
```

### Testing During Development
```bash
# Validate playbook syntax
ansible-playbook site.yml --syntax-check

# List all tags
ansible-playbook site.yml --list-tags

# List all tasks
ansible-playbook site.yml --list-tasks
```

## Development Workflow

1. Build `audit.sh` first - the playbook depends on its output
2. Test audit script on source machine, inspect `laptop-snapshot/` structure
3. Develop playbook with placeholder data that `populate.sh` will fill
4. Test playbook roles independently using tags
5. Generate supplementary docs: README.md, MANUAL_STEPS.md, POST_INSTALL.md

## File Discovery

Don't hardcode paths - discover them dynamically where possible. KDE config locations:
- `~/.config/` - Application configs
- `~/.local/share/` - Application data, themes, wallpapers
- `~/.local/share/kservices5/` - KDE service definitions
- `/etc/sddm.conf.d/` - Login manager config

## Hardware Transition Notes

AMD → Intel transition is mostly transparent on Fedora, but ensure:
- Correct microcode package (intel-microcode vs. amd-ucode)
- Intel-specific firmware packages if needed
- Power management configs may differ (TLP, thermald)
