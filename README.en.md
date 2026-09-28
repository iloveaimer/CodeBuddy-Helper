# CodeBuddy Helper

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![verify](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml/badge.svg)](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml)

[简体中文](README.md) | **English**

## Why this exists

When you use CodeBuddy inside your editor, **you get no notification when a task finishes** —
you end up watching the output yourself, or switching back every so often to check.

The notification CodeBuddy does ship is slow, too: it polls its own log to decide whether a task
has ended, which measures **15 seconds to 7 minutes** behind. So this extension fills that gap.

---

It adds two things to CodeBuddy (the VS Code extension `tencent-cloud.coding-copilot`):

1. **Zero-delay completion notifications** — CodeBuddy's own notification takes 15 seconds to
   7 minutes (it polls its log to decide the task has ended). This extension fires from a hook
   the instant the task ends.
2. **Automatic retry on rate limits** — on 429 / 5xx, on content-moderation blocks, or on the
   「服务出现异常，请重试」 dialog (backend response status error, e.g. code 500) it re-submits
   the unfinished task for you.

Extras: custom notification sounds, click a notification to jump back to that project,
"a command is waiting for your confirmation" alerts (reminded once more after 3 minutes
if the first one is missed), and task duration.

**Windows + VS Code only.** Notifications go through Windows Toast (so Windows is required),
and auto-retry relies on a command exposed by CodeBuddy's VS Code extension.

> **The extension's own UI strings are currently Chinese only** — command titles in the palette,
> settings descriptions, and messages. This README documents the commands by their exact
> (Chinese) titles so you can match them in the palette.

---

## Install

**Requirements**: Windows 10 or later, VS Code, and CodeBuddy already installed.
This extension works *with* CodeBuddy — without it, there is nothing to notify about.

### Easiest way

