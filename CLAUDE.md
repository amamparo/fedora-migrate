# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

Fedora laptop migration toolkit: captures a fully configured Fedora KDE workstation's state and reproduces it on a fresh install via Ansible.

## Architecture (Three Components)

1. **`audit.sh`** — Read-only bash script run on the source machine. Captures full system state into `snapshot/` with a `manifest.json`. Organized into capture functions (one per concern: packages, shell, desktop, dotfiles, system, devtools, audio, thirdparty, hardware).
2. **`populate.sh`** — Bridge script that transforms `snapshot/` data into Ansible variables (`group_vars/all.yml`) and copies config files into `roles/*/files/` directories.
3. **Ansible Playbook (`site.yml`)** — 9 tagged roles applied to localhost. Targets Ansible 2.15+. Prefers `ansible.builtin` modules. Only uses `become: true` for system-level tasks. Must support `--check --diff` dry runs.

### Data Flow

```
Source machine              Target machine
audit.sh → snapshot/ --rsync--> populate.sh → group_vars/all.yml + roles/*/files/
                                           → ansible-playbook site.yml
                                           → verify.sh
```

### Role Execution Order

repos → packages → shell → desktop → system → devtools → audio → thirdparty → hardware

Each role is independently runnable via `--tags`. Role defaults live in `roles/*/defaults/main.yml`; populated values override via `group_vars/all.yml`.

## Commands

```bash
# Audit (source machine)
./audit.sh                                    # outputs to snapshot/

# Populate (target machine, after rsync-ing snapshot)
./populate.sh                                 # fills group_vars/all.yml + roles/*/files/

# Playbook
ansible-playbook site.yml --ask-become-pass   # full run
ansible-playbook site.yml --check --diff      # dry run
ansible-playbook site.yml --tags repos        # single role
ansible-playbook site.yml --syntax-check      # validate syntax
ansible-playbook site.yml --list-tags         # list available tags

# Post-install verification
./verify.sh                                   # run after reboot
```

## Shell Script Patterns (audit.sh / populate.sh)

Both scripts use `set -euo pipefail`. Key pitfalls we've hit:

- **`< /dev/null` on dnf/rpm commands** to prevent stdin reads that hang the script — but never on `xargs` (it overrides the pipe input).
- **`((var++)) || true`** — bare arithmetic with `set -e` exits on zero result; always append `|| true`.
- **`{ cmd || true; } | ...`** — when a pipeline command (like `rpm -q`) legitimately returns non-zero, wrap it to prevent `pipefail` from killing the script.
- **dnf5 output format** differs from dnf4: key-value pairs with `: value` continuations, not indented blocks. Parse with awk accordingly.
- **COPR repo files** on Fedora use both `_copr_` and `_copr:` prefixes — use glob pattern `_copr[_:]*`.

## Security — This Repo Is Public

**`.gitignored` (contain sensitive user data):**
- `snapshot/` — SSH configs, network credentials, API tokens
- `roles/*/files/*` — Populated user config copies (except `.gitkeep`)
- `group_vars/all.yml` — User-specific package lists (review before committing)

Only playbook structure, roles, templates, defaults, and placeholder examples get committed.
