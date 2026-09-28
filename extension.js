const vscode = require("vscode");
const fs = require("fs");
const path = require("path");
const os = require("os");
const cp = require("child_process");

// 目录一律取环境变量，不拼 os.homedir()：企业漫游或重定向过的机器上，
// %LOCALAPPDATA% / %APPDATA% 未必落在 home 下面，拼出来的路径会指到空的目录
const LOCAL_APP = process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
const ROAM_APP = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
const LOG = path.join(LOCAL_APP, "CodeBuddyExtension", "Logs", "VSCode");
const CB_SETTINGS = path.join(os.homedir(), ".codebuddy", "settings.json");
// CodeBuddy 的对话命令。自动重试和可用性自检都用它，只此一处定义
const CB_CMD = "tencentcloud.codingcopilot.chat.sendMessage";
const HOOK_SCRIPT = path.join(__dirname, "cb-hook.ps1");
const HOOK_LOG = path.join(os.tmpdir(), "cbh-hook.log");
const S = {};          // 文件 → 已读到的字节位置（始终落在完整行的末尾）
const E = {};          // 项目 → { code, count, next, warned }
const W = {};          // 项目 → { ts, cmd, notified, reminded }  危险命令等待确认
const R = {};          // 项目 → { ts, logTs, code, cid, retried }  待处理的服务端错误
const MAX = 10;
const CONFIRM_WAIT = 20000;    // 等待超过 20 秒 → 第一次提醒（agent 此时不 Stop，hook 覆盖不到）
// 三条提醒路径（hook 的 Notification、hook 的 Stop、下面这条兜底）各自只响一次，
// 用户漏看就再也不会响，而 CodeBuddy 没有确认超时、任务会一直挂着。等满这么久再补一次。
// 两个阈值都从等待开始那一刻算起，不是从第一次提醒算起
const CONFIRM_REMIND = 180000;
const RETRY_GRACE = 20000;    // 错误出现后等这么久再重试，给"已自行恢复"的日志写入时间
const RETRY_WINDOW = 1800000; // 只处理 30 分钟内的错误，更早的视为历史遗留
const HOOK_WAIT_WINDOW = 180000; // hook 发过的"待确认"通知保质期，与 cb-hook.ps1 判卡住用的 3 分钟新鲜度对齐
const CFG_FILE = path.join(os.tmpdir(), "cbh-config.json");  // 导给 hook 读的配置
// Windows Toast 的来源标识：注册表项给显示名，开始菜单里的同名 .lnk 让壳层认得这个 AppId
const AUMID = "CBH";
const AUMID_LNK = path.join(ROAM_APP, "Microsoft", "Windows", "Start Menu", "Programs", `${AUMID}.lnk`);
// 项目名要当文件名用，清洗规则必须和 cb-hook.ps1 的 Get-SafeName 完全一致，
// 否则扩展按 cbh-path-<项目名>.txt 取不到 hook 写下的项目路径
const SAFE_RE = /[\\/:*?"<>|]/g;
const safeName = (n) => String(n).replace(SAFE_RE, "_");

// 跨实例通知去重。每个 VS Code 窗口一个扩展宿主，都会看到同一批日志和同一条 hook 状态，
// 于是同一条消息会被每个窗口各弹一次 —— 而 Toast 是全局的，用户看到的是重复通知。
// 放在 %TEMP% 让所有实例共用。竞态下最坏结果是多弹一次，可以接受。
const DEDUP_FILE = path.join(os.tmpdir(), "cbh-notify-dedup.json");
const DEDUP_MS = 10000;
function dupNotify(msg) {
    try {
        let m = {};
        try { m = JSON.parse(fs.readFileSync(DEDUP_FILE, "utf-8")); } catch (_) {}
        const now = Date.now();
        const hit = !!(m[msg] && now - m[msg] < DEDUP_MS);
        const next = {};   // 顺手淘汰过期键，否则文件会一直长
        for (const [k, t] of Object.entries(m)) if (now - t < DEDUP_MS) next[k] = t;
        if (!hit) next[msg] = now;
        fs.writeFileSync(DEDUP_FILE, JSON.stringify(next), "utf-8");
        return hit;
    } catch (_) { return false; }
}

// 用户配置（VS Code 设置 → CodeBuddy Helper）。改设置即时生效，见 activate 里的 onDidChangeConfiguration
let cfg = { pollInterval: 3000, retryCooldown: 30000, retryDelay: 5, notifyOnComplete: true, notifyOn429: true };

// 全局重试队列：429 是账号级限流，多个项目同时重试只会继续撞墙，串行处理
const queue = [];
let busy = false;

// 焦点上报文件：本窗口是否在前台、开着哪些项目，hook 读它决定要不要弹通知。
const FOCUS_FILE = path.join(os.tmpdir(), `cbh-focus-${process.pid}.txt`);
// 最近一次重试结果，用于状态栏展示
let lastRetry = null;

const O = vscode.window.createOutputChannel("CodeBuddy Helper");
const l = (s) => O.appendLine(`[${new Date().toLocaleTimeString()}] ${s}`);

// hook 跑在独立进程里读不到 VS Code 设置，所以把配置导出成文件给它
function refreshCfg() {
    const c = vscode.workspace.getConfiguration("codebuddyHelper");
    cfg = {
        pollInterval: Math.max(1, c.get("pollInterval", 3)) * 1000,
        retryCooldown: Math.max(5, c.get("retryCooldown", 30)) * 1000,
        retryDelay: Math.max(1, c.get("retryDelay", 5)),
        notifyOnComplete: c.get("notifyOnComplete", true) !== false,
        notifyOn429: c.get("notifyOn429", true) !== false
    };
    try {
        // aumid 一并导给 hook：Toast 的来源标识只在这里定义一处，
        // hook 侧不另写一份（改漏一处通知就静默变成"未知程序"）
        fs.writeFileSync(CFG_FILE, JSON.stringify({ notifyOnComplete: cfg.notifyOnComplete, aumid: AUMID }), "utf-8");
    } catch (_) {}
    l(`cfg: poll=${cfg.pollInterval}ms cooldown=${cfg.retryCooldown}ms delay=${cfg.retryDelay}s complete=${cfg.notifyOnComplete} 429=${cfg.notifyOn429}`);
}

// 项目名 → 可点击的项目 URL。
// 扩展是按日志文件名认项目的，文件名里只有项目名、没有全路径，所以路径只能问 hook：
// 它每次跑都会把 cwd 写进 %TEMP%\cbh-path-<项目名>.txt。
// 下面那段「当前窗口工作区目录」只是兜底：单目录工作区够用，多根工作区就可能指错，
// 所以优先用 hook 落盘的路径。
function projectUrl(proj) {
    let p = null;
    try {
        const f = path.join(os.tmpdir(), `cbh-path-${safeName(proj)}.txt`);
        if (fs.existsSync(f)) p = fs.readFileSync(f, "utf-8").trim();
    } catch (_) {}
    // 退回当前窗口的工作区目录，但只认项目名相同的，免得把通知指向另一个项目
    if (!p) {
        const ws = (vscode.workspace.workspaceFolders || [])[0];
        if (ws && path.basename(ws.uri.fsPath).toLowerCase() === String(proj).toLowerCase()) p = ws.uri.fsPath;
    }
    if (!p) return "";
    // 两个坑：文件夹 URL 必须带结尾 /，官方格式是 vscode://file/{full path to project}/，
    // 少了会被当成文件打开；路径还必须 percent-encode，含 # 会被当片段截断、含 % 会被当转义。
    // encodeURIComponent 连分隔符和盘符冒号一起编码，再把这两个还原回来。
    const e = encodeURIComponent(p.replace(/\\/g, "/")).replace(/%2F/gi, "/").replace(/%3A/gi, ":");
    return "vscode://file/" + e + "/";
}

// 通知：仅 Windows Toast，不做 VS Code 弹窗（避免每次完成任务都弹窗打扰）
// 传了 proj 就把项目路径写进 launch，点通知能切到那个项目；
// 不带 launch 的 Toast 被点击时是没有任何反应的。
function notify(msg, proj) {
    l(msg);
    if (dupNotify(msg)) { l(`dup-skip(其它窗口已弹):${msg}`); return; }
    try {
        // 文件名带 pid：同一毫秒里的两条通知不能被写进同一个文件，否则内容互相覆盖
        const f = path.join(os.tmpdir(), `t_${process.pid}_${Date.now()}.ps1`);
        const xml = msg.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
        const url = proj ? projectUrl(proj) : "";
        const attr = url ? ` activationType="protocol" launch="${url}"` : "";
        fs.writeFileSync(f, "\ufeff" + `[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null
[Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom,ContentType=WindowsRuntime]|Out-Null
$x=New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml('<toast${attr}><visual><binding template="ToastGeneric"><text>${xml}</text></binding></visual></toast>')
$n=[Windows.UI.Notifications.ToastNotification]::new($x)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('${AUMID}').Show($n)
`, "utf-8");
        cp.exec(`powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "${f}"`, () => {
            setTimeout(() => { try { fs.unlinkSync(f); } catch (_) {} }, 5000);
        });
    } catch (_) {}
}

// 注册通知来源。不注册的话 Toast 会显示成"未知程序"、图标空白 ——
// hook 自己发通知时没有注册能力，这一步只能由扩展补上。
function ensureAumid() {
    const regKey = `HKCU\\Software\\Classes\\AppUserModelId\\${AUMID}`;
    let regOk = false;
    try {
        // 先用 reg.exe 探一下（约 15ms）：为了检查而拉一个 PowerShell 要 215ms，不划算
        cp.execFileSync("reg", ["query", regKey, "/v", "DisplayName"], { stdio: "ignore", timeout: 5000 });
        regOk = true;
    } catch (_) {}
    if (regOk && fs.existsSync(AUMID_LNK)) return;

    try {
        const f = path.join(os.tmpdir(), `cbh-aumid-${process.pid}.ps1`);
        // 建快捷方式只能走 WScript.Shell COM，所以这一段必须借 PowerShell；只在缺失时跑一次
        fs.writeFileSync(f, "\ufeff" + `$rk='HKCU:\\Software\\Classes\\AppUserModelId\\${AUMID}'
if (-not (Test-Path $rk)) { New-Item $rk -Force | Out-Null }
Set-ItemProperty $rk -Name DisplayName -Value '${AUMID}' -Force
$lk='${AUMID_LNK}'
if (-not (Test-Path $lk)) {
  $ws = New-Object -ComObject WScript.Shell
  $sc = $ws.CreateShortcut($lk)
  $sc.TargetPath = 'powershell.exe'
  $sc.Save()
}
`, "utf-8");
        cp.exec(`powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "${f}"`, (e) => {
            setTimeout(() => { try { fs.unlinkSync(f); } catch (_) {} }, 3000);
            l(e ? `aumid 注册失败: ${e.message}` : "aumid 已注册");
        });
    } catch (e) { l("aumid 注册异常: " + e.message); }
}

// 本窗口打开的项目名（小写）。日志文件名是 <项目名>__<32位hex>.log，里面只有项目名、
// 没有全路径，所以只能按目录名比对。
function localProjects() {
    return (vscode.workspace.workspaceFolders || []).map((f) => path.basename(f.uri.fsPath).toLowerCase());
}

function today() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

// 自检：CodeBuddy 的 hook 是否还完好。
// 完成通知依赖 Stop hook，任务耗时依赖 UserPromptSubmit hook。
// 一旦配置丢失/脚本被删，这些能力会静默失效——必须主动发现。
function checkHook() {
    const probs = [];
    const need = { Stop: "完成通知", UserPromptSubmit: "任务耗时" };
    try {
        if (!fs.existsSync(CB_SETTINGS)) probs.push("settings.json 不存在");
        else {
            const sc = JSON.parse(fs.readFileSync(CB_SETTINGS, "utf-8"));
            for (const [ev, purpose] of Object.entries(need)) {
                const arr = sc.hooks && sc.hooks[ev];
                if (!Array.isArray(arr) || arr.length === 0) { probs.push(`${ev} hook 未配置（${purpose}）`); continue; }
                const cmds = arr.flatMap((g) => (g.hooks || []).map((h) => h.command || ""));
                const hit = cmds.find((c) => c.includes("cb-hook.ps1"));
                if (!hit) { probs.push(`${ev} hook 未指向 cb-hook.ps1（${purpose}）`); continue; }
                // 只比对文件名不够：脚本被移走或删掉后路径就成了死链，但文件名还在，
                // 自检会认为一切正常，而通知其实完全不响（也不会被自动修复）
                const m = hit.match(/-File\s+"?([^"]+\.ps1)"?/);
                if (!m || !fs.existsSync(m[1])) probs.push(`${ev} hook 指向的脚本不存在（${purpose}）: ${m ? m[1] : hit}`);
            }
        }
    } catch (e) { probs.push("配置解析失败: " + e.message); }
    if (!fs.existsSync(HOOK_SCRIPT)) probs.push("cb-hook.ps1 文件不存在");
    return probs;
}

