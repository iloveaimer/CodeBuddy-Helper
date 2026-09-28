# CodeBuddy Helper

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![verify](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml/badge.svg)](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml)

[简体中文](README.md) | **English**

> Notified the instant a task finishes, and the task is re-submitted by itself when it hits a server error. A Windows-notification and auto-retry companion for CodeBuddy — Windows + VS Code only.

## Why this exists

When you use CodeBuddy inside your editor, **you get no notification when a task finishes** —
you end up watching the output yourself, or switching back every so often to check.

The notification CodeBuddy does ship is slow, too: it polls its own log to decide whether a task
has ended, which measures **15 seconds to 7 minutes** behind. So this extension fills that gap.

> **The extension's own UI strings are currently Chinese only** — command titles in the palette,
> settings descriptions, and messages. This README documents the commands by their exact
> (Chinese) titles so you can match them in the palette.

## Features

- **Zero-delay completion notifications** — fires from CodeBuddy's `Stop` hook the instant the task
  ends, instead of polling the log.
- **Automatic retry on server errors** — on 429 / 5xx, on content-moderation blocks, or on the
  「服务出现异常，请重试」 dialog (backend response status error, e.g. code 500) it re-submits the
  unfinished task for you, up to 10 attempts. The retry goes back into **the conversation that
  failed**, not the current one.
- **Finished vs. interrupted** — when a task ends because of a server error you get
  「任务中断，未正常完成」 instead of a plain "done", so a failure never reads as a success.
- **"A command is waiting for your confirmation" alerts** — plus one reminder a minute later if the
  first one is missed.
- **Custom notification sounds** — three roles, seven formats, see below.
- **Click a notification to jump back to its project**, and task-duration reporting.

## Requirements

- Windows 10 or later — notifications go through Windows Toast, so Windows is required
- VS Code 1.80 or later
- **CodeBuddy** (the VS Code extension `tencent-cloud.coding-copilot`) — this extension works *with*
  it; without CodeBuddy there is nothing to notify about

## Install

### From the VSIX

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

## Usage

### Verifying the install

Command palette (`Ctrl+Shift+P`) → `CodeBuddy Helper: 测试通知` — a Windows notification should appear.

This one deliberately ignores the "VS Code is in the foreground, stay quiet" rule, so it shows up
even while you are looking at the editor. It is still suppressed when `notifyOnComplete` is off —
in that case no notification is a correct answer, not a broken install.

### What the extension sets up on its own

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

### Commands

| Command | What it does |
| --- | --- |
| `CodeBuddy Helper: 测试通知` | Fires a test notification through the real hook path, to verify the install |
| `CodeBuddy Helper: 显示运行日志` | The log — start here when something is off |
| `CodeBuddy Helper: 选择提示音` | Pick a sound from the Windows system sounds and the sound directory; it is written to your settings |
| `CodeBuddy Helper: 打开通知音效目录` | Opens the custom-sound directory |
| `CodeBuddy Helper: 修复通知配置` | Rewrites the hooks if they went missing or point at a dead path; idempotent |
| `CodeBuddy Helper: 卸载前移除 hook` | Run before uninstalling the extension |

## Settings

Search for `codebuddyHelper` in Settings:

| Setting | Default | Description |
| --- | --- | --- |
| `pollInterval` | 3 s | Log scan interval |
| `retryCooldown` | 30 s | Minimum gap between two retries |
| `retryDelay` | 5 s | How long to wait before retrying (429 uses exponential backoff, capped at 60 s) |
| `notifyOnComplete` | on | Notify when a task completes |
| `notifyWhenFocused` | on | Also notify when the window running that task is focused; turn it off to only be reminded for other windows |
| `notifyOn429` | on | Notify and auto-retry on rate limits / server errors / content-moderation blocks / backend response status errors |
| `soundDone` | empty | Sound for "task finished": absolute path to an audio file; leave empty to use `done.*` from the sound directory or the system default (normally set via the command, not by hand) |
| `soundConfirm` | empty | Sound for "waiting for confirmation / interrupted"; leave empty to use `confirm.*` or the system default |

## Custom notification sounds

### Pick one inside the extension (recommended)

Command palette → `CodeBuddy Helper: 选择提示音`.