Download `CodeBuddy-Helper.vsix` from [Releases](https://github.com/iloveaimer/CodeBuddy-Helper/releases),
double-click it → VS Code asks whether to install → install → **fully quit and restart VS Code**.

(If you have the source locally, `dist\CodeBuddy-Helper.vsix` is the same file.)

### Or run the script

```
install.bat
```

It locates the VS Code CLI by itself (falling back to the usual install locations when `code` is
not on `PATH`), and **prefers the variant that actually has CodeBuddy installed** — if you run both
Stable and Insiders, installing into the wrong one achieves nothing.

---

## What the extension sets up on its own

Nothing for you to do. On first activation it:

| Action | Where |
| --- | --- |
| Registers the notification source (otherwise notifications show as "Unknown app") | `HKCU\Software\Classes\AppUserModelId\CBH` |
| Writes the completion-notification hook | `%USERPROFILE%\.codebuddy\settings.json` |
| Writes the task-duration hook | same file |
| Creates the custom-sound directory | `%USERPROFILE%\.codebuddy-helper\sounds` |

Before writing `settings.json` it backs it up to `settings.json.bak`, and it **merges only**:
your existing plugin switches and other hooks are left untouched. If the scripts it points to get
moved, it corrects the path by itself.

**Then reopen a CodeBuddy session** — hooks are read when a session starts, so this will not take
effect until you do.

---

## Verifying the install

Command palette (`Ctrl+Shift+P`) → `CodeBuddy Helper: 测试通知` — a Windows notification should appear.

This one deliberately ignores the "VS Code is in the foreground, stay quiet" rule, so it shows up
even while you are looking at the editor. It is still suppressed when `notifyOnComplete` is off —
in that case no notification is a correct answer, not a broken install.

---

## Settings

Search for `codebuddyHelper` in Settings:

| Setting | Default | Description |
| --- | --- | --- |
| `pollInterval` | 3 s | Log scan interval |
| `retryCooldown` | 30 s | Minimum gap between two retries |
| `retryDelay` | 5 s | How long to wait before retrying (429 uses exponential backoff, capped at 60 s) |
| `notifyOnComplete` | on | Notify when a task completes |
| `notifyOn429` | on | Notify and auto-retry on rate limits / server errors |

---

## Custom notification sounds

Directory: `%USERPROFILE%\.codebuddy-helper\sounds`
(command palette → `CodeBuddy Helper: 打开通知音效目录`)

- `done.*` plays on completion, `confirm.*` when a confirmation is pending, `default.*` as a fallback
- Supports `.wav .mp3 .m4a .wma .aac .flac .ogg` — **`.wav` is the most reliable**
- With no audio files at all, the Windows default notification sound is used
- If the directory holds exactly one audio file, that file is used directly — no renaming needed
- `C:\Windows\Media\` has 70+ ready-made sounds; copy one over and rename it

---

## Troubleshooting

Start with the log: command palette → `CodeBuddy Helper: 显示运行日志`.

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| No notifications at all | The hook was not written to the config, or CodeBuddy is not installed | Command palette → `CodeBuddy Helper: 修复通知配置` |
| Notification appears, but the source reads "Unknown app" | Notification source not registered | Restart VS Code; the extension re-registers on activation |
| Notification arrives silently | Unsupported audio format | Switch to `.wav` |
| Notification is very late (tens of seconds) | It came from CodeBuddy's own log-based notification, not this extension's hook | Check that the `Stop` hook in `settings.json` points to `cb-hook.ps1` |
| No auto-retry on 429 | `notifyOn429` is off, or the 10-attempt cap was hit | The status bar shows retry progress; the log has `HTTP 429 ... 已挂起` |
| The 「服务出现异常，请重试」 dialog appears (e.g. code 500) | Backend response status error; the log line carries no `HTTP` text | This extension reads the status code from adjacent log lines and retries, up to 10 attempts; the status bar shows `HTTP 500 第 N 次` |
| No auto-retry for one particular project | That project is not open in any VS Code window (a retry has to go back into that project's own conversation, so only the window holding it retries) | Open that project |
| Clicking a notification does not jump to the project | That notification carried no project path (a 1.2.0 bug in the extension's own notification path) | Upgrade to 1.2.1 or later, then **reload the window** |
| Nothing happens after installing | You only ran Reload Window | Fully quit the VS Code process and start it again |

The hook keeps its own log at `%TEMP%\cbh-hook.log`.

### Uninstall

```
uninstall.bat
```

It **removes the hooks from `settings.json` first, then uninstalls the extension.** The opposite
order leaves a hook pointing at a script that no longer exists, and CodeBuddy will then try to run
a missing file on every Stop.

---

## For contributors

| Script | Purpose |
| --- | --- |
| `verify.ps1` | **Pre-release self-check**; every pitfall below is an automated check |
| `package-vsix.ps1` | Package into `dist\CodeBuddy-Helper.vsix` |
| `install.bat` / `install.ps1` | Package + install |
| `uninstall.bat` / `uninstall.ps1` | Remove hooks first, then uninstall |

| Source | Purpose |
| --- | --- |
| `extension.js` | VS Code side: log polling, retry queue, auto-registration of hooks and the notification source |
| `cb-hook.ps1` | CodeBuddy hook: instant notifications; decides between "really finished" and "waiting for your confirmation" |
| `cb-sound.ps1` | Custom sound playback (separate process, so it never blocks the hook) |

After changing anything, run the self-check, then install:

```powershell
powershell -ExecutionPolicy Bypass -File verify.ps1   # encoding, syntax, package contents
install.bat                                            # package + install
```

Then fully restart VS Code. CI on `main` runs the same self-check.

### Three easy-to-hit pitfalls

- **`.ps1` files must have a BOM.** Reading a BOM-less file, PowerShell 5.1 decodes it with the
  system ANSI code page, so UTF-8 Chinese turns into mojibake. Garbled comments are merely ugly —
  garbled string literals get shown to users.
- **`.bat` files must be pure ASCII.** `cmd` reads `.bat` with the OEM code page, so Chinese comments
  break on Windows installs of other languages and can cause bizarre parse errors.
- **A hook script that never makes it into the VSIX is not installed.** The `Copy-Item` calls in
  `package-vsix.ps1` must stay in sync with the scripts actually used. The extension itself only
  polls and registers; notifications all come from `cb-hook.ps1`.

---

## License

[MIT](LICENSE)

## Note

This project reads CodeBuddy's logs and registers hooks to round out the notification experience.
It is a third-party companion tool and is not affiliated with the CodeBuddy team. Please confirm
that using it complies with the terms of service of the version you run.