// 把 hook 写进 CodeBuddy 的 settings.json。
// 只有扩展自己知道安装目录在哪，所以这份配置必须由扩展写，写在安装脚本里必然指向错的地方。
// 严格做"合并"：settings.json 里还有插件开关和用户自己的其它 hook，整体覆盖会全丢掉。
function installHooks() {
    const want = `powershell -NoProfile -ExecutionPolicy Bypass -File "${HOOK_SCRIPT}"`;
    const events = ["Stop", "UserPromptSubmit"];   // 完成通知 / 任务耗时
    let sc;
    try {
        sc = fs.existsSync(CB_SETTINGS) ? JSON.parse(fs.readFileSync(CB_SETTINGS, "utf-8")) : {};
    } catch (e) { return `配置解析失败: ${e.message}`; }
    if (!sc.hooks || typeof sc.hooks !== "object") sc.hooks = {};

    const changed = [];
    for (const ev of events) {
        const arr = Array.isArray(sc.hooks[ev]) ? sc.hooks[ev] : [];
        let hit = false;
        for (const g of arr) for (const h of g.hooks || []) {
            const m = (h.command || "").match(/-File\s+"?([^"]+\.ps1)"?/);
            if (!m || !m[1].toLowerCase().endsWith("cb-hook.ps1")) continue;
            hit = true;
            // 只在它指向的脚本已经不存在时才改写：否则会在开发目录和安装目录之间来回横跳
            if (!fs.existsSync(m[1])) { h.command = want; changed.push(`${ev}(路径失效)`); }
        }
        if (!hit) {
            arr.push({ hooks: [{ type: "command", command: want, timeout: 10 }] });
            changed.push(ev);
        }
        sc.hooks[ev] = arr;
    }
    if (!changed.length) return null;

    try { fs.copyFileSync(CB_SETTINGS, CB_SETTINGS + ".bak"); } catch (_) {}   // 先备份，写坏了还有得救
    try {
        fs.mkdirSync(path.dirname(CB_SETTINGS), { recursive: true });
        fs.writeFileSync(CB_SETTINGS, JSON.stringify(sc, null, 2), "utf-8");
    } catch (e) { return `写入失败: ${e.message}`; }
    return changed.join(", ");
}

