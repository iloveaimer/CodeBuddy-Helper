# 更新日志

本项目的重要变更都记在这里。

格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [1.2.0] - 2026-09-17

第一个公开版本。这一版的核心是把"只有作者本机能跑"变成"谁装都能用"。

### 新增

- **零延迟完成通知。** 改用 CodeBuddy 的 `Stop` hook，任务结束的瞬间就弹通知。
  早期版本靠轮询日志判断任务是否完成，而日志缓冲导致的写入滞后实测有 15 秒到数分钟，
  这是"通知来得晚"的唯一根源，靠优化扫描频率解决不了，只能绕开。
- **区分「任务完成」与「等待用户确认」。** agent 停在等用户批准命令时 `Stop` hook 同样会触发，
  只看 hook 会误报"任务完成"。现在会回读日志里的权限决策记录来判断，两种情况给不同文案。
- **限流与服务端错误自动重试。** 识别 `429` / `500` / `502` / `503` / `504` 与令牌过期，
  按 `conversationId` 把"请继续执行未完成的任务"发回**出错的那次会话**，而不是当前会话。
  `429` 走指数退避，且全局串行——它是账号级限流，多个项目并发重试只会继续撞墙。
- **自定义通知音效。** `done.*` / `confirm.*` / `default.*` 三种用途，支持
  wav / mp3 / m4a / wma / aac / flac / ogg，`.wav` 播放最稳。
- **点击通知跳回对应项目。**
- **通知来源与 hook 配置全自动注册。** 插件首次激活时自己写好 `AppUserModelId` 和
  `~/.codebuddy/settings.json` 里的 hook。写入前先备份 `.bak`，而且**只做合并**：
  原有的插件开关和其它 hook 一律不动。
- **`install.ps1` / `uninstall.ps1`。** 自动定位 VS Code 命令行工具，并且**优先选择真正装了
  CodeBuddy 的那个变体**——同时装了正式版和 Insiders 时，装到 CodeBuddy 不在的那个等于没装。
  卸载时**先清 hook 再卸扩展**。
- **`verify.ps1`。** 发布前自检，把下面这些坑固化成了自动检查。

### 修复

- **VSIX 里从来没有 hook 脚本。** 打包脚本只复制了 `extension.js` 和 `package.json`，
  `cb-hook.ps1` / `cb-sound.ps1` 从未进过包。此前能用纯粹是因为 hook 恰好指向了开发目录——
  装好的扩展里没有脚本，而 hook 指向开发目录里的脚本，两个残缺互相补上了。
  换台机器安装，通知会完全失效。
- **重试的成功判定不可靠。** `chat.sendMessage` 在目标会话不存在时**不抛异常**、
  只返回 `{ error }`，原先只看有没有抛错，会把失败记成成功。
- **hook 指向的脚本失效后无法被发现。** 原先只比对命令里有没有 `cb-hook.ps1` 这个文件名，
  脚本被移走或删掉后路径成了死链、但文件名还在，自检就认为一切正常，而通知完全不响。
  现在会取出实际路径判断文件是否存在。
- **打包与安装的桌面路径不一致。** 打包用 `[Environment]::GetFolderPath("Desktop")`，
  安装读 `%USERPROFILE%\Desktop`。桌面被 OneDrive 重定向的机器上两者不同，安装会找不到文件。
  现在统一产出到项目内的 `dist/`。
- **`code` 不在 PATH 时安装脚本直接失败。** 全新机器上这是常态（安装 VS Code 时没勾
  "添加到 PATH"）。现在会依次查找 PATH、`%LOCALAPPDATA%`、`%ProgramFiles%`、
  `%ProgramFiles(x86)%` 下的正式版与 Insiders。
- **扩展写配置时可能遮蔽用户设置。** `checkHook()` 内部有个 `const cfg` 遮蔽了模块级的
  用户配置对象，是一处埋着的雷，已改名消除。
- **日志读取的字节边界问题。** 增量读取日志时按字符算偏移，会在多字节字符被切断时错位，
  改为按字节找换行，只消费到最后一个完整行。
- **"待确认"通知的重复提醒。** hook 日志只记 `HH:mm:ss` 不带日期，不筛时间窗的话，
  几天前的一条"等待用户确认"会让扩展以为自己不必提醒，用户就干等一个永远不会来的通知。
- **重试次数越界后仍在自增**，状态栏会冒出"重试 20/10"这种数字。
- **重试冷却期间误置标记**，导致那条错误此后永远进不了队列。

### 说明

- `.ps1` 必须带 UTF-8 BOM。没有 BOM 时 PowerShell 5.1 按系统 ANSI 码页解码文件，
  UTF-8 中文变乱码；严重时 CJK 标点被拆开的字节会**吞掉紧跟其后的 ASCII 引号**，
  字符串永不闭合，整个脚本语法报错。`.editorconfig` 和 `verify.ps1` 都会守住这一条。
- `.bat` 必须纯 ASCII，且不能有 BOM——cmd 按 OEM 码页读 `.bat`，BOM 会被当成命令的一部分。

## [1.1.0] - 2026-09-17

内部里程碑：改用 CodeBuddy 原生 hook 替代日志轮询，实现及时通知。

## [1.0.0] - 2026-08-18

内部里程碑：跑通 VS Code 扩展 + Windows Toast 通知的基本链路。

[1.2.0]: https://github.com/iloveaimer/CodeBuddy-Helper/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/iloveaimer/CodeBuddy-Helper/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/iloveaimer/CodeBuddy-Helper/releases/tag/v1.0.0