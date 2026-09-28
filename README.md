# CodeBuddy Helper

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![校验](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml/badge.svg)](https://github.com/iloveaimer/CodeBuddy-Helper/actions/workflows/verify.yml)

**简体中文** | [English](README.en.md)

> 任务跑完的那一瞬间就弹通知，撞上服务端错误自动把任务续上。给 CodeBuddy 用的 Windows 通知与自动重试搭档，仅支持 Windows + VS Code。

## 为什么有这个插件

在编辑器里用 CodeBuddy 干活，任务跑完之后**没有任何提醒**——你得自己盯着输出，或者隔一会儿切回来看一眼。

官方自带的通知又慢：它靠扫日志判断任务结束了没有，实测要等 **15 秒到 7 分钟**。

所以就写了这个插件。

## 功能

- **零延迟完成通知** —— 用 CodeBuddy 的 `Stop` hook，任务结束的瞬间就弹 Windows 通知，不走日志轮询。
- **失败自动重试** —— 撞上 429 / 5xx（限流、网关抖动）、内容审核拦截，或「服务出现异常，请重试」（后端服务响应状态码异常，常见错误码 500）时，自动把未完成的任务续上，最多 10 次；
  重试会发回**出错的那次会话**，不是当前会话。
- **区分「跑完」与「出错中断」** —— 任务因服务端错误收尾时弹「任务中断，未正常完成」，不会和「任务执行完成」混为一谈。
- **危险命令待确认提醒** —— 任务停下来等你批准命令时提醒你，漏看 1 分钟后补一次。
- **自定义通知音效** —— 三种用途、七种格式，见下文。
- **任务栏闪烁** —— 横幅被 Windows「专注助手 / 勿扰」收走时，闪一下对应窗口的任务栏按钮兜底。
- **点通知跳回对应项目**、任务耗时统计、状态栏显示有几个项目在等你确认。

## 环境要求

- Windows 10 及以上 —— 通知走 Windows Toast，所以必须在 Windows 上
- VS Code 1.80 及以上
- **CodeBuddy 扩展**（`tencent-cloud.coding-copilot`）—— 本插件是配合它的，CodeBuddy 不在就弹不出通知

## 安装

### 从 VSIX 安装

从 [Releases](https://github.com/iloveaimer/CodeBuddy-Helper/releases) 下载 `CodeBuddy-Helper.vsix`，
双击它 → VS Code 会问你是否安装 → 装 → **完全退出并重启 VS Code**。

（源码在本地的话，`dist\CodeBuddy-Helper.vsix` 是同一个东西。）

### 或者跑脚本

```
install.bat
```

它会自己找 VS Code 的命令行工具（PATH 上找不到就翻常见安装位置），并且**优先挑真正装了 CodeBuddy 的那个**——同时装了正式版和 Insiders 时，装错变体等于没装。

## 使用

### 确认装好了

命令面板（`Ctrl+Shift+P`）→ `CodeBuddy Helper: 测试通知`，应该弹出一条 Windows 通知。

这条命令特意绕过了「VS Code 在前台就不打扰」的规则，所以你在编辑器里也会看到它。
但 `notifyOnComplete` 关掉时它照样不弹——那就是配置里通知被关了，不是插件坏了。

### 插件自己会做的事

第一次激活时它完成这些，不需要你动手：

| 做什么 | 落点 |
| --- | --- |
| 注册通知来源（否则通知显示成"未知程序"） | `HKCU\Software\Classes\AppUserModelId\CBH` |
| 写完成通知 hook | `%USERPROFILE%\.codebuddy\settings.json` |
| 写任务耗时 hook | 同上 |
| 建自定义音效目录 | `%USERPROFILE%\.codebuddy-helper\sounds` |

写 `settings.json` 之前会备份成 `settings.json.bak`，而且**只做合并**：你原有的插件开关和其它 hook 一律不动。指向的脚本要是被移走了，插件会自己把路径纠正回来。

**然后重开一个 CodeBuddy 会话** —— hook 是会话开始时读取的，不重开会话不生效。

### 命令

| 命令 | 作用 |
| --- | --- |
| `CodeBuddy Helper: 测试通知` | 走真实 hook 链路弹一条测试通知，用来验证安装 |
| `CodeBuddy Helper: 显示运行日志` | 排错先看这个 |
| `CodeBuddy Helper: 选择提示音` | 从 Windows 系统音效和音效目录里挑提示音，选完直接写进设置 |
| `CodeBuddy Helper: 打开通知音效目录` | 打开自定义音效目录 |
| `CodeBuddy Helper: 修复通知配置` | hook 丢失或指向失效时用，幂等，可反复执行 |
| `CodeBuddy Helper: 卸载前移除 hook` | 卸载扩展前先执行 |

## 设置

设置里搜 `codebuddyHelper`：

| 配置项 | 默认 | 说明 |
| --- | --- | --- |
| `pollInterval` | 3 秒 | 日志扫描间隔 |
| `retryCooldown` | 30 秒 | 两次重试之间的最小间隔 |
| `retryDelay` | 5 秒 | 检测到错误后等多久开始重试（429 走指数退避，封顶 60 秒） |
| `notifyOnComplete` | 开 | 任务完成时弹通知 |
| `notifyWhenFocused` | 开 | 任务所在的那个窗口正被看着时也弹通知；关掉则只在别的窗口时提醒 |
| `notifyOn429` | 开 | 限流 / 服务端错误 / 内容审核拦截 / 后端服务响应状态码异常时通知并自动重试 |
| `soundDone` | 空 | 任务完成时的提示音：音频文件绝对路径；留空则用音效目录里的 `done.*` 或系统默认音（一般不用手填，用命令挑） |
| `soundConfirm` | 空 | 待确认 / 任务中断时的提示音；留空则用音效目录里的 `confirm.*` 或系统默认音 |

## 自定义通知音效

### 在插件里挑（推荐）

命令面板 → `CodeBuddy Helper: 选择提示音`。

列出来的候选包括 **Windows 自带的全部系统音效**（`C:\Windows\Media\`）和**音效目录里你放进去的文件**，
选中后再选用在「任务完成」「待确认 / 任务中断」还是「两个都用它」，直接写进设置，**立即生效、不用重启**。

对应两个设置，想手填绝对路径也可以：`soundDone`（完成）、`soundConfirm`（待确认 / 中断）。

### 或者直接放文件

目录：`%USERPROFILE%\.codebuddy-helper\sounds`
（命令面板 → `CodeBuddy Helper: 打开通知音效目录`）

- `done.*` 完成时播放，`confirm.*` 待确认与中断时播放，`default.*` 作为通用兜底
- 支持 `.wav .mp3 .m4a .wma .aac .flac .ogg`，**`.wav` 播放最稳**
- 目录里只有唯一一个音频文件时，直接用它，不用改名
- 放进去就生效，不用重启 VS Code

### 挑选顺序

**设置里指定的文件 → 音效目录里同用途的 `done.*` / `confirm.*` → 目录里唯一的一个文件 → `default.*` → Windows 默认通知音**。

一个音频都没有就用 Windows 默认通知音；设置里填的路径失效（文件被删或移走）时会静默回退到后面的档，
不会因为一个失效路径就不响。

## 常见问题

先看日志：命令面板 → `CodeBuddy Helper: 显示运行日志`。

| 症状 | 多半是 | 怎么办 |
| --- | --- | --- |
| 完全不弹通知 | hook 没写进配置，或 CodeBuddy 没装 | 命令面板 → `CodeBuddy Helper: 修复通知配置` |
| 弹了，但来源显示"未知程序" | 通知来源没注册 | 重启 VS Code，插件激活时会自动补注册 |
| 有通知没声音 | 音效格式不支持 | 换成 `.wav` |
| 通知来得很晚（十几秒以上） | 走的是 CodeBuddy 自带的日志通知，不是本插件的 hook | 检查 `settings.json` 里的 `Stop` hook 是否指向 `cb-hook.ps1` |
| 人正看着 VS Code 时完全不弹 | 1.2.5 之前「前台静默」会把它吃掉 | 升级到 1.2.5 以上；想恢复"只在别的窗口提醒"就把 `notifyWhenFocused` 关掉 |
| 开着静默开关也收不到 | Windows「专注助手 / 勿扰」把横幅收进了通知中心 | 1.2.8 起任务栏按钮会闪一下兜底；想看到横幅就关掉专注助手。本插件的 hook 与 agent 结束是同一秒触发，不存在插件侧延迟 |
| 弹了「处理过程出现异常，请重试」 | 撞上了内容审核拦截，CodeBuddy 自己只内部重试 1 次就放弃 | 本插件会自动续跑，最多 10 次；状态栏显示「内容审核拦截 第 N 次」 |
| 弹了「服务出现异常，请重试」（错误码 500） | 后端服务响应状态码异常，日志里整行没有 HTTP 字样 | 本插件会从相邻日志行取状态码自动续跑，最多 10 次；状态栏显示「HTTP 500 第 N 次」 |
| 弹了「任务中断，未正常完成」 | 任务撞上服务端错误收尾了，本插件会自动补重试 | 这是对的，别当成跑完了；等重试跑通后会再弹一条「任务执行完成」 |
| 429 没有自动重试 | `notifyOn429` 被关了，或已达 10 次上限 | 状态栏会显示重试进度，日志里也有 `HTTP 429 ... 已挂起` |
| 某个项目 429 后没自动重试 | 那个项目不在任何 VS Code 窗口里打开着（重试必须发回它自己的会话，所以只由持有它的窗口负责） | 打开该项目 |
| 点了通知不跳转 | 那条通知没带项目地址（1.2.0 的扩展通知路径有这个问题） | 升级到 1.2.1 以上，然后**重载窗口** |
| 装完没反应 | 只 Reload Window 了 | 要完全退出 VS Code 进程再启动 |

hook 自己的日志：`%TEMP%\cbh-hook.log`

## 卸载

```
uninstall.bat
```

会**先清掉 `settings.json` 里的 hook，再卸扩展**。顺序反过来会在配置里留一条指向已删脚本的 hook，CodeBuddy 之后每次 Stop 都会去跑一个不存在的文件。

## 参与开发

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

## 许可

[MIT](LICENSE)

## 说明

本项目的做法是读取 CodeBuddy 的日志、注册 hook 来补齐通知体验，属于第三方配套工具，
与 CodeBuddy 官方无关。使用前请自行确认这符合你所使用版本的服务条款。