// 摘掉本扩展写入的 hook。卸载前用，否则 CodeBuddy 每次 Stop 都会去跑一个已经删掉的脚本
function removeHooks() {
    let sc;
    try {
        sc = JSON.parse(fs.readFileSync(CB_SETTINGS, "utf-8"));
    } catch (e) { return `配置解析失败: ${e.message}`; }
    if (!sc.hooks) return null;

    const gone = [];
    for (const ev of Object.keys(sc.hooks)) {
        const arr = sc.hooks[ev];
        if (!Array.isArray(arr)) continue;
        let dropped = false;
        const kept = [];
        for (const g of arr) {
            const hs = [];
            for (const h of g.hooks || []) {
                if ((h.command || "").includes("cb-hook.ps1")) dropped = true;
                else hs.push(h);
            }
            if (hs.length) kept.push({ ...g, hooks: hs });
            else if ((g.hooks || []).length) dropped = true;   // 整组都是我们的 hook → 整组去掉
        }
        if (!dropped) continue;
        if (kept.length) sc.hooks[ev] = kept;
        else delete sc.hooks[ev];
        gone.push(ev);
    }
    if (!gone.length) return null;
    try { fs.writeFileSync(CB_SETTINGS, JSON.stringify(sc, null, 2), "utf-8"); }
    catch (e) { return `写入失败: ${e.message}`; }
    return gone.join(", ");
}

