import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");

const sharedScriptCode = fs.readFileSync(
  path.join(ROOT, "scripts/po0-firewall-whitelist.js"),
  "utf8"
);

function runSharedClient({
  envType = "surge",
  argument,
  storeInit = {},
  cellular = false,
  responder,
}) {
  const store = new Map(Object.entries(storeInit));
  const notifications = [];
  const requests = [];

  return new Promise((resolve, reject) => {
    const sandbox = {
      console,
      Date,
      JSON,
      Math,
      Promise,
      String,
      Array,
      Object,
      parseInt,
      isNaN,
      encodeURIComponent,
      decodeURIComponent,
      setTimeout: (fn) => {
        // 零延迟驱动重试，加速测试
        Promise.resolve().then(fn);
      },
      $argument: argument,
      $network: cellular
        ? { v4: { primaryInterface: "pdp_ip0" } }
        : { v4: { primaryInterface: "en0" } },
    };

    if (envType === "qx") {
      sandbox.$task = {
        fetch(opts) {
          requests.push(opts);
          const r = responder(opts, requests.length);
          if (r.netError !== undefined) {
            return Promise.reject(r.netError);
          }
          return Promise.resolve({ statusCode: r.status, body: r.body });
        },
      };
      sandbox.$prefs = {
        valueForKey: (k) => (store.has(k) ? store.get(k) : null),
        setValueForKey: (v, k) => {
          store.set(k, String(v));
          return true;
        },
      };
      sandbox.$notify = (title, subtitle, body) => {
        notifications.push({ title, subtitle, body });
      };
      sandbox.$done = (val) => {
        resolve({ done: val, notifications, requests, store });
      };
    } else {
      if (envType === "loon") {
        sandbox.$loon = "iOS 3.2.0";
      } else if (envType === "shadowrocket") {
        sandbox.$environment = { "shadowrocket-version": "2.2.50" };
      } else {
        sandbox.$environment = { "surge-version": "5.10.0" };
      }

      const httpClient = {
        post(opts, cb) {
          // 模拟 Shadowrocket ObjC 桥接对象 self 类型检查
          if (this !== httpClient) {
            throw new TypeError("self type check failed for Objective-C instance method");
          }
          requests.push({ ...opts, method: "POST" });
          const r = responder(opts, requests.length);
          Promise.resolve().then(() => {
            if (r.netError !== undefined) cb(r.netError, null, null);
            else cb(null, { status: r.status }, r.body);
          });
        },
        get(opts, cb) {
          if (this !== httpClient) {
            throw new TypeError("self type check failed for Objective-C instance method");
          }
          requests.push({ ...opts, method: "GET" });
          const r = responder(opts, requests.length);
          Promise.resolve().then(() => {
            if (r.netError !== undefined) cb(r.netError, null, null);
            else cb(null, { status: r.status }, r.body);
          });
        },
      };
      sandbox.$httpClient = httpClient;
      sandbox.$persistentStore = {
        read: (k) => (store.has(k) ? store.get(k) : null),
        write: (v, k) => {
          store.set(k, String(v));
          return true;
        },
      };
      sandbox.$notification = {
        post: (title, subtitle, body) => {
          notifications.push({ title, subtitle, body });
        },
      };
      sandbox.$done = (val) => {
        resolve({ done: val, notifications, requests, store });
      };
    }

    try {
      vm.runInNewContext(sharedScriptCode, sandbox, {
        filename: "po0-firewall-whitelist.js",
      });
    } catch (err) {
      reject(err);
    }
  });
}

