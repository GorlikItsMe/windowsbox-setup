# windowsbox-setup

One PowerShell file that turns a fresh Windows 11 install into a ready dev box:
debloat, sane settings, the full toolchain, and remote access over Tailscale.

```powershell
powershell -c "irm https://raw.githubusercontent.com/GorlikItsMe/windowsbox-setup/main/win-setup.ps1 | iex"
```

> The repo has to be **public** for this one-liner to work (`raw.githubusercontent.com`
> returns 404 for private repos).

The script asks a few questions (ENTER = default = install everything), elevates
itself through UAC and then runs unattended. It is idempotent: re-run it to retry
anything that failed.

## What it does

| Phase | |
|---|---|
| 1. debloat | runs the latest [Win11Debloat](https://github.com/Raphire/Win11Debloat) release (SHA-256 verified) with `-RunDefaults -Silent` plus a few personal tweaks: End Task in taskbar, file extensions, classic context menu, Explorer opens This PC, clean Start |
| 2. settings | long paths, Developer Mode, `ExecutionPolicy RemoteSigned` |
| 3. packages | installs everything below via `winget`, skipping what is already there |
| 4. post-config | global git config + aliases, ed25519 SSH key + ssh-agent, `Terminal-Icons` / `posh-git`, noVNC, T3 Code autostart |

At the end it prints a summary, the noVNC URL and your SSH public key.

## Packages

| | |
|---|---|
| **Core** | Git, GitHub CLI, PowerShell 7, Windows Terminal, 7-Zip, WinDirStat, VS Code, Cursor, Claude Code, opencode, Antigravity, ripgrep, fd, fzf, jq, curl, FFmpeg, fastfetch, Node.js LTS, Bun, pnpm, Python 3.15, uv, .NET SDK 10, Tailscale, T3 Code |
| **Optional** | Chrome, VS Code Insiders, Claude Desktop |

Everything is configured in the `$CONFIG` block at the top of `win-setup.ps1`.

## Remote access (noVNC over Tailscale)

- **TightVNC** runs as a service, listening on `127.0.0.1` only, **without a password**.
- **websockify + noVNC** serve the web client on the Tailscale address, port `6080`,
  started at boot by the scheduled task `win-setup noVNC`.
- Firewall allows `6080` from `100.64.0.0/10` (tailnet) only and blocks `5900`.

Open `http://<tailnet-host>:6080/` from any device in your tailnet. Anyone in your
tailnet can take over the desktop. If that's too much, enable "Require VNC
authentication" in TightVNC Server and append `&password=...` to the URL.

## T3 Code autostart

T3 Code has no "start minimized" option, so the script adds a `T3 Code (minimized)`
shortcut to `shell:startup` that launches it and minimizes the main window.

## Parameters

| Parameter | |
|---|---|
| `-WhatIfOnly` | dry run: print the plan, change nothing, no admin needed |
| `-Yes` | no questions, use defaults |
| `-NoDebloat` | skip Win11Debloat |
| `-Aggressive` | extra debloat: Copilot, Recall, widgets, Xbox Game Bar, location, ... |
| `-RemoveOneDrive` | uninstall OneDrive |
| `-NoOptional` | Core packages only |
| `-NoRemote` | no TightVNC / noVNC |
| `-NoT3Autostart` | no T3 Code autostart |
| `-OnlyRemote` | only (re)build noVNC and T3 autostart |
| `-GitUserName`, `-GitUserEmail` | set git identity without the prompt |
| `-Reboot` | restart when done |
| `-Revert` | open Win11Debloat's restore window (its own registry backups) |

Running from a local copy: `.\win-setup.ps1 -WhatIfOnly`, `.\win-setup.ps1 -Yes -NoOptional`.

## Logs

- `%LOCALAPPDATA%\win-setup\log-*.log` — this script
- `%LOCALAPPDATA%\win-setup\Win11Debloat.log` — debloat phase
- `%ProgramData%\win-setup\novnc\novnc.log` — websockify
- `%LOCALAPPDATA%\win-setup\T3CodeStartup\startup.log` — T3 Code launcher

Undoing the debloat: `-Revert` → "Restore backup". Removed apps are not restored;
reinstall them from the Store.

## Notes

- Save `win-setup.ps1` as **UTF-8 without BOM** — a BOM breaks `irm | iex`.
- Not handled: Windows activation, migrating files/keys/app settings, Store-only apps.
- After the run: open a new terminal (new PATH), then `gh auth login`, `tailscale up`,
  and sign in to `claude` / `opencode`.
