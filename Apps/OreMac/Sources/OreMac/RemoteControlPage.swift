import Foundation

enum RemoteControlPage {
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="mobile-web-app-capable" content="yes">
<title>ORE Remote</title>
<style>
:root { color-scheme: dark; --bg:#111114; --card:#1c1c22; --line:#2c2c34; --text:#f4f4f5; --muted:#a1a1aa; --accent:#ece8ff; --ink:#1a1228; }
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; min-height: 100%; background: var(--bg); color: var(--text);
  font: 16px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
body { padding: env(safe-area-inset-top) env(safe-area-inset-right) 0 env(safe-area-inset-left);
  display: flex; flex-direction: column; min-height: 100dvh; }
header { padding: 14px 16px 8px; display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }
h1 { font-size: 13px; letter-spacing: .14em; text-transform: uppercase; margin: 0; opacity: .65; }
#status { font-size: 13px; color: var(--muted); text-align: right; }
.pickers { display: flex; gap: 8px; padding: 0 14px 10px; flex-wrap: wrap; }
select, textarea, button, input { font: inherit; color: inherit; }
select, textarea, input[type=text] { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 12px 14px; }
select { flex: 1; min-width: 140px; min-height: 48px; }
.shell { flex: 1; display: flex; flex-direction: column; gap: 10px; padding: 0 14px;
  max-width: 920px; width: 100%; margin: 0 auto; min-height: 0; }
.log { background: #16161c; border-radius: 16px; padding: 12px 14px; flex: 1;
  min-height: 180px; overflow: auto; -webkit-overflow-scrolling: touch; }
.msg { padding: 10px 0; border-bottom: 1px solid #24242c; white-space: pre-wrap; overflow-wrap: anywhere; }
.msg .who { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin-bottom: 4px; }
.msg.you .who { color: #c4b5fd; }
.msg.tool .who, .msg.activity .who { color: #93c5fd; }
.msg.error .who { color: #fca5a5; }
.msg.queued { opacity: .6; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 14px; }
.card h2 { margin: 0 0 8px; font-size: 15px; }
.card .target { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px;
  white-space: pre-wrap; overflow-wrap: anywhere; color: #e4e4e7; }
.row { display: flex; gap: 8px; flex-wrap: wrap; }
.row button { flex: 1; min-width: 110px; }
button { appearance: none; border: 0; border-radius: 14px; padding: 14px 16px;
  background: var(--accent); color: var(--ink); font-weight: 600; min-height: 48px; }
button.secondary { background: #2a2a32; color: var(--text); }
button.stop { background: #5a1d1d; color: #ffd7d7; }
button:disabled { opacity: .45; }
.composer { padding: 10px 14px calc(12px + env(safe-area-inset-bottom));
  max-width: 920px; width: 100%; margin: 0 auto; }
textarea { width: 100%; min-height: 88px; resize: vertical; margin-bottom: 8px; }
.hint, .busy, .error { font-size: 13px; color: var(--muted); padding: 0 2px 8px; }
.error { color: #fca5a5; padding: 8px 16px; }
.options { display: flex; flex-direction: column; gap: 8px; margin: 10px 0; }
@media (min-width: 700px) {
  .log { min-height: 280px; }
  textarea { min-height: 110px; }
}
</style>
</head>
<body>
<header>
  <h1>ORE</h1>
  <div id="status">Connecting…</div>
</header>
<p class="error" id="error" hidden></p>
<div class="pickers">
  <select id="workspace" aria-label="Workspace"></select>
  <select id="chat" aria-label="Conversation"></select>
  <button class="secondary" id="newchat" type="button">New chat</button>
</div>
<div class="shell">
  <div class="log" id="log"></div>
  <div id="needsyou"></div>
</div>
<div class="composer">
  <div class="busy" id="busy"></div>
  <textarea id="draft" placeholder="Message this agent" enterkeyhint="send"></textarea>
  <div class="row">
    <button id="send">Send</button>
    <button class="stop" id="stop">Stop</button>
  </div>
</div>
<script>
const hashToken = decodeURIComponent((location.hash || "").replace(/^#/, ""));
if (hashToken) try { sessionStorage.setItem("ore-remote-token", hashToken); } catch (e) {}
const token = hashToken || (function(){ try { return sessionStorage.getItem("ore-remote-token") || ""; } catch (e) { return ""; } })();
const headers = () => ({ "Content-Type": "application/json", "X-Ore-Token": token });
const $ = (id) => document.getElementById(id);
let state = { workspaces: [], chats: [], messages: [], permissions: [], questions: [], busy: false };
let stickBottom = true;

async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { ...headers(), ...(options.headers || {}) } });
  if (response.status === 401) throw new Error("This device is not paired. Scan the QR code in ORE Settings again.");
  if (!response.ok) throw new Error(await response.text() || response.statusText);
  if (response.status === 204) return null;
  return response.json();
}

function showError(message) {
  const node = $("error");
  node.hidden = !message;
  node.textContent = message || "";
}

function ids() {
  return { workspaceID: $("workspace").value, chatID: $("chat").value };
}

function renderSelects() {
  const ws = $("workspace");
  const chat = $("chat");
  const selectedWS = ws.value;
  const workspaces = state.workspaces || [];
  ws.innerHTML = workspaces.map(w =>
    `<option value="${escapeAttr(w.id)}">${escapeHtml(w.name)}${w.branch ? " · " + escapeHtml(w.branch) : ""}</option>`
  ).join("");
  if (selectedWS && workspaces.some(w => w.id === selectedWS)) ws.value = selectedWS;
  else if (state.selectedWorkspace) ws.value = state.selectedWorkspace;
  const chats = (state.chats || []).filter(c => c.workspaceID === ws.value);
  const selectedChat = chat.value;
  chat.innerHTML = chats.map(c =>
    `<option value="${escapeAttr(c.id)}">${escapeHtml(c.title)}${c.busy ? " · running" : ""}</option>`
  ).join("");
  if (selectedChat && chats.some(c => c.id === selectedChat)) chat.value = selectedChat;
  else if (state.selectedChat) chat.value = state.selectedChat;
}

function renderLog() {
  const log = $("log");
  const nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 80;
  log.innerHTML = (state.messages || []).map(m => {
    const kind = m.kind || m.role || "agent";
    const who = m.title ? `${kind} · ${m.title}` : kind;
    return `<div class="msg ${kind}${m.queued ? " queued" : ""}"><div class="who">${escapeHtml(who)}</div>${escapeHtml(m.text || "")}</div>`;
  }).join("") || `<div class="busy">No messages yet. Send one to start this conversation.</div>`;
  if (stickBottom || nearBottom) log.scrollTop = log.scrollHeight;
}

function renderNeedsYou() {
  const host = $("needsyou");
  const permissions = state.permissions || [];
  const questions = state.questions || [];
  const parts = [];
  permissions.forEach(p => {
    parts.push(`<div class="card"><h2>${escapeHtml(p.action || "Permission")}</h2>
      ${p.target ? `<div class="target">${escapeHtml(p.target)}</div>` : ""}
      ${p.detail ? `<p class="hint">${escapeHtml(p.detail)}</p>` : ""}
      <div class="row" style="margin-top:10px">
        <button data-allow="${escapeAttr(p.id)}">Allow</button>
        <button class="stop" data-deny="${escapeAttr(p.id)}">Deny</button>
      </div></div>`);
  });
  questions.forEach(q => {
    const options = (q.options || []).map(label =>
      `<button class="secondary" data-answer="${escapeAttr(q.id)}" data-value="${escapeAttr(label)}">${escapeHtml(label)}</button>`
    ).join("");
    parts.push(`<div class="card"><h2>Question</h2><p>${escapeHtml(q.prompt || "")}</p>
      <div class="options">${options}</div>
      ${q.freeform ? `<div class="row"><input type="text" data-free="${escapeAttr(q.id)}" placeholder="Type an answer"><button data-free-send="${escapeAttr(q.id)}">Answer</button></div>` : ""}
      </div>`);
  });
  host.innerHTML = parts.join("");
}

function render() {
  renderSelects();
  renderLog();
  renderNeedsYou();
  const hint = state.queueHint || (state.busy ? "Agent is working…" : "");
  $("busy").textContent = hint;
  $("send").textContent = state.willQueue ? "Queue" : "Send";
  $("stop").disabled = !state.busy && !state.willQueue;
  const extra = state.error ? " · " + state.error : "";
  $("status").textContent = (state.busy ? "Working" : "Live") + " · " + (state.workspaces || []).length + " workspaces" + extra;
}

function escapeHtml(value) {
  return String(value || "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" }[c]));
}
function escapeAttr(value) { return escapeHtml(value); }

async function refresh() {
  try {
    const next = await api("/api/state?workspace=" + encodeURIComponent($("workspace").value) +
      "&chat=" + encodeURIComponent($("chat").value));
    state = next;
    showError("");
    render();
  } catch (error) {
    showError(error.message);
    $("status").textContent = "Disconnected";
  }
}

$("log").addEventListener("scroll", () => {
  const log = $("log");
  stickBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 80;
});
$("workspace").addEventListener("change", async () => {
  await api("/api/select", { method: "POST", body: JSON.stringify({ workspaceID: $("workspace").value }) });
  await refresh();
});
$("chat").addEventListener("change", async () => {
  await api("/api/select", { method: "POST", body: JSON.stringify(ids()) });
  await refresh();
});
$("newchat").addEventListener("click", async () => {
  await api("/api/new-chat", { method: "POST", body: JSON.stringify({ workspaceID: $("workspace").value }) });
  await refresh();
});
$("send").addEventListener("click", send);
$("draft").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); send(); }
});
$("stop").addEventListener("click", async () => {
  await api("/api/stop", { method: "POST", body: JSON.stringify(ids()) });
  await refresh();
});
$("needsyou").addEventListener("click", async (event) => {
  const allow = event.target.closest("[data-allow]");
  const deny = event.target.closest("[data-deny]");
  const option = event.target.closest("[data-answer]");
  const freeSend = event.target.closest("[data-free-send]");
  const payload = ids();
  if (allow) {
    await api("/api/permission", { method: "POST", body: JSON.stringify({ ...payload, requestID: allow.dataset.allow, decision: "allow" }) });
  } else if (deny) {
    await api("/api/permission", { method: "POST", body: JSON.stringify({ ...payload, requestID: deny.dataset.deny, decision: "deny" }) });
  } else if (option) {
    await api("/api/answer", { method: "POST", body: JSON.stringify({ ...payload, questionID: option.dataset.answer, answer: option.dataset.value }) });
  } else if (freeSend) {
    const input = $("needsyou").querySelector(`[data-free="${CSS.escape(freeSend.dataset.freeSend)}"]`);
    const answer = (input && input.value || "").trim();
    if (!answer) return;
    await api("/api/answer", { method: "POST", body: JSON.stringify({ ...payload, questionID: freeSend.dataset.freeSend, answer }) });
  } else {
    return;
  }
  await refresh();
});

async function send() {
  const text = $("draft").value.trim();
  if (!text) return;
  $("draft").value = "";
  await api("/api/send", { method: "POST", body: JSON.stringify({ ...ids(), text }) });
  await refresh();
}

refresh();
setInterval(refresh, 1500);
</script>
</body>
</html>
"""#
}
