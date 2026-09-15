import Foundation

/// The page served to the phone.
///
/// Two things it deliberately does *not* do:
///
/// - **It never carries a credential in the markup.** The master token is not
///   injected here; a paired phone holds its own device token in `localStorage`.
///   Earlier this page embedded the master token, which meant any device that
///   could load the page got full privileges.
/// - **It loads nothing external.** No CDN, no font files, no analytics. It may
///   be on a LAN with no route out, and a page that can see your screen should
///   not also be fetching someone else's JavaScript.
public enum WebViewer {
    public static func html(hostName: String, version: String) -> String {
        template
            .replacingOccurrences(of: "__HOST__", with: escape(hostName))
            .replacingOccurrences(of: "__VERSION__", with: escape(version))
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let template = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#070a08">
<title>PHONE·CATCH·SCREEN</title>
<style>
  /* ---------------------------------------------------------------------
     Visual language: terminal/TUI chrome carrying a pixel feel.

     The pixel character lives in the *chrome* — hard 1px corners, block
     glyphs, tabular figures, a scanline wash, inverse-video buttons. It is
     deliberately NOT a pixel font: those do not cover CJK, and at phone sizes
     Chinese in a pixel face is unreadable. So the font stacks are split —
     Latin and digits get monospace with tight tracking, Chinese falls back to
     the platform CJK face at a normal reading size.
     --------------------------------------------------------------------- */
  :root{
    --bg:#070a08;
    --panel:#0c110d;
    --panel-2:#111813;
    --line:#1f3a28;
    --line-hot:#3d7a50;
    --ink:#b9f0c9;
    --ink-bright:#6bffa0;
    --dim:#4e7a5e;
    --warn:#ffc046;
    --err:#ff6b6b;
    --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
    --cjk: "PingFang SC", "Hiragino Sans GB", "Heiti SC", "Microsoft YaHei", sans-serif;
  }
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  html,body{height:100%}
  body{
    margin:0;
    background:var(--bg);
    color:var(--ink);
    font:15px/1.6 var(--cjk);
    display:flex;
    flex-direction:column;
    overflow:hidden;
    padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
  }
  [hidden]{display:none!important}

  /* CRT wash. Fixed, non-interactive, and cheap — one repeating gradient. */
  #scanlines{
    position:fixed;inset:0;pointer-events:none;z-index:99;
    background:repeating-linear-gradient(
      to bottom,
      rgba(107,255,160,.035) 0 1px,
      rgba(0,0,0,0) 1px 3px
    );
    mix-blend-mode:screen;
  }

  .px{font-family:var(--mono);font-variant-numeric:tabular-nums;letter-spacing:.05em}
  .dim{color:var(--dim)}
  code{
    font-family:var(--mono);background:var(--panel-2);
    border:1px solid var(--line);padding:1px 5px;color:var(--ink-bright);
  }

  /* ---------- Panels ---------- */
  .panel{
    border:1px solid var(--line);
    background:var(--panel);
    padding:18px 16px;
    position:relative;
  }
  /* TUI group-box: the label sits on the top border and masks it. */
  .panel-title{
    position:absolute;top:-9px;left:12px;
    background:var(--bg);padding:0 6px;
    font-family:var(--mono);
    font-size:11px;letter-spacing:.22em;color:var(--ink-bright);
  }