// 1. 测试 Surge / Shadowrocket / Loon / QX 的 timeout 单位与 ObjC 桥接调用安全
{
  const srRes = await runSharedClient({
    envType: "shadowrocket",
    argument: '"tokens=pgnfw_sr1@0|pgnfw_sr2"',
    cellular: true,
    responder: () => ({
      status: 200,
      body: JSON.stringify({
        enabled: true,
        currentIp: "203.0.113.0/24",
        limit: 5,
        whitelist: [{ ip: "203.0.113.0/24", slot: 0 }],
      }),
    }),
  });
  assert.equal(srRes.requests.length, 2);
  assert.equal(srRes.requests[0].timeout, 15);
  assert.match(srRes.requests[0].url, /\/pgnfw_sr1\/add\?slot=0$/);
  assert.match(srRes.requests[1].url, /\/pgnfw_sr2\/add$/);
  assert.equal(srRes.done.icon, "checkmark.shield");
  assert.match(srRes.done.title, /📶/);
  assert.equal(srRes.notifications.length, 1);

  // 相同状态第二次运行应保持安静（不弹重复通知）
  const srRes2 = await runSharedClient({
    envType: "shadowrocket",
    argument: '"tokens=pgnfw_sr1@0|pgnfw_sr2"',
    storeInit: Object.fromEntries(srRes.store),
    cellular: true,
    responder: () => ({
      status: 200,
      body: JSON.stringify({
        enabled: true,
        currentIp: "203.0.113.0/24",
        limit: 5,
        whitelist: [{ ip: "203.0.113.0/24", slot: 0 }],
      }),
    }),
  });
  assert.equal(srRes2.notifications.length, 0);

  const loonRes = await runSharedClient({
    envType: "loon",
    argument: { tokens: "pgnfw_loon1" },
    responder: () => ({
      status: 200,
      body: JSON.stringify({
        enabled: true,
        currentIp: "198.51.100.0/24",
        limit: 5,
        whitelist: [{ ip: "198.51.100.0/24", slot: null }],
      }),
    }),
  });
  assert.equal(loonRes.requests[0].timeout, 15000);
}

// 2. 测试瞬时裸 400 "Error" 重试自愈、规范 JSON 400 确定性报错（不再出现 0/undefined）与畸形 % 参数容错
{
  const retryRes = await runSharedClient({
    envType: "surge",
    argument: "tokens=pgnfw_transient",
    responder: (_opts, n) =>
      n < 3
        ? { status: 400, body: "Error" }
        : {
            status: 200,
            body: JSON.stringify({
              enabled: true,
              currentIp: "192.0.2.0/24",
              limit: 5,
              whitelist: [{ ip: "192.0.2.0/24", slot: null }],
            }),
          },
  });
  assert.equal(retryRes.requests.length, 3);
  assert.equal(retryRes.done.icon, "checkmark.shield");

  const jsonErrRes = await runSharedClient({
    envType: "qx",
    storeInit: { po0fw_tokens: "pgnfw_invalid" },
    responder: () => ({
      status: 400,
      body: JSON.stringify({ code: 400, message: "serviceId is required" }),
    }),
  });
  assert.equal(jsonErrRes.requests.length, 1);
  assert.equal(jsonErrRes.notifications.length, 1);
  assert.match(jsonErrRes.notifications[0].body, /HTTP 400: serviceId is required/);
  assert.doesNotMatch(jsonErrRes.notifications[0].body, /undefined/);

  // 畸形百分号编码不得抛未捕获 URIError，且非法槽位 @abc 必须显式报错
  const malformedRes = await runSharedClient({
    envType: "surge",
    argument: "tokens=pgnfw_bad%ZZ@abc",
    responder: () => ({ status: 200, body: "{}" }),
  });
  assert.equal(malformedRes.requests.length, 0);
  assert.match(malformedRes.done.content, /槽位号 '@abc' 无效/);
}

// 3. 测试 Egern 原生模块（含 403 throw 解析、并发执行、持续失败不吞通知）
{
  // 将 HTTP_RETRY_DELAY_MS 在测试临时副本中缩短为 1ms，避免真实等待 4.5s
  const egernPath = path.join(ROOT, "egern/po0-firewall-whitelist.js");
  const egernCode = fs
    .readFileSync(egernPath, "utf8")
    .replace("const HTTP_RETRY_DELAY_MS = 1500;", "const HTTP_RETRY_DELAY_MS = 1;");
  const tmpEgern = path.join(ROOT, "tests/.tmp-egern-test.mjs");
  fs.writeFileSync(tmpEgern, egernCode, "utf8");
  try {
    const { default: egernMain } = await import(pathToFileURL(tmpEgern).href);
    const kv = new Map();
    const jsonKv = new Map();
    const notices = [];
    let callCount = 0;

    const makeCtx = (tokens, handler) => ({
      env: { tokens },
      device: { cellular: { carrier: "CMCC" }, wifi: {} },
      storage: {
        get: (k) => kv.get(k) ?? null,
        set: (k, v) => kv.set(k, v),
        getJSON: (k) => jsonKv.get(k) ?? null,
        setJSON: (k, v) => jsonKv.set(k, v),
      },
      notify: (n) => notices.push(n),
      http: {
        async post(url) {
          callCount++;
          return handler(url, callCount);
        },
      },
    });

    // 403 槽位冲突首次运行弹通知
    await egernMain(
      makeCtx("pgnfw_eg1@1", () => {
        throw new Error('HTTP error! status: 403, body: {"currentIp":"203.0.113.0/24"}');
      })
    );
    assert.equal(notices.length, 1);
    assert.match(notices[0].body, /槽位冲突/);

    // 关键回归验证：Egern 持续失败时第二次运行必须继续弹通知，不能静默吞掉！
    await egernMain(
      makeCtx("pgnfw_eg1@1", () => {
        throw new Error('HTTP error! status: 403, body: {"currentIp":"203.0.113.0/24"}');
      })
    );
    assert.equal(notices.length, 2);

    // 恢复正常后弹一次成功通知，随后例行相同状态保持静默
    notices.length = 0;
    await egernMain(
      makeCtx("pgnfw_eg1@0,pgnfw_eg2", async () => ({
        status: 200,
        text: async () =>
          JSON.stringify({
            enabled: true,
            currentIp: "203.0.113.0/24",
            limit: 5,
            whitelist: [{ ip: "203.0.113.0/24", slot: 0 }],
          }),
      }))
    );
    assert.equal(notices.length, 1);
    assert.match(notices[0].subtitle, /po0 加白 2\/2/);

    await egernMain(
      makeCtx("pgnfw_eg1@0,pgnfw_eg2", async () => ({
        status: 200,
        text: async () =>
          JSON.stringify({
            enabled: true,
            currentIp: "203.0.113.0/24",
            limit: 5,
            whitelist: [{ ip: "203.0.113.0/24", slot: 0 }],
          }),
      }))
    );
    assert.equal(notices.length, 1);
  } finally {
    fs.rmSync(tmpEgern, { force: true });
  }
}