// 自检，能修就修。返回 { probs, fixed }：probs 是修完仍存在的问题，fixed 是这次补了什么（null 表示没动过配置）
function ensureHook() {
    let probs = checkHook();
    if (!probs.length) return { probs, fixed: null };
    l(`hook 自检失败: ${probs.join("; ")}`);
    const fixed = installHooks();
    if (!fixed) return { probs, fixed: null };
    l(`hook 自动修复: ${fixed}`);
    return { probs: checkHook(), fixed };
}

// hook 是否刚就"待确认"发过通知（避免与扩展的检测重复提醒）。
// 必须带时间窗：hook 日志只记 HH:mm:ss，不筛时间的话几天前的一条"等待用户确认"
// 会让扩展以为自己不必提醒，用户就干等一个永远不会来的通知。
function hookSaidWaiting(proj) {
    try {
        const lines = fs.readFileSync(HOOK_LOG, "utf-8").split(/\r?\n/).filter(Boolean).slice(-15);
        const now = Date.now();
        return lines.some((line) => {
            if (!line.includes("等待用户确认") || !line.includes(`Stop: ${proj} |`)) return false;
            const m = line.match(/^(\d{2}):(\d{2}):(\d{2})/);
            if (!m) return false;
            const t = new Date();
            t.setHours(+m[1], +m[2], +m[3], 0);
            let diff = now - t.getTime();
            if (diff < -43200000) diff += 86400000;   // 日志写于昨天：HH:mm:ss 比当前时间还晚
            return diff >= 0 && diff <= HOOK_WAIT_WINDOW;
        });
    } catch (_) { return false; }
}

// 追踪"危险命令待用户确认"。
// 这种场景 agent 在等工具结果，不会 Stop，所以 hook 覆盖不到，只能由扩展兜底。
// 按行顺序处理，保证 "Dangerous command detected" → "状态变更: pending ->" 的先后关系有效。
function trackConfirm(p, c) {
    for (const line of c.split("\n")) {
        if (!line.startsWith("[")) continue;   // 跳过写进日志的源码文本行
        if (line.includes("Dangerous command detected")) {
            W[p] = {
                ts: Date.now(),
                cmd: (line.match(/Dangerous command detected:\s*(.{0,60})/) || [])[1] || "",
                notified: false,
                reminded: false
            };
        } else if (/状态变更: pending ->|confirmed:|execution_started|全量执行完成|Permission response: approved=/.test(line)) {
            if (W[p]) W[p] = null;   // 已响应即清除，避免状态残留
        }
    }
}