  /* ---------- Boot / pairing ---------- */
  #boot{
    flex:1;display:flex;flex-direction:column;justify-content:center;
    gap:20px;padding:20px;overflow-y:auto;
  }
  /* Keeps the form from stretching into a letterbox on a desktop-width window,
     while still filling a phone. */
  #boot > *{width:100%;max-width:540px;margin-left:auto;margin-right:auto}

  /* The wordmark is drawn with a CSS border rather than box-drawing characters.
     `▛▀▜` are East-Asian "ambiguous width": they fall back to a CJK face at a
     different advance than Latin text, so a hand-aligned ASCII box comes out
     crooked depending on the system's font fallback. A border cannot misalign. */
  .logo{
    display:flex;align-items:center;gap:12px;
    border:2px solid var(--ink-bright);
    padding:10px 16px;
    font-family:var(--mono);
    font-size:clamp(12px,3.4vw,15px);
    letter-spacing:.26em;
    color:var(--ink-bright);
  }
  .logo .mark{color:var(--ink-bright)}
  .logo .word{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

  .hint{margin:0 0 16px;color:var(--dim);font-size:13.5px;line-height:1.75}
  .hint b{color:var(--ink);font-weight:600}

  .field{display:block;margin-bottom:14px}
  .field-label{
    display:block;
    font-family:var(--mono);font-size:10.5px;letter-spacing:.2em;
    color:var(--dim);margin-bottom:6px;
  }
  input{
    width:100%;
    background:var(--panel-2);
    border:1px solid var(--line);
    color:var(--ink-bright);
    padding:12px 14px;
    font-family:var(--mono);
    font-size:16px;
    border-radius:0;              /* hard corners: no rounding anywhere */
    outline:none;
  }
  input:focus{border-color:var(--line-hot);background:#0d1410}
  input::placeholder{color:#2c4535}
  #code{
    font-size:28px;
    letter-spacing:.34em;
    text-align:center;
    /* Left padding cancels the trailing letter-space so the digits sit centred. */
    padding:14px 0 14px .34em;
    font-variant-numeric:tabular-nums;
  }

  /* ---------- Buttons: inverse video, like a selected TUI item ---------- */
  .btn{
    appearance:none;cursor:pointer;
    background:var(--panel);
    color:var(--ink);
    border:1px solid var(--line);
    border-radius:0;
    padding:11px 12px;
    font-family:var(--mono);
    font-size:12.5px;
    letter-spacing:.08em;
    min-height:42px;
    transition:background .1s,color .1s,border-color .1s;
    white-space:nowrap;
  }
  .btn:active,.btn.on{
    background:var(--ink-bright);
    color:#04120a;
    border-color:var(--ink-bright);
  }
  .btn.primary{color:var(--ink-bright);border-color:var(--line-hot)}
  .btn.primary.on,.btn.primary:active{background:var(--ink-bright);color:#04120a}
  .btn.danger{color:var(--err);border-color:#5a2626}
  .btn.danger:active{background:var(--err);color:#1a0505;border-color:var(--err)}
  .btn:disabled{opacity:.45}
  .btn.wide{flex:1 1 100%}

  /* ---------- Linked view ---------- */
  #app{flex:1;display:flex;flex-direction:column;min-height:0}

  .statusbar{
    flex:0 0 auto;
    display:flex;align-items:center;gap:8px;
    padding:9px 12px;
    border-bottom:1px solid var(--line);
    font-size:11px;
    overflow:hidden;
  }
  .brand{color:var(--ink-bright);white-space:nowrap}
  .chip{
    margin-left:auto;color:var(--dim);white-space:nowrap;
    padding:1px 6px;border:1px solid var(--line);
  }
  .chip.live{color:var(--ink-bright);border-color:var(--line-hot)}
  #who{
    color:var(--dim);white-space:nowrap;overflow:hidden;
    text-overflow:ellipsis;max-width:34%;
  }
  /* Block cursor, blinking. The one piece of actual animation. */
  .cursor{animation:blink 1.1s steps(1) infinite}
  @keyframes blink{0%,50%{opacity:1}50.01%,100%{opacity:0}}

  #stage{
    flex:1 1 auto;min-height:0;
    display:flex;align-items:center;justify-content:center;
    padding:10px;position:relative;
  }
  #shot{
    display:none;
    max-width:100%;max-height:100%;
    width:auto;height:auto;
    object-fit:contain;
    border:1px solid var(--line);
    background:#000;
  }
  #shot.show{display:block}
  #shot.fill{width:100%;height:100%;object-fit:cover}
  .empty{
    text-align:center;color:var(--dim);font-size:13.5px;
    line-height:2;padding:24px;
  }

  .metabar{
    flex:0 0 auto;
    padding:5px 12px;
    border-top:1px solid var(--line);
    font-size:10.5px;color:var(--dim);
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
  }

  /* A fixed 12-column grid rather than flex-wrap: with wrapping, a wide desktop
     window lets the primary button eat all the slack and the row becomes a
     different shape at every width. Explicit spans keep the same two rows on a
     phone and on a desktop. */
  .controls{
    flex:0 0 auto;
    display:grid;
    grid-template-columns:repeat(12,1fr);
    gap:7px;
    padding:9px 12px;
    border-top:1px solid var(--line);
  }
  .controls .btn{width:100%;min-width:0}
  #grab{grid-column:span 7}
  #live{grid-column:span 5}
  #m-display,#m-window,#fit,#zen{grid-column:span 3}

  /* Same row, narrower cells — needs tighter type or "[ 整屏 ]" overflows its
     column on a 390px phone. */
  @media (max-width:430px){
    .controls .btn{padding:11px 4px;font-size:11.5px;letter-spacing:.02em}
  }

  .footbar{
    flex:0 0 auto;
    display:flex;align-items:center;gap:10px;
    padding:0 12px 12px;
  }
  .msg{
    margin:0;font-size:12.5px;color:var(--warn);
    min-height:1.2em;flex:1 1 auto;
  }
  .msg.err{color:var(--err)}
  .msg.ok{color:var(--ink-bright)}

  body.zen .statusbar,
  body.zen .metabar,
  body.zen .controls,
  body.zen .footbar{display:none}
  body.zen #stage{padding:0}
  body.zen #shot{border:0}
</style>
</head>
<body>
<div id="scanlines"></div>

<!-- ─────────────── 未配对 ─────────────── -->
<section id="boot" hidden>
  <div class="logo">
    <span class="mark">▐</span>
    <span class="word">PHONE·CATCH·SCREEN</span>
    <span class="cursor">█</span>
  </div>

  <div class="panel">
    <div class="panel-title">PAIR</div>

    <p class="hint">
      在 Mac 上执行 <code>screenbeam pair</code>，<br>
      把终端里显示的 <b>6 位配对码</b>填到下面。
    </p>

    <label class="field">
      <span class="field-label">配对码 / CODE</span>
      <input id="code" inputmode="numeric" pattern="[0-9]*" maxlength="6"
             autocomplete="off" autocorrect="off" spellcheck="false"
             placeholder="000000">
    </label>

    <label class="field">
      <span class="field-label">设备名称 / LABEL</span>
      <input id="devname" maxlength="24" autocomplete="off" placeholder="我的 iPhone">
    </label>

    <button id="pairbtn" class="btn primary wide">[ 建 立 连 接 ]</button>
    <p id="bootmsg" class="msg"></p>
  </div>
</section>

<!-- ─────────────── 已配对 ─────────────── -->
<section id="app" hidden>
  <div class="statusbar px">
    <span class="brand">▐ PCS</span>
    <span id="conn" class="chip">○ 离线</span>
    <span id="who" class="px"></span>
  </div>

  <div id="stage">
    <img id="shot" alt="最新截图">
    <div id="empty" class="empty">
      还没有截图<br>
      点下面的 <b>截屏</b>，或在 Mac 上执行 <code>screenbeam shot</code>
    </div>
  </div>

  <div class="metabar px" id="meta">—</div>

  <div class="controls">
    <button id="grab" class="btn primary">[ 截屏 ]</button>
    <button id="live" class="btn">[ 连续:关 ]</button>
    <button id="m-display" class="btn on">[ 整屏 ]</button>
    <button id="m-window" class="btn">[ 窗口 ]</button>
    <button id="fit" class="btn">[ 填充 ]</button>
    <button id="zen" class="btn">[ 全屏 ]</button>
  </div>

  <div class="footbar">
    <button id="unpair" class="btn danger">[ 解除配对 ]</button>
    <span id="toast" class="msg"></span>
  </div>
</section>

<script>
(function () {
  "use strict";

  var LS = { token: "pcs.deviceToken", id: "pcs.deviceId", name: "pcs.deviceName" };

  var $ = function (id) { return document.getElementById(id); };
  var el = {
    boot: $("boot"), app: $("app"),
    code: $("code"), devname: $("devname"), pairbtn: $("pairbtn"), bootmsg: $("bootmsg"),
    conn: $("conn"), who: $("who"), shot: $("shot"), empty: $("empty"),
    meta: $("meta"), toast: $("toast"),
    grab: $("grab"), live: $("live"),
    mDisplay: $("m-display"), mWindow: $("m-window"),
    fit: $("fit"), zen: $("zen"), unpair: $("unpair")
  };

  var lastShotID = null;
  var toastTimer = null;

  // ---------------------------------------------------------------- credential
  //
  // A paired device keeps its own token in localStorage. A master token arriving
  // as ?token= is honoured for the page load but never persisted — writing the
  // master credential into a phone's storage would be a downgrade, not a
  // convenience.

  function storedToken() { return localStorage.getItem(LS.token) || ""; }

  function activeToken() {
    if (storedToken()) return storedToken();
    var qs = new URLSearchParams(location.search);
    return qs.get("token") || "";
  }

  function forgetDevice() {
    localStorage.removeItem(LS.token);
    localStorage.removeItem(LS.id);
    localStorage.removeItem(LS.name);
  }

  function withToken(url) {
    return url + (url.indexOf("?") >= 0 ? "&" : "?") + "token=" + encodeURIComponent(activeToken());
  }

  // ------------------------------------------------------------------- helpers

  function say(node, text, kind) {
    node.textContent = text || "";
    node.className = "msg" + (kind ? " " + kind : "");
  }

  function toast(text, kind) {
    say(el.toast, text, kind);
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { say(el.toast, ""); }, 4500);
  }

  async function api(path, options) {
    var response = await fetch(withToken(path), options || {});
    if (response.status === 401 || response.status === 403) {
      if (storedToken()) {
        forgetDevice();
        showBoot("配对已失效，请重新配对。");
        throw new Error("unauthorized");
      }
    }
    var body = null;
    try { body = await response.json(); } catch (_) { body = {}; }
    if (!response.ok) throw new Error(body.error || ("HTTP " + response.status));
    return body;
  }

  // --------------------------------------------------------------------- views

  function showBoot(message) {
    el.app.hidden = true;
    el.boot.hidden = false;
    if (message) say(el.bootmsg, message, "err");
  }

  function showApp() {
    el.boot.hidden = true;
    el.app.hidden = false;

    var label = localStorage.getItem(LS.name) || "";
    el.who.textContent = label;
    el.who.title = label;

    connect();
    refreshStatus();
  }

  // ---------------------------------------------------------------------- shots

  function display(info) {
    if (!info || !info.id || info.id === lastShotID) return;
    lastShotID = info.id;

    var src = withToken("/api/frame/" + info.id + "." + (info.ext || "jpg"));
    var preload = new Image();
    preload.onload = function () {
      el.shot.src = src;
      el.shot.classList.add("show");
      el.empty.hidden = true;
    };
    preload.onerror = function () { toast("图片加载失败", "err"); };
    preload.src = src;

    var kb = Math.round((info.bytes || 0) / 1024);
    var when = (info.createdAt || "").replace("T", " ").replace("Z", "").slice(11, 19);
    el.meta.textContent =
      (info.source || "?") + "  " + info.width + "×" + info.height +
      "  " + kb + "KB  " + when;
  }

  function setButtons(state) {
    if (typeof state.watching === "boolean") {
      el.live.textContent = state.watching ? "[ 连续:开 ]" : "[ 连续:关 ]";
      el.live.classList.toggle("on", state.watching);
    }
    if (state.captureMode) {
      el.mDisplay.classList.toggle("on", state.captureMode === "display");
      el.mWindow.classList.toggle("on", state.captureMode === "window");
    }
  }

  async function refreshStatus() {
    try {
      var status = await api("/api/status");
      setButtons({ watching: status.watching, captureMode: status.capture && status.capture.mode });
    } catch (_) { /* the SSE stream will keep the page honest */ }
  }

  // ----------------------------------------------------------------- live stream

  var stream = null;

  function connect() {
    if (stream) stream.close();
    stream = new EventSource(withToken("/api/events"));

    stream.addEventListener("hello", function (event) {
      var data = JSON.parse(event.data);
      setButtons(data);
      if (data.latest) display(data.latest);
      if (data.granted === false) toast("Mac 端缺少「屏幕录制」权限", "err");
    });

    stream.addEventListener("shot", function (event) {
      display(JSON.parse(event.data));
    });

    stream.addEventListener("watch", function (event) {
      setButtons(JSON.parse(event.data));
    });

    stream.addEventListener("settings", function (event) {
      setButtons(JSON.parse(event.data));
    });

    stream.addEventListener("permission", function (event) {
      if (!JSON.parse(event.data).granted) toast("Mac 端缺少「屏幕录制」权限", "err");
    });

    stream.onopen = function () {
      el.conn.textContent = "● 在线";
      el.conn.classList.add("live");
    };
    stream.onerror = function () {
      el.conn.textContent = "○ 离线";
      el.conn.classList.remove("live");
      // EventSource reconnects by itself; this only reflects the state.
    };
  }

  // ------------------------------------------------------------------- pairing

  async function pair() {
    var code = el.code.value.replace(/\D/g, "");
    if (code.length !== 6) {
      say(el.bootmsg, "配对码是 6 位数字。", "err");
      return;
    }

    el.pairbtn.disabled = true;
    say(el.bootmsg, "连接中…");

    try {
      var response = await fetch("/api/pair", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code: code,
          name: el.devname.value.trim() || defaultDeviceName()
        })
      });
      var body = await response.json();
      if (!response.ok) throw new Error(body.error || ("HTTP " + response.status));

      localStorage.setItem(LS.token, body.deviceToken);
      localStorage.setItem(LS.id, body.device.id);
      localStorage.setItem(LS.name, body.device.name);

      // Drop the code from the URL so a refresh does not try to redeem it again.
      history.replaceState(null, "", location.pathname);
      say(el.bootmsg, "");
      showApp();
    } catch (error) {
      say(el.bootmsg, String(error.message || error), "err");
    } finally {
      el.pairbtn.disabled = false;
    }
  }

  function defaultDeviceName() {
    var ua = navigator.userAgent;
    if (/iPhone/.test(ua)) return "iPhone";
    if (/iPad/.test(ua)) return "iPad";
    if (/Android/.test(ua)) return "Android";
    return "我的手机";
  }

  // ------------------------------------------------------------------- controls

  el.pairbtn.addEventListener("click", pair);
  el.code.addEventListener("input", function () {
    el.code.value = el.code.value.replace(/\D/g, "").slice(0, 6);
    if (el.code.value.length === 6) el.code.blur();
  });
  el.code.addEventListener("keydown", function (event) {
    if (event.key === "Enter") pair();
  });

  el.grab.addEventListener("click", async function () {
    el.grab.disabled = true;
    el.grab.textContent = "[ 截屏中… ]";
    try {
      var body = await api("/api/shot", { method: "POST" });
      display(body.shot);
    } catch (error) {
      if (error.message !== "unauthorized") toast(String(error.message), "err");
    } finally {
      el.grab.disabled = false;
      el.grab.textContent = "[ 截屏 ]";
    }
  });

  el.live.addEventListener("click", async function () {
    try {
      var body = await api("/api/watch/toggle", { method: "POST" });
      setButtons({ watching: body.watching });
      toast(body.watching ? "已开启连续截图" : "已停止连续截图", "ok");
    } catch (error) {
      if (error.message !== "unauthorized") toast(String(error.message), "err");
    }
  });

  function switchMode(mode) {
    return async function () {
      try {
        var body = await api("/api/capture/mode?mode=" + mode, { method: "POST" });
        setButtons({ captureMode: body.captureMode });
        toast(mode === "window" ? "只截当前窗口" : "截取整个屏幕", "ok");
      } catch (error) {
        if (error.message !== "unauthorized") toast(String(error.message), "err");
      }
    };
  }
  el.mDisplay.addEventListener("click", switchMode("display"));
  el.mWindow.addEventListener("click", switchMode("window"));

  el.fit.addEventListener("click", function () {
    var filled = el.shot.classList.toggle("fill");
    el.fit.textContent = filled ? "[ 适应 ]" : "[ 填充 ]";
  });

  el.zen.addEventListener("click", function () {
    document.body.classList.toggle("zen");
  });

  el.unpair.addEventListener("click", async function () {
    if (!confirm("解除这台设备与 Mac 的配对？")) return;
    try { await api("/api/unpair", { method: "POST" }); } catch (_) {}
    forgetDevice();
    showBoot("");
    say(el.bootmsg, "已解除配对。", "ok");
  });

  // ---------------------------------------------------------------------- start

  (function start() {
    // A QR code scanned from the Mac arrives as #pair=123456. It is carried in
    // the fragment on purpose: fragments are not sent to the server, so the code
    // never lands in a request log.
    var match = /(?:^|[#&])pair=(\d{6})/.exec(location.hash || "");
    var hasCredential = !!activeToken();

    if (hasCredential) {
      showApp();
      return;
    }

    el.devname.value = defaultDeviceName();
    showBoot("");

    if (match) {
      el.code.value = match[1];
      pair();
    }
  })();
})();
</script>
</body>
</html>
"""#
}