The list covers **every Windows system sound** (`C:\Windows\Media\`) plus **any files you put in the
sound directory**. After picking, choose whether it applies to "task finished", "waiting for
confirmation / task interrupted", or both — it is written to your settings and **takes effect
immediately, no restart**.

Two settings back this, if you would rather type a path yourself: `soundDone` (finished) and
`soundConfirm` (waiting for confirmation / interrupted).

### Or just drop a file in

Directory: `%USERPROFILE%\.codebuddy-helper\sounds`
(command palette → `CodeBuddy Helper: 打开通知音效目录`)

- `done.*` plays on completion, `confirm.*` when a confirmation is pending or a task was
  interrupted, `default.*` as a fallback
- Supports `.wav .mp3 .m4a .wma .aac .flac .ogg` — **`.wav` is the most reliable**
- If the directory holds exactly one audio file, that file is used directly — no renaming needed
- Drop a file in and it takes effect immediately — no VS Code restart

### Resolution order

**A file set in Settings → a `done.*` / `confirm.*` match in the sound directory → the only file in
that directory → `default.*` → the Windows default notification sound.**

With no audio files at all, the Windows default notification sound is used. If a path set in
Settings goes stale (file deleted or moved), it silently falls back to the next step rather than
going quiet.

## Troubleshooting

Start with the log: command palette → `CodeBuddy Helper: 显示运行日志`.

| Symptom | Likely cause | What to do |
| --- | --- | --- |
| No notifications at all | The hook was not written to the config, or CodeBuddy is not installed | Command palette → `CodeBuddy Helper: 修复通知配置` |
| Notification appears, but the source reads "Unknown app" | Notification source not registered | Restart VS Code; the extension re-registers on activation |
| Notification arrives silently | Unsupported audio format | Switch to `.wav` |
| Notification is very late (tens of seconds) | It came from CodeBuddy's own log-based notification, not this extension's hook | Check that the `Stop` hook in `settings.json` points to `cb-hook.ps1` |
| No notification at all while you are looking at VS Code | Before 1.2.5 the "focused window" rule silently dropped it | Upgrade to 1.2.5+; to keep the old "only other windows" behaviour, turn `notifyWhenFocused` off |
| Still missing even with the setting on | Windows Focus Assist / Do Not Disturb moved the banner into the notification centre | Turn Focus Assist off. This extension's hook fires in the same second the agent ends — there is no plugin-side delay |
| The 「处理过程出现异常，请重试」 dialog appears | A content-moderation block; CodeBuddy retries internally only once and gives up | This extension re-submits the task, up to 10 attempts; the status bar shows 「内容审核拦截 第 N 次」 |
| The 「服务出现异常，请重试」 dialog appears (e.g. code 500) | Backend response status error; the log line carries no `HTTP` text | This extension reads the status code from adjacent log lines and retries, up to 10 attempts; the status bar shows `HTTP 500 第 N 次` |
| 「任务中断，未正常完成」 appears | The task ended on a server error; this extension will re-submit it | That is correct — it did not finish; a 「任务执行完成」 notification follows once the retry succeeds |
| No auto-retry on 429 | `notifyOn429` is off, or the 10-attempt cap was hit | The status bar shows retry progress; the log has `HTTP 429 ... 已挂起` |
| No auto-retry for one particular project | That project is not open in any VS Code window (a retry has to go back into that project's own conversation, so only the window holding it retries) | Open that project |
| Clicking a notification does not jump to the project | That notification carried no project path (a 1.2.0 bug in the extension's own notification path) | Upgrade to 1.2.1 or later, then **reload the window** |
| Nothing happens after installing | You only ran Reload Window | Fully quit the VS Code process and start it again |

The hook keeps its own log at `%TEMP%\cbh-hook.log`.

## Uninstall

```
uninstall.bat
```

It **removes the hooks from `settings.json` first, then uninstalls the extension.** The opposite
order leaves a hook pointing at a script that no longer exists, and CodeBuddy will then try to run
a missing file on every Stop.

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

## License

[MIT](LICENSE)

## Note

This project reads CodeBuddy's logs and registers hooks to round out the notification experience.
It is a third-party companion tool and is not affiliated with the CodeBuddy team. Please confirm
that using it complies with the terms of service of the version you run.