// 服务端错误追踪：429 / 5xx / 审核拦截 / 「后端服务响应状态码异常」。
// 关键点：不能只认"最近 2 分钟内的"，因为 CodeBuddy 日志实际会滞后 69~206 秒，
// 用时间窗口会把绝大多数错误直接过滤掉、永远不重试。
// 改成状态机：出现错误就挂起，等日志里出现新的 agent 活动（说明已自行恢复）就撤销。
function trackApiError(p, c) {
    const lines = c.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (!line.startsWith("[")) continue;

        // agent 又动起来了 → 说明任务已恢复（用户手动重试/服务端自愈），撤销待重试
        if (/notifyAgentStart|notifyStepStart/.test(line)) {
            if (R[p]) { l(`api resolved:${p} ${R[p].code}`); R[p] = null; }
            continue;
        }

        const head = line.match(/^\[(\d{4}\/\d+\/\d+ \d+:\d+:\d+)\.\d+\]\s*\[(?:Error|Info)\]/);
        if (!head) continue;

        // 三类服务端失败都值得自动续上：
        //   ① HTTP 状态码错误 —— 502/503/504 是网关临时故障，性质和 429/500 一样，都要退避重试
        //   ② 内容审核拦截 —— 整行没有 HTTP 字样，只有 InternalError.Algo.DataInspectionFailed。
        //      CodeBuddy 自己只会内部重试 1 次（日志里 maxRetries: 1），失败就直接弹
        //      「处理过程出现异常」干等用户点，剩下的重试只能由这里补。
        //      它不带 X-Conversation-ID，也不必硬凑：弹框就出现在任务所在的那个窗口，
        //      sendMessage 默认发进当前会话，正是出错的那一个。
        //   ③ 「后端服务响应状态码异常」—— 界面上是「服务出现异常，请重试」弹框（错误码 500 那种）。
        //      同样整行没有 HTTP 字样，状态码写在相邻几行里：ContextCompactRetry 的
        //      statusCode: 500、AgentSessionManager 的 errorCode=500、响应体里的 "code":500。
        //      所以取码要连本行往后的几行一起看，一条都没取到才退回 srv（服务端异常）——
        //      这本来就是服务端故障，宁可多试，也不能让任务干等。只认 HTTP 的话它一次都不会重试。
        const httpM = line.match(/HTTP (429|500|502|503|504|401)/);
        const codeM = httpM ? null : line.match(/\b(?:statusCode|errorCode|code)["']?\s*[:=]\s*"?(429|5\d\d)\b/);
        const bizFail = /后端服务响应状态码异常/.test(line);
        if (!httpM && !codeM && !bizFail && !/InternalError\.Algo\.DataInspectionFailed/.test(line)) continue;

        const block = line + "\n" + lines.slice(i, i + 5).join("\n");
        const codeHit = httpM || codeM || block.match(/\b(?:statusCode|errorCode|code)["']?\s*[:=]\s*"?(429|5\d\d)\b/);
        const code = codeHit ? codeHit[1] : (bizFail ? "srv" : "inspect");
        // 真实日志格式: X-Conversation-ID: 33c46762bc3b4cbd88cbe73166577849
        // \W{0,8} 兼容带引号/多空格/换行的变体（实测 55/55 命中）
        // 「后端服务响应状态码异常」不带 X-Conversation-ID，但相邻行写了 conversationId=xxx
        //（AgentSessionManager）或 "conversationId":"xxx"（ResultHandler.handleError），
        // 同是出错的那次会话，比"发进当前会话"更准。注意 X-Conversation-ID 里隔着横线，不会被误取
        const cid = (block.match(/[Xx]-[Cc]onversation-[Ii][Dd]\W{0,8}([a-f0-9]{32})/) || [])[1]
            || (block.match(/[Cc]onversation[Ii]d\W{0,8}([a-f0-9]{32})/) || [])[1] || "";
        const logTs = new Date(head[1].replace(/\//g, "-")).getTime();

        // 令牌过期重试也没用，只提醒。安全相关，不受 notifyOn429 开关影响
        if (code === "401") { notify(`【${p}】令牌过期，请重新登录`, p); continue; }

        if (!cfg.notifyOn429) { l(`${code}:${p} 已忽略（notifyOn429 关闭）`); continue; }

        R[p] = { ts: Date.now(), logTs, code, cid, retried: false };
        l(`${code}:${p} cid=${cid || "?"} 已挂起，待确认是否需重试`);
    }
}

// 读取文件增量。
// 只消费到最后一个换行符，剩下的半行留到下一轮 —— 边界落在日志行中间时，
// 行首锚定的正则（notifyAllStepsEnd）会两半都匹配不上，重试计数就永远归不了零。
// S[fp] 因此始终落在完整行末尾，下一轮从那里续读，不会重复处理同一行。
function readDelta(fp) {
    const sz = fs.statSync(fp).size;
    let pv = S[fp] || 0;
    if (sz < pv) pv = 0;        // 日志轮转/被截断 → 从头读，否则这个文件此后永远读不到
    if (sz <= pv) return null;
    const ln = sz - pv;
    const buf = Buffer.alloc(ln);
    const fd = fs.openSync(fp, "r");
    fs.readSync(fd, buf, 0, ln, pv);
    fs.closeSync(fd);
    const br = buf.lastIndexOf(0x0a);   // 按字节找换行：多字节字符被切断时按字符算偏移会错
    if (br < 0) return null;            // 还没有一个完整行，等下一轮
    S[fp] = pv + br + 1;
    return buf.slice(0, br + 1).toString("utf-8");
}

// 扫描单个日志文件
function scanFile(fp) {
    const c = readDelta(fp);
    if (!c) return;
    const p = path.basename(fp).split("__")[0] || "?";

    // 任务完成 → 只重置重试计数。完成通知由 CodeBuddy Stop hook 零延迟发送，
    // 扩展不再做日志扫描通知（日志写入延迟 15s~423s，是延迟通知的根源）
    if (/^\[[^\]]+\]\s*\[Info\]\s*\[BaseAgent:craft\]\s*\[[a-f0-9]{32,}\]\s*notifyAllStepsEnd/im.test(c)) {
        if (E[p]) E[p] = { code: null, count: 0, next: 0 };
    }

    // 危险命令待确认追踪（hook 覆盖不到，由扩展兜底）
    trackConfirm(p, c);

    // 服务端错误追踪 —— 状态机，见 trackApiError 注释
    trackApiError(p, c);
}

// 错误码给用户看时的措辞：审核拦截与"一条码都取不到的服务端异常"没有具体 HTTP 码，
// 不能一律写成"HTTP xxx"，内部的 inspect / srv 代号也不外露
const errLabel = (code) =>
    code === "inspect" ? "内容审核拦截" : code === "srv" ? "服务端异常" : `HTTP ${code}`;

// 入队重试（全局串行）
function enqueue(p, code, cid) {
    if (!E[p]) E[p] = { code: null, count: 0, next: 0, warned: false };
    const s = E[p];
    if (s.code !== code) { s.code = code; s.count = 0; s.warned = false; }
    // count 是已完成的重试次数，封顶在 MAX：越界后不再自增，
    // 否则持续限流时状态栏会冒出"重试 20/10"这种数字
    if (s.count >= MAX) {
        // 只在刚越界时喊一次：持续限流期间每来一条新错误都弹同一句话纯属轰炸
        if (!s.warned) { s.warned = true; notify(`【${p}】${errLabel(code)} 已达 ${MAX} 次上限，请手动处理`, p); }
        return;
    }
    s.count++;
    const base = code === "429" ? Math.min(cfg.retryDelay * Math.pow(2, s.count - 1), 60) : cfg.retryDelay;
    const delay = Math.round(base * (0.8 + Math.random() * 0.4) * 1000);
    s.next = Date.now() + delay + cfg.retryCooldown;
    queue.push({ p, code, cid, delay, count: s.count });
    notify(`【${p}】${errLabel(code)} 第${s.count}/${MAX}次重试`, p);
    drain();
}

// CodeBuddy 是否可用。它没装或没启用时 hook 和自动重试都无从谈起，
// 这种"静默失效"必须能被指出来，否则用户只会觉得插件坏了
async function hasCbCmd() {
    try { return (await vscode.commands.getCommands(true)).includes(CB_CMD); }
    catch (_) { return true; }   // 自检本身出错时按可用算，不能反过来误报"CodeBuddy 未安装"
}

// 串行执行队列
async function drain() {
    if (busy) return;
    busy = true;
    while (queue.length) {
        const job = queue.shift();
        await new Promise((r) => setTimeout(r, job.delay));
        try {
            // 带上 conversationId，让消息回到出错的那次会话；不带就发到当前会话
            const opts = job.cid ? { conversationId: job.cid } : {};
            const res = await vscode.commands.executeCommand(CB_CMD, {
                message: "请继续执行未完成的任务。",
                options: opts
            });
            // 目标会话不存在时这条命令不抛异常，只返回 { error }，不看返回值会把失败记成成功
            if (res && res.error) throw new Error(String(res.error));
            l(`retry ok:${job.p} cid=${job.cid || "current"}`);
            lastRetry = { proj: job.p, code: job.code, ok: true, ts: Date.now() };
        } catch (e) {
            const hint = (await hasCbCmd()) ? "" : "（未检测到 CodeBuddy 扩展）";
            l(`retry fail:${job.p} ${e.message}${hint}`);
            lastRetry = { proj: job.p, code: job.code, ok: false, ts: Date.now() };
        }
        // 项目之间留间隔，避免连续请求继续触发限流
        if (queue.length) await new Promise((r) => setTimeout(r, 5000));
    }
    busy = false;
}

function activate(ctx) {
    const sb = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    sb.text = "$(bell) CBH";
    sb.tooltip = "CodeBuddy Helper\n完成通知由 CodeBuddy hook 负责\n点击查看运行日志";
    sb.command = "codebuddyHelper.showOutput";
    sb.show();
    ctx.subscriptions.push(sb);

    // 命令：打开运行日志
    ctx.subscriptions.push(
        vscode.commands.registerCommand("codebuddyHelper.showOutput", () => O.show())
    );

    // 焦点状态上报：hook 据此判断"当前任务所在的那个项目窗口是否正被看着"，是就不弹通知（避免打扰）。
    // 只报 VS Code 在不在前台不够用：多窗口并行时用户在 B 窗口干活，A 窗口的项目跑完也会被静默掉，
    // 用户就再也收不到完成通知。所以把本窗口的工作区路径一起报，hook 只静默"任务就在这个窗口"的通知。
    // 格式：<1|0>|<工作区路径>[;<路径>...]，路径统一正斜杠、不带结尾 /
    // hook 侧以 5 分钟未更新视为失效，所以除了状态变化要写，还得定期刷新 mtime
    // 不能让它抛出去：writeFocus 是在轮询回调里调的，一次异常会中断整轮轮询
    //（后面的 hook 自检、危险命令检测、429 重试、清理全跳过）
    const wsPaths = () => {
        try {
            return (vscode.workspace.workspaceFolders || [])
                .map((f) => f.uri.fsPath.replace(/\\/g, "/").replace(/\/+$/, ""))
                .join(";");
        } catch (_) { return ""; }
    };
    let lastFocus = null;
    const writeFocus = (force) => {
        const cur = `${vscode.window.state.focused ? 1 : 0}|${wsPaths()}`;
        if (!force && cur === lastFocus) return;
        lastFocus = cur;
        try { fs.writeFileSync(FOCUS_FILE, cur, "utf-8"); } catch (_) {}
    };
    writeFocus(true);
    ctx.subscriptions.push(vscode.window.onDidChangeWindowState(() => writeFocus()));
    ctx.subscriptions.push(new vscode.Disposable(() => { try { fs.unlinkSync(FOCUS_FILE); } catch (_) {} }));

    // 状态栏刷新：展示重试进度 / 最近一次重试结果
    const updateStatusBar = () => {
        const retrying = Object.entries(E).find(([, s]) => s && s.count > 0 && Date.now() < (s.next || 0));
        let text, tip;
        if (retrying || queue.length) {
            const k = retrying ? retrying[0] : (queue[0] ? queue[0].p : "?");
            const s = E[k] || { count: 0, code: "?" };
            text = `$(sync~spin) CBH 重试 ${s.count}/${MAX}`;
            tip = `${k}\n${errLabel(s.code)} · 第 ${s.count} 次\n队列 ${queue.length} 项`;
        } else if (lastRetry) {
            const sec = Math.round((Date.now() - lastRetry.ts) / 1000);
            const ago = sec < 60 ? `${sec} 秒前` : `${Math.round(sec / 60)} 分钟前`;
            text = `$(bell) CBH ${lastRetry.ok ? "$(check)" : "$(warning)"}`;
            tip = `最近重试: ${lastRetry.proj} (${errLabel(lastRetry.code)})\n${lastRetry.ok ? "成功" : "失败"} · ${ago}`;
        } else {
            text = "$(bell) CBH";
            tip = "CodeBuddy Helper\n完成通知由 CodeBuddy hook 负责\n点击查看运行日志";
        }
        if (sb.text !== text) sb.text = text;
        if (sb.tooltip !== tip) sb.tooltip = tip;
    };

    // 命令：打开自定义音效目录
    ctx.subscriptions.push(
        vscode.commands.registerCommand("codebuddyHelper.openSoundsDir", () => {
            const dir = path.join(os.homedir(), ".codebuddy-helper", "sounds");
            try { fs.mkdirSync(dir, { recursive: true }); } catch (_) {}
            vscode.env.openExternal(vscode.Uri.file(dir));
            l(`openSoundsDir: ${dir}`);
        })
    );

    // 命令：测试通知（走真实 hook 链路，含自定义音效）
    ctx.subscriptions.push(
        vscode.commands.registerCommand("codebuddyHelper.test", () => {
            const hook = path.join(__dirname, "cb-hook.ps1");
            const ws = (vscode.workspace.workspaceFolders || [])[0];
            const cwd = ws ? ws.uri.fsPath : process.cwd();
            try {
                const p = cp.spawn("powershell",
                    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", hook],
                    { stdio: ["pipe", "ignore", "ignore"] });
                p.stdin.write(JSON.stringify({ hook_event_name: "Stop", session_id: "cbh-test", cwd, stop_hook_active: false, loop_count: 1 }));
                p.stdin.end();
                l(`test notify sent: ${cwd}`);
            } catch (e) { l("test notify failed: " + e.message); }
        })
    );

    // 命令：修复通知配置。hook 丢失或指向失效时用，幂等，可以反复执行
    ctx.subscriptions.push(
        vscode.commands.registerCommand("codebuddyHelper.installHooks", () => {
            const { probs } = ensureHook();
            if (probs.length) vscode.window.showWarningMessage(`CodeBuddy Helper: hook 仍未就绪 — ${probs.join("; ")}`);
            else vscode.window.showInformationMessage("CodeBuddy Helper: 通知配置已就绪");
        })
    );

    // 命令：移除本扩展写入的 hook。卸载扩展前先执行，否则 CodeBuddy 每次 Stop 都会去跑一个不存在的脚本
    ctx.subscriptions.push(
        vscode.commands.registerCommand("codebuddyHelper.removeHooks", () => {
            const r = removeHooks();
            vscode.window.showInformationMessage(r ? `CodeBuddy Helper: 已移除 ${r} 的 hook` : "CodeBuddy Helper: 没有需要移除的 hook");
        })
    );

    refreshCfg();
    ensureAumid();
    l("activated");
    l(`date:${today()}`);

    // 没有 CodeBuddy 的话，hook 和自动重试都无从谈起。明说，别让人以为是插件自己坏了
    hasCbCmd().then((has) => {
        if (has) l("CodeBuddy 命令可用");
        else {
            l("未检测到 CodeBuddy 扩展，通知与自动重试都不会生效");
            notify("【CBH】未检测到 CodeBuddy，本插件需要它才能工作");
        }
    });

    // 启动即自检一次，缺 hook 就自动补上（不补的话完成通知会静默失效）
    let hookWarned = false;
    const init = ensureHook();
    // 新装的机器第一次激活就走到这里：hook 是刚写进配置的，CodeBuddy 要重开会话才读得到
    if (init.fixed) notify(`【CBH】已配置通知 hook（${init.fixed}），重开 CodeBuddy 会话后生效`);
    if (init.probs.length) {
        l(`hook 仍未就绪: ${init.probs.join("; ")}`);
        notify(`【CBH】hook 异常，完成通知可能失效: ${init.probs[0]}`);
        hookWarned = true;
    } else {
        l("hook 自检 OK");
    }

    let tick = 0;
    // 心跳/自检/清理按真实时间算，不按轮次 —— pollInterval 可被调到 60 秒，
    // 按轮次算心跳会从 60 秒变成 20 分钟，hook 那边 5 分钟就判扩展已退出。
    let lastBeat = 0;
    let lastCheck = 0;
    let lastClean = Date.now();

    const tickFn = () => {
        tick++;
        const now = Date.now();
        const dir = path.join(LOG, today());
        updateStatusBar();
        // 每 60 秒刷一次 mtime，避免 hook 认为扩展已退出
        if (now - lastBeat > 60000) { lastBeat = now; writeFocus(true); }
        // 每 10 分钟自检一次 hook（配置丢失/脚本被删会导致通知静默失效）
        if (now - lastCheck > 600000) {
            lastCheck = now;
            const probs = ensureHook().probs;   // 失败原因 ensureHook 已经记过日志，这里只管要不要告警
            if (probs.length) {
                if (!hookWarned) { notify(`【CBH】hook 异常，完成通知可能失效: ${probs[0]}`); hookWarned = true; }
            } else if (hookWarned) {
                hookWarned = false;
                l("hook 自检恢复 OK");
            }
        }
        if (!fs.existsSync(dir)) {
            if (tick % 10 === 0) l(`alive:${tick} no-dir`);
            return;
        }
        const files = fs.readdirSync(dir).filter((f) => f.endsWith(".log"));
        if (tick % 10 === 0) l(`alive:${tick} files=${files.length} q=${queue.length}`);
        // 只扫本窗口打开的项目。日志目录是当天所有项目共用的（实测同时躺着 5 个项目的日志），
        // 不筛的话有两个后果：① A 窗口会把 B 项目的错误重试进 A 的会话；
        // ② 每个开着的窗口都会各弹一次同样的通知、各发一次同样的重试消息。
        const mine = localProjects();
        for (const f of files) {
            const projName = f.split("__")[0];
            if (!mine.includes(projName.toLowerCase())) continue;
            const fp = path.join(dir, f);
            if (S[fp] === undefined) {
                try { S[fp] = fs.statSync(fp).size; } catch (_) { continue; }
                l(`init:${projName}:${S[fp]}`);
                continue;
            }
            try { scanFile(fp); } catch (_) {}
        }
        // 危险命令等待超时 → 提醒。agent 此时在等工具结果不会 Stop，hook 覆盖不到。
        for (const k of Object.keys(W)) {
            const w = W[k];
            if (!w) continue;
            if (!w.notified && now - w.ts > CONFIRM_WAIT) {
                w.notified = true;
                if (hookSaidWaiting(k)) { l(`confirm-skip(hook已通知):${k}`); }
                else { notify(`【${k}】有命令待你确认`, k); l(`confirm-wait:${k} ${w.cmd}`); }
                continue;   // 一轮只弹一条：扩展被系统挂起很久后醒来，别把两次提醒挤在一起
            }
            // 等满 3 分钟仍没人动 → 补一次。三条提醒路径全都只响一次，Stop 又不是心跳，
            // 漏看就再也不会响，而 CodeBuddy 自身没有确认超时，任务会一直挂在
            // waiting_user_input、agent 原地闲着。这里刻意不看 hookSaidWaiting：
            // hook 那条同样是单次的，拿它当理由跳过就等于放弃兜底。
            // 已处理的确认不会误报——用户一点，日志里立刻写 Permission response，
            // trackConfirm 随即清掉 W[p]，这个分支就进不来了。
            if (!w.reminded && now - w.ts > CONFIRM_REMIND) {
                w.reminded = true;
                notify(`【${k}】仍在等你确认（已等 ${Math.round((now - w.ts) / 60000)} 分钟）`, k);
                l(`confirm-remind:${k} ${w.cmd}`);
            }
        }
        // 服务端错误 → 过了宽限期仍没恢复 → 自动重试续上任务
        for (const k of Object.keys(R)) {
            const r = R[k];
            if (!r || r.retried) continue;
            if (now - r.ts < RETRY_GRACE) continue;
            if (now - r.logTs > RETRY_WINDOW) { l(`retry skip(过期):${k}`); R[k] = null; continue; }
            const st = E[k] || { next: 0 };
            // 冷却中就先别动 retried：置了位再 continue，这条错误此后永远进不了队列
            if (now < st.next) continue;
            r.retried = true;
            enqueue(k, r.code, r.cid);
        }
        // 内存清理
        if (now - lastClean > 3000000) {
            lastClean = now;
            for (const k of Object.keys(E)) {
                if (E[k] && E[k].next && now > E[k].next + 600000) delete E[k];
            }
            for (const k of Object.keys(S)) {
                if (!fs.existsSync(k)) delete S[k];
            }
            for (const k of Object.keys(W)) { if (!W[k]) delete W[k]; }
            for (const k of Object.keys(R)) { if (!R[k]) delete R[k]; }
        }
    };

    let timer = null;
    const startTimer = () => {
        if (timer) clearInterval(timer);
        timer = setInterval(tickFn, cfg.pollInterval);
        l(`timer: ${cfg.pollInterval}ms`);
    };
    startTimer();

    // pollInterval 改了要重建 timer，其余配置每次用的时候现读 cfg
    ctx.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration((e) => {
            if (!e.affectsConfiguration("codebuddyHelper")) return;
            refreshCfg();
            startTimer();
        })
    );
    ctx.subscriptions.push(new vscode.Disposable(() => clearInterval(timer)));
}

module.exports = { activate };