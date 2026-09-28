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
const W = {};          // 项目 → { ts, cmd, notified }  危险命令等待确认
const R = {};          // 项目 → { ts, logTs, code, cid, retried }  待处理的服务端错误
const MAX = 10;
const CONFIRM_WAIT = 20000;   // 危险命令等待超过 20 秒就提醒（agent 此时不 Stop，hook 覆盖不到）
const RETRY_GRACE = 20000;    // 错误出现后等这么久再重试，给"已自行恢复"的日志写入时间
const RETRY_WINDOW = 1800000; // 只处理 30 分钟内的错误，更早的视为历史遗留
const HOOK_WAIT_WINDOW = 180000; // hook 发过的"待确认"通知保质期，与 cb-hook.ps1 判卡住用的 3 分钟新鲜度对齐
const CFG_FILE = path.join(os.tmpdir(), "cbh-config.json");  // 导给 hook 读的配置
// Windows Toast 的来源标识：注册表项给显示名，开始菜单里的同名 .lnk 让壳层认得这个 AppId
const AUMID = "CBH";
const AUMID_LNK = path.join(ROAM_APP, "Microsoft", "Windows", "Start Menu", "Programs", `${AUMID}.lnk`);

// 用户配置（VS Code 设置 → CodeBuddy Helper）。改设置即时生效，见 activate 里的 onDidChangeConfiguration
let cfg = { pollInterval: 3000, retryCooldown: 30000, retryDelay: 5, notifyOnComplete: true, notifyOn429: true };

// 全局重试队列：429 是账号级限流，多个项目同时重试只会继续撞墙，串行处理
const queue = [];
let busy = false;

// 焦点上报文件：本窗口是否处于前台，hook 读它决定要不要弹通知。
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
        fs.writeFileSync(CFG_FILE, JSON.stringify({ notifyOnComplete: cfg.notifyOnComplete }), "utf-8");
    } catch (_) {}
    l(`cfg: poll=${cfg.pollInterval}ms cooldown=${cfg.retryCooldown}ms delay=${cfg.retryDelay}s complete=${cfg.notifyOnComplete} 429=${cfg.notifyOn429}`);
}

// 通知：仅 Windows Toast，不做 VS Code 弹窗（避免每次完成任务都弹窗打扰）
function notify(msg) {
    l(msg);
    try {
        const f = path.join(os.tmpdir(), `t_${Date.now()}.ps1`);
        const xml = msg.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
        fs.writeFileSync(f, "\ufeff" + `[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null
[Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom,ContentType=WindowsRuntime]|Out-Null
$x=New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>${xml}</text></binding></visual></toast>')
$n=[Windows.UI.Notifications.ToastNotification]::new($x)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('CBH').Show($n)
`, "utf-8");
        cp.exec(`powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "${f}"`, () => {
            setTimeout(() => { try { fs.unlinkSync(f); } catch (_) {} }, 5000);
        });
    } catch (_) {}
}

// 注册通知来源。没注册的话 Toast 显示成"未知程序"、图标空白。
// 这套注册原本写在已废弃的 monitor.ps1 里，从来没被执行过 —— 新机器装完通知就是没来源名的。
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
                notified: false
            };
        } else if (/状态变更: pending ->|confirmed:|execution_started|全量执行完成|Permission response: approved=/.test(line)) {
            if (W[p]) W[p] = null;   // 已响应即清除，避免状态残留
        }
    }
}

// 服务端错误（429/500）追踪。
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
        // 502/503/504 是网关侧的临时故障，性质和 429/500 一样，都值得退避重试
        const codeM = line.match(/HTTP (429|500|502|503|504|401)/);
        if (!codeM) continue;

        const code = codeM[1];
        const block = line + "\n" + lines.slice(i, i + 5).join("\n");
        // 真实日志格式: X-Conversation-ID: 33c46762bc3b4cbd88cbe73166577849
        // \W{0,8} 兼容带引号/多空格/换行的变体（实测 55/55 命中）
        const cid = (block.match(/[Xx]-[Cc]onversation-[Ii][Dd]\W{0,8}([a-f0-9]{32})/) || [])[1] || "";
        const logTs = new Date(head[1].replace(/\//g, "-")).getTime();

        // 令牌过期重试也没用，只提醒。安全相关，不受 notifyOn429 开关影响
        if (code === "401") { notify(`【${p}】令牌过期，请重新登录`); continue; }

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

    // 服务端错误（429/500/401）追踪 —— 状态机，见 trackApiError 注释
    trackApiError(p, c);
}

// 入队重试（全局串行）
function enqueue(p, code, cid) {
    if (!E[p]) E[p] = { code: null, count: 0, next: 0, warned: false };
    const s = E[p];
    if (s.code !== code) { s.code = code; s.count = 0; s.warned = false; }
    // count 是已完成的重试次数，封顶在 MAX：越界后不再自增，
    // 否则持续限流时状态栏会冒出"重试 20/10"这种数字
    if (s.count >= MAX) {
        // 只在刚越界时喊一次：持续限流期间每来一条新错误都弹同一句话纯属轰炸
        if (!s.warned) { s.warned = true; notify(`【${p}】HTTP ${code} 已达 ${MAX} 次上限，请手动处理`); }
        return;
    }
    s.count++;
    const base = code === "429" ? Math.min(cfg.retryDelay * Math.pow(2, s.count - 1), 60) : cfg.retryDelay;
    const delay = Math.round(base * (0.8 + Math.random() * 0.4) * 1000);
    s.next = Date.now() + delay + cfg.retryCooldown;
    queue.push({ p, code, cid, delay, count: s.count });
    notify(`【${p}】HTTP ${code} 第${s.count}/${MAX}次重试`);
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

    // 焦点状态上报：hook 据此判断 VS Code 是否在前台，在前台就不弹通知（避免打扰）
    // hook 侧以 5 分钟未更新视为失效，所以除了状态变化要写，还得定期刷新 mtime
    let lastFocus = null;
    const writeFocus = (force) => {
        const cur = vscode.window.state.focused ? "1" : "0";
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
            tip = `${k}\nHTTP ${s.code} · 第 ${s.count} 次\n队列 ${queue.length} 项`;
        } else if (lastRetry) {
            const sec = Math.round((Date.now() - lastRetry.ts) / 1000);
            const ago = sec < 60 ? `${sec} 秒前` : `${Math.round(sec / 60)} 分钟前`;
            text = `$(bell) CBH ${lastRetry.ok ? "$(check)" : "$(warning)"}`;
            tip = `最近重试: ${lastRetry.proj} (HTTP ${lastRetry.code})\n${lastRetry.ok ? "成功" : "失败"} · ${ago}`;
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
        for (const f of files) {
            const fp = path.join(dir, f);
            if (S[fp] === undefined) {
                try { S[fp] = fs.statSync(fp).size; } catch (_) { continue; }
                l(`init:${f.split("__")[0]}:${S[fp]}`);
                continue;
            }
            try { scanFile(fp); } catch (_) {}
        }
        // 危险命令等待超时 → 提醒。agent 此时在等工具结果不会 Stop，hook 覆盖不到。
        for (const k of Object.keys(W)) {
            const w = W[k];
            if (w && !w.notified && now - w.ts > CONFIRM_WAIT) {
                w.notified = true;
                if (hookSaidWaiting(k)) { l(`confirm-skip(hook已通知):${k}`); }
                else { notify(`【${k}】有命令待你确认`); l(`confirm-wait:${k} ${w.cmd}`); }
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