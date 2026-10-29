# Release checklist

Run all of these from the repo root, on the exact commit you are releasing, **before** building an installer
with `Build-Installer.ps1`. Every one must pass. Stop and fix anything that doesn't.

1. `bash tools/verify-exe.sh` — rebuilds `ButtonLauncher.exe` from `exe/ButtonLauncher.cs` and must print `MATCH`
   (committed exe = clean rebuild = `exe/ButtonLauncher.exe.sha256`).
2. `pwsh -NoProfile -File tools/test-installer-dryrun.ps1` — must end with `ALL PASS`.
3. `pwsh -NoProfile -File check-launcher.ps1` — must check the repo's `Launcher.ps1` and print `NO ISSUES`.
4. `pwsh -NoProfile -File tools/test-modern.ps1` and `tools/test-onepanel.ps1` — both must end with `ALL PASS`.
5. Parse every `.ps1` with the PowerShell parser (0 errors) and keep to PowerShell 5.1 syntax.
6. ClaudeCode and Lockjaw have passed this commit.
7. Then, on Windows: run `Build-Installer.ps1` (it refuses an exe whose SHA-256 doesn't match), install on a test PC,
   check Start menu, Installed apps, Start with Windows, reinstall (keeps buttons.json and your pictures) and Uninstall.
