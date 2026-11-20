/*
 * po0fw 调试脚本：每次运行必弹通知，回显运行环境与 $argument 原文。
 * 用于确认客户端（尤其 Shadowrocket / Loon）的 cron / network-changed 是否真的在跑、
 * argument 是否被传入。定位完问题请删除本模块。
 */
var envs = [];
var isQX = typeof $task !== "undefined";
var isSurgeLike = typeof $httpClient !== "undefined";
if (isQX) envs.push("QX");
if (isSurgeLike) envs.push("SurgeLike");
if (typeof $loon !== "undefined") envs.push("Loon");
if (typeof $network !== "undefined") envs.push("$network");
if (typeof $persistentStore !== "undefined") envs.push("store");

var envInfo = "";
try {
  if (typeof $environment !== "undefined" && $environment) {
    envInfo = JSON.stringify($environment).toLowerCase();
  }
} catch (e) {}

var isLoon = typeof $loon !== "undefined" || envInfo.indexOf("loon") >= 0;
var isSurgeFamily =
  envInfo.indexOf("surge-version") >= 0 ||
  envInfo.indexOf("shadowrocket") >= 0 ||
  envInfo.indexOf("stash") >= 0;

// Loon / QX timeout 单位为毫秒，Surge / SR / Stash 为秒
var probeTimeout = isLoon || isQX ? 10000 : isSurgeFamily ? 10 : null;

var argText;
try {
  argText =
    typeof $argument === "undefined"
      ? "(undefined)"
      : typeof $argument === "object"
        ? JSON.stringify($argument)
        : String($argument);
} catch (e) {
  argText = "(error: " + e + ")";
}

var iface = "";
try {
  iface = ($network && $network.v4 && $network.v4.primaryInterface) || "(no v4)";
} catch (e) {
  iface = "(err)";
}

function sendNotice(t, s, b) {
  if (isQX && typeof $notify !== "undefined") $notify(t, s, b);
  else if (typeof $notification !== "undefined") $notification.post(t, s, b);
}

var title = "po0fw 调试 · 脚本已运行";
var body =
  "time: " +
  new Date().toTimeString().slice(0, 8) +
  "\nenv: " +
  (envs.join(",") || "unknown") +
  "\niface: " +
  iface +
  "\n$argument: " +
  argText.slice(0, 120);

sendNotice(title, "", body);

var probeOpts = { url: "https://124.221.69.228/api/firewall/ping_test/add", body: "" };
if (probeTimeout !== null) probeOpts.timeout = probeTimeout;

// 再测一次真实出网（走模块里的 DIRECT 规则；预期返回 HTTP 400 即证明直连链路畅通）
if (isQX) {
  probeOpts.method = "POST";
  $task.fetch(probeOpts).then(
    function (resp) {
      sendNotice("po0fw 调试 · 出网测试", "", "HTTP ✅ status " + resp.statusCode);
      $done();
    },
    function (err) {
      sendNotice("po0fw 调试 · 出网测试", "", "HTTP ❌ " + String((err && err.error) || err));
      $done();
    }
  );
} else if (isSurgeLike) {
  $httpClient.post(probeOpts, function (error, response) {
    var line = error
      ? "HTTP ❌ " + String(error)
      : "HTTP ✅ status " + (response && (response.status || response.statusCode));
    sendNotice("po0fw 调试 · 出网测试", "", line);
    $done({});
  });
} else if (typeof $done !== "undefined") {
  $done({});
}
