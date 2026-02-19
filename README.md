# Fedora Laptop Migration

Replicate a fully configured Fedora KDE workstation onto a fresh Fedora install — every visual, functional, and behavioral aspect of the source machine reproduced on the target.

## Overview

| Component | Purpose |
|---|---|
| `audit.sh` | Captures complete system state on the source machine (read-only) |
| `populate.sh` | Transforms the audit snapshot into Ansible variables and role files |
| `site.yml` | Ansible playbook that applies the captured state to a fresh install |

## Source Machine

The audit script uses standard Fedora tools (`rsync`, `rpm`, `dnf`, `flatpak`, `systemctl`, etc.). It runs as your normal user — not root. Some captures (NetworkManager profiles, SDDM config) may be incomplete without root-readable files; the playbook handles those separately.

```bash
./audit.sh    # creates snapshot/
```

## Target Machine Setup

Starting from a fresh Fedora KDE install (first boot or live session), both machines on the same LAN:

### 1. Install prerequisites

```bash
sudo dnf install ansible git rsync python3-libselinux
```

Install the required Ansible collections:

```bash
ansible-galaxy collection install community.general ansible.posix
```

### 2. Clone this repository

```bash
git clone https://github.com/YOUR_USERNAME/fedora-migrate.git
cd fedora-migrate
```

### 3. Run the audit on the source machine

On the **source** machine:

```bash
cd fedora-migrate
./audit.sh
```

This creates `snapshot/` in the current directory.

### 4. Transfer the snapshot (and SSH keys) to the target machine

Ensure SSH is running on the **source** machine:

```bash
sudo dnf install openssh-server
sudo systemctl enable --now sshd
```

Get the source machine's IP:

```bash
hostname -I    # first address is typically your LAN IP
```

On the **target** machine, pull the snapshot from the source via rsync:

```bash
# Replace SOURCE_IP and SOURCE_USER for your setup
rsync -avz --progress SOURCE_USER@SOURCE_IP:~/git/fedora-migrate/snapshot/ ./snapshot/

# Also transfer SSH keys now (avoids a manual step later)
rsync -av SOURCE_USER@SOURCE_IP:~/.ssh/id_* ~/.ssh/
chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_* && chmod 644 ~/.ssh/id_*.pub
```

### 5. Populate the playbook

```bash
./populate.sh
```

This reads `snapshot/` and generates:
- `group_vars/all.yml` — all variables for the playbook
- Files in `roles/*/files/` — config files, themes, wallpapers, etc.

### 6. Review and adjust

```bash
# Review the generated variables
$EDITOR group_vars/all.yml

# Dry run — see what would change without applying
ansible-playbook site.yml --check --diff --ask-become-pass
```

### 7. Run the playbook

```bash
ansible-playbook site.yml --ask-become-pass
```

Run specific roles if you prefer incremental migration:

```bash
ansible-playbook site.yml --tags repos,packages --ask-become-pass
ansible-playbook site.yml --tags shell
ansible-playbook site.yml --tags desktop
# etc.
```

### 8. Verify

```bash
# Reboot first, then:
./verify.sh
```

See `MANUAL_STEPS.md` for the few items that require human intervention (browser logins, Bluetooth pairing, etc.).
