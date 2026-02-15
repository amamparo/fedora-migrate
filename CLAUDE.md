# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

Fedora laptop migration toolkit: capture a fully configured Fedora KDE workstation's state and reproduce it on a fresh install via Ansible. The detailed spec is in [TODO.md](TODO.md) — read it before starting any work.

## Current State

This is a greenfield project. TODO.md is the authoritative spec. No implementation exists yet.

## Architecture (Three Components)

1. **`audit.sh`** — Read-only bash script run on the source machine. Captures full system state into `laptop-snapshot/` with a `manifest.json`. Build this first; the playbook depends on its output.
2. **`populate.sh`** — Bridge script that transforms `laptop-snapshot/` data into Ansible variables (`group_vars/all.yml`) and config files (`files/`).
3. **Ansible Playbook (`site.yml`)** — Role-based, tagged, idempotent. Targets Ansible 2.15+. Prefer `ansible.builtin` modules over `shell`/`command`. Must support `--check --diff` dry runs. Only use `become: true` for system-level tasks.

## Commands

```bash
# Audit (source machine)
./audit.sh                                    # outputs to laptop-snapshot/

# Populate (target machine, after rsync-ing snapshot)
./populate.sh                                 # fills group_vars/all.yml and files/

# Playbook
ansible-playbook site.yml                     # full run
ansible-playbook site.yml --check --diff      # dry run
ansible-playbook site.yml --tags repos        # single role
ansible-playbook site.yml --syntax-check      # validate syntax
ansible-playbook site.yml --list-tags         # list available tags
```

## Security — This Repo Is Public

**`.gitignored` directories (contain sensitive user data):**
- `laptop-snapshot/` — SSH configs, network credentials, API tokens
- `files/` — Populated user config copies

Only playbook structure, roles, templates, and placeholder variables get committed. `group_vars/all.yml` after population contains user-specific package lists — review before committing.