// 4. 校验 docs/index.html 内联脚本逻辑、Windows PowerShell BOM 约束与模块资源完整性
{
  const html = fs.readFileSync(path.join(ROOT, "docs/index.html"), "utf8");
  const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
  assert.ok(scriptMatch, "docs/index.html must contain inline script");

  // 验证内联 JS 语法合法，并在最小 DOM 桩下测试多 token 与安卓槽位 URL 生成
  const makeEl = (text = "") => ({
    value: text,
    textContent: text,
    innerText: text,
    href: "",
    style: {},
    dataset: {},
    children: [],
    classList: {
      set: new Set(),
      add(c) {
        this.set.add(c);
      },
      remove(c) {
        this.set.delete(c);
      },
      toggle(c, on) {
        if (on) this.set.add(c);
        else this.set.delete(c);
      },
    },
    listeners: {},
    addEventListener(ev, fn) {
      this.listeners[ev] = fn;
    },
    setAttribute() {},
    focus() {},
    appendChild(node) {
      this.children.push(node);
      this.textContent += node.textContent;
    },
  });

  const els = {
    tok: makeEl(""),
    tokState: makeEl(""),
    tokStateText: makeEl(""),
    tokClear: makeEl(""),
    tokDemo: makeEl("填入示例"),
    "android-urls": makeEl(""),
    "android-multi-hint": makeEl(""),
    iosTokBar: makeEl(""),
    copyCommaTok: makeEl("复制"),
    copyPipeTok: makeEl("复制"),
  };
  const cmdSpans = [makeEl("pgnfw_你的token"), makeEl("pgnfw_你的token")];
  const schemeLink = makeEl("一键安装");
  schemeLink.dataset = {
    scheme: "surge:///install-module?url={U}",
    file: "surge/po0-firewall-whitelist.sgmodule",
  };

  const domSandbox = {
    localStorage: {
      store: {},
      getItem(k) {
        return this.store[k] || null;
      },
      setItem(k, v) {
        this.store[k] = v;
      },
      removeItem(k) {
        delete this.store[k];
      },
    },
    navigator: {},
    setTimeout: () => {},
    encodeURIComponent,
    parseInt,
    String,
    Boolean,
    document: {
      getElementById: (id) => els[id],
      createTextNode: (t) => ({ textContent: t }),
      createElement: () => makeEl(""),
      querySelectorAll: (sel) => {
        if (sel === "[data-t]") return cmdSpans;
        if (sel === "[data-scheme]") return [schemeLink];
        return [];
      },
    },
  };

  vm.runInNewContext(scriptMatch[1], domSandbox, { filename: "docs/index.html" });
  // 页面初始化后一键安装按钮必须立即拥有 href
  assert.match(schemeLink.href, /^surge:\/\/\/install-module\?url=https%3A%2F%2F/);

  // 点击「填入示例」不写入 localStorage，但同步更新所有命令与安卓 URL
  els.tokDemo.listeners.click();
  assert.equal(domSandbox.localStorage.getItem("po0fw_token"), null);
  assert.match(cmdSpans[0].textContent, /^pgnfw_homeRouter@0,pgnfw_mobileNode$/);

  // 输入多 token + 固定槽位（含前导零 @00），验证命令占位与安卓 URL 转换正确
  els.tok.value = "pgnfw_homeA@00 | pgnfw_officeB";
  els.tok.listeners.input();
  assert.equal(cmdSpans[0].textContent, "pgnfw_homeA@0,pgnfw_officeB");
  assert.equal(
    els["android-urls"].textContent,
    "https://124.221.69.228/api/firewall/pgnfw_homeA/add?slot=0\nhttps://124.221.69.228/api/firewall/pgnfw_officeB/add"
  );
  assert.equal(els["android-multi-hint"].style.display, "block");
  assert.ok(els.tokState.classList.set.has("ok"));

  // 验证 po0-debug.js 在 Loon 下使用毫秒级 10000ms timeout（而非 10ms）
  const debugCode = fs.readFileSync(path.join(ROOT, "scripts/po0-debug.js"), "utf8");
  let debugProbeTimeout = null;
  await new Promise((resolve) => {
    vm.runInNewContext(debugCode, {
      Date,
      JSON,
      String,
      $loon: "3.2.0",
      $argument: "tokens=debug",
      $notification: { post() {} },
      $httpClient: {
        post(opts, cb) {
          debugProbeTimeout = opts.timeout;
          cb(null, { status: 400 }, "{}");
        },
      },
      $done: resolve,
    });
  });
  assert.equal(debugProbeTimeout, 10000);

  // 检查所有静态约束：图标存在、PowerShell UTF-8 BOM、VBS 纯 ASCII、LICENSE 存在
  assert.ok(fs.existsSync(path.join(ROOT, "LICENSE")), "LICENSE must exist");
  assert.ok(fs.existsSync(path.join(ROOT, "docs/icons/po0fw.png")), "po0fw.png icon must exist");

  for (const psFile of ["windows/po0fw.ps1", "windows/install-windows.ps1"]) {
    const buf = fs.readFileSync(path.join(ROOT, psFile));
    assert.ok(
      buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf,
      `${psFile} must start with UTF-8 BOM`
    );
    const lines = buf.toString("utf8").split(/\r?\n/);
    for (const line of lines) {
      assert.doesNotMatch(line, /`[ \t]*$/, `${psFile} must not use fragile backtick continuations`);
    }
  }

  const vbsBuf = fs.readFileSync(path.join(ROOT, "windows/po0fw-hidden.vbs"));
  assert.ok(vbsBuf.every((b) => b < 0x80), "windows/po0fw-hidden.vbs must remain ASCII-only");
}

console.log("po0fw JS client, HTML UI, and repository integrity tests passed");
