# Manual Steps

Items the playbook cannot automate. Complete these after running the playbook.

> **Note:** The `thirdparty` role may regenerate this file with additional entries specific to your system.

## SSH Keys

```bash
rsync -av SOURCE_USER@SOURCE_IP:~/.ssh/id_* ~/.ssh/
chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_* && chmod 644 ~/.ssh/id_*.pub
```

## Secrets & Credentials

- **Browser profiles** — sign in to browser sync
- **Application logins** — re-authenticate in email, chat, cloud storage, IDEs
- **API tokens** — check shell configs, `~/.config/`, `.env` files, `~/.netrc`, `~/.npmrc`
- **KDE Wallet** — saved passwords will be re-requested on first use

## Hardware

- **Bluetooth** — all devices must be re-paired
- **Fingerprint reader** — `fprintd-enroll`
