# Post-Install Verification

Reboot after the playbook completes, then:

```bash
./verify.sh
```

This automatically checks: shell, network, repos, Flatpak, PipeWire, microcode, GPU, firewall, printers, dev tools, and more.

## Manual Visual Checks

Things only human eyes can verify:

- [ ] Plasma panels, widgets, wallpaper match source
- [ ] Color scheme, icon theme, cursor theme correct
- [ ] Window decorations and font rendering look right
- [ ] SDDM login screen theme matches
- [ ] Audio output works (play something)
- [ ] Suspend/resume works
- [ ] Brightness and keyboard backlight controls work

## If Something's Off

1. Re-run the specific role: `ansible-playbook site.yml --tags <role>`
2. KDE changes may need logout/login to take effect
3. Font issues: `fc-cache -fv` and restart
4. Check `MANUAL_STEPS.md` for items that need manual setup
