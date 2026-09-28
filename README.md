# CodeBuddy Helper

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![校验](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml/badge.svg)](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml)

**简体中文** | [English](README.en.md)

## 为什么有这个插件

在编辑器里用 CodeBuddy 干活，任务跑完之后**没有任何提醒**——你得自己盯着输出，或者隔一会儿切回来看一眼。

官方自带的通知又慢：它靠扫日志判断任务结束了没有，实测要等 **15 秒到 7 分钟**。

所以就写了这个插件。

---

给 CodeBuddy（VS Code 扩展 `tencent-cloud.coding-copilot`）补两块能力：

1. **零延迟完成通知** —— CodeBuddy 自己弹通知要等 15 秒到 7 分钟（它靠扫日志判断任务结束），本插件用 hook 在任务结束的瞬间就弹。
2. **失败自动重试** —— 撞上 429 / 5xx（限流、网关抖动）、内容审核拦截，或「服务出现异常，请重试」（后端服务响应状态码异常，常见错误码 500）这类服务端故障时，自动把未完成的任务续上。

附带：自定义通知音效、点通知跳回对应项目、危险命令待确认提醒（漏看 3 分钟后补提醒）、任务耗时。

**目前只支持 Windows + VS Code。** 通知走 Windows Toast（所以必须在 Windows 上）；
自动重试依赖 CodeBuddy 的 VS Code 扩展提供的命令。

---

## 装

**前提**：Windows 10 及以上、装了 VS Code、并且装好了 CodeBuddy。本插件是配合 CodeBuddy 的，CodeBuddy 不在就弹不出通知。

### 最简单的办法

从 [Releases](https://github.com/iloveaimer/CodeBuddy-Helper/releases) 下载 `CodeBuddy-Helper.vsix`，
双击它 → VS Code 会问你是否安装 → 装 → **完全退出并重启 VS Code**。

（源码在本地的话，`dist\CodeBuddy-Helper.vsix` 是同一个东西。）

### 或者跑脚本

```
install.bat
```

它会自己找 VS Code 的命令行工具（PATH 上找不到就翻常见安装位置），并且**优先挑真正装了 CodeBuddy 的那个**——同时装了正式版和 Insiders 时，装错变体等于没装。

---

## 装完之后，插件自己会做的事

不需要你动手。第一次激活时它完成这些：

| 做什么 | 落点 |
| --- | --- |
| 注册通知来源（否则通知显示成"未知程序"） | `HKCU\Software\Classes\AppUserModelId\CBH` |
| 写完成通知 hook | `%USERPROFILE%\.codebuddy\settings.json` |
| 写任务耗时 hook | 同上 |
| 建自定义音效目录 | `%USERPROFILE%\.codebuddy-helper\sounds` |

写 `settings.json` 之前会备份成 `settings.json.bak`，而且**只做合并**：你原有的插件开关和其它 hook 一律不动。指向的脚本要是被移走了，插件会自己把路径纠正回来。

**然后重开一个 CodeBuddy 会话** —— hook 是会话开始时读取的，不重开会话不生效。

---

## 确认装好了

命令面板（`Ctrl+Shift+P`）→ `CodeBuddy Helper: 测试通知`，应该弹出一条 Windows 通知。

这条命令特意绕过了「VS Code 在前台就不打扰」的规则，所以你在编辑器里也会看到它。
但 `notifyOnComplete` 关掉时它照样不弹——那就是配置里通知被关了，不是插件坏了。

---

## 配置

设置里搜 `codebuddyHelper`：

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `pollInterval` | 3 秒 | 日志扫描间隔 |
| `retryCooldown` | 30 秒 | 两次重试之间的最小间隔 |
| `retryDelay` | 5 秒 | 检测到错误后等多久开始重试（429 走指数退避，封顶 60 秒） |
| `notifyOnComplete` | 开 | 任务完成时弹通知 |
| `notifyOn429` | 开 | 限流 / 服务端错误 / 内容审核拦截时通知并自动重试 |

---

## 自定义通知音效

目录：`%USERPROFILE%\.codebuddy-helper\sounds`
（命令面板 → `CodeBuddy Helper: 打开通知音效目录`）

- `done.*` 完成时播放，`confirm.*` 待确认时播放，`default.*` 作为通用兜底
- 支持 `.wav .mp3 .m4a .wma .aac .flac .ogg`，**`.wav` 播放最稳**
- 一个音频都不放，就用 Windows 系统默认通知音
- 目录里只有唯一一个音频文件时，直接用它，不用改名
- `C:\Windows\Media\` 里有 70 多个现成音效，复制过来改名即可

---

## 出问题

先看日志：命令面板 → `CodeBuddy Helper: 显示运行日志`。

| 症状 | 多半是 | 怎么办 |
| --- | --- | --- |
| 完全不弹通知 | hook 没写进配置，或 CodeBuddy 没装 | 命令面板 → `CodeBuddy Helper: 修复通知配置` |
| 弹了，但来源显示"未知程序" | 通知来源没注册 | 重启 VS Code，插件激活时会自动补注册 |
| 有通知没声音 | 音效格式不支持 | 换成 `.wav` |
| 通知来得很晚（十几秒以上） | 走的是 CodeBuddy 自带的日志通知，不是本插件的 hook | 检查 `settings.json` 里的 `Stop` hook 是否指向 `cb-hook.ps1` |
| 弹了「处理过程出现异常，请重试」 | 撞上了内容审核拦截，CodeBuddy 自己只内部重试 1 次就放弃 | 本插件会自动续跑，最多 10 次；状态栏显示「内容审核拦截 第 N 次」 |
| 弹了「服务出现异常，请重试」（错误码 500） | 后端服务响应状态码异常，日志里整行没有 HTTP 字样 | 本插件会从相邻日志行取状态码自动续跑，最多 10 次；状态栏显示「HTTP 500 第 N 次」 |
| 弹了「任务中断，未正常完成」 | 任务撞上服务端错误收尾了，本插件会自动补重试 | 这是对的，别当成跑完了；等重试跑通后会再弹一条「任务执行完成」 |
| 429 没有自动重试 | `notifyOn429` 被关了，或已达 10 次上限 | 状态栏会显示重试进度，日志里也有 `HTTP 429 ... 已挂起` |
| 某个项目 429 后没自动重试 | 那个项目不在任何 VS Code 窗口里打开着（重试必须发回它自己的会话，所以只由持有它的窗口负责） | 打开该项目 |
| 点了通知不跳转 | 那条通知没带项目地址（1.2.0 的扩展通知路径有这个问题） | 升级到 1.2.1 以上，然后**重载窗口** |
| 装完没反应 | 只 Reload Window 了 | 要完全退出 VS Code 进程再启动 |

hook 自己的日志：`%TEMP%\cbh-hook.log`

### 卸载

```
uninstall.bat
```

会**先清掉 `settings.json` 里的 hook，再卸扩展**。顺序反过来会在配置里留一条指向已删脚本的 hook，CodeBuddy 之后每次 Stop 都会去跑一个不存在的文件。

---

## 给改代码的人

| 脚本 | 作用 |
| --- | --- |
| `verify.ps1` | **发布前自检**，把下面那些坑做成了自动检查 |
| `package-vsix.ps1` | 打包 → `dist\CodeBuddy-Helper.vsix` |
| `install.bat` / `install.ps1` | 打包 + 安装 |
| `uninstall.bat` / `uninstall.ps1` | 先清 hook，再卸扩展 |

| 源码 | 作用 |
| --- | --- |
| `extension.js` | VS Code 侧：日志轮询、重试队列、hook 与通知来源的自动注册 |
| `cb-hook.ps1` | CodeBuddy hook：零延迟弹通知，判断"真干完了"还是"卡在等你确认" |
| `cb-sound.ps1` | 自定义音效播放（独立子进程，不阻塞 hook） |

改完先跑一次自检，再安装：

```powershell
powershell -ExecutionPolicy Bypass -File verify.ps1   # 编码、语法、打包内容
install.bat                                            # 打包 + 安装
```

然后完全重启 VS Code。`main` 分支上的 CI 会跑同一套自检。

### 三个容易踩的坑

- **`.ps1` 必须带 BOM。** PowerShell 5.1 读无 BOM 文件时按系统 ANSI 码页解码，UTF-8 中文会变成乱码——注释乱掉只是难看，字符串字面量乱掉会直接打到用户界面上。
- **`.bat` 必须纯 ASCII。** cmd 按 OEM 码页读 `.bat`，中文注释在不同语言的 Windows 上会乱，可能引发诡异的解析错误。
- **hook 脚本不进 VSIX 就等于没装。** `package-vsix.ps1` 里的 `Copy-Item` 必须和实际用到的脚本同步维护。扩展本身只做轮询和注册，通知全靠 `cb-hook.ps1`。

---

## 许可

[MIT](LICENSE)

## 说明

本项目的做法是读取 CodeBuddy 的日志、注册 hook 来补齐通知体验，属于第三方配套工具，
与 CodeBuddy 官方无关。使用前请自行确认这符合你所使用版本的服务条款。