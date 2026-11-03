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
<title>ORE</title>
<style>
:root {
  color-scheme: dark;
  --content: #171615;
  --chrome: #14151A;
  --canvas-top: #100F0F;
  --well: #28282A;
  --brand: #F59E0B;
  --brand-ink: #1a1208;
  --hairline: rgba(255,255,255,.075);
  --subdued: rgba(255,255,255,.045);
  --selected: rgba(245,158,11,.13);
  --sidebar-sel: rgba(255,255,255,.09);
  --text: rgba(255,255,255,.92);
  --muted: rgba(255,255,255,.48);
  --dim: rgba(255,255,255,.28);
  --running: #60a5fa;
  --needs: #fb923c;
  --failed: #f87171;
  --prose: 15px;
  --chrome-size: 13px;
  --radius-tab: 8px;
  --radius-control: 10px;
  --radius-pill: 11px;
  --radius-card: 16px;
  --sidebar: 248px;
  --safe-t: env(safe-area-inset-top);
  --safe-b: env(safe-area-inset-bottom);
  --safe-l: env(safe-area-inset-left);
  --safe-r: env(safe-area-inset-right);
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; height: 100%; background: var(--content); color: var(--text);
  font: var(--chrome-size)/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
  overflow: hidden; }
button, select, textarea, input { font: inherit; color: inherit; }
button { appearance: none; border: 0; background: none; cursor: pointer; }
.app { display: flex; height: 100dvh; height: 100svh; background:
  linear-gradient(180deg, var(--canvas-top) 0%, var(--content) 42%); }
.backdrop { display: none; position: fixed; inset: 0; background: rgba(0,0,0,.45); z-index: 20; }
.sidebar {
  width: var(--sidebar); flex: none; background: var(--chrome);
  border-right: 1px solid var(--hairline); display: flex; flex-direction: column;
  padding: calc(12px + var(--safe-t)) 10px calc(12px + var(--safe-b)) calc(10px + var(--safe-l));
  min-height: 0; z-index: 21;
}
.brand { display: flex; align-items: center; gap: 8px; padding: 6px 8px 14px; }
.brand-mark { width: 22px; height: 22px; border-radius: 6px; background: var(--brand);
  color: var(--brand-ink); font-weight: 700; font-size: 11px; letter-spacing: .04em;
  display: grid; place-items: center; }
.brand span { font-size: 11px; letter-spacing: .16em; text-transform: uppercase; color: var(--muted); }
.ws-list { flex: 1; overflow: auto; -webkit-overflow-scrolling: touch; display: flex; flex-direction: column; gap: 2px; }
.ws {
  display: flex; align-items: center; gap: 10px; width: 100%; text-align: left;
  padding: 8px 10px; border-radius: var(--radius-pill); color: var(--text);
}
.ws:hover { background: var(--subdued); }
.ws.sel { background: var(--sidebar-sel); box-shadow: inset 2px 0 0 var(--brand); }
.ws.assistant .mono { background: var(--selected); color: var(--brand); }
.mono {
  width: 28px; height: 28px; border-radius: 9px; flex: none;
  background: rgba(255,255,255,.08); display: grid; place-items: center;
  font-size: 12px; font-weight: 600; color: var(--muted);
}
.ws.sel .mono { background: var(--selected); color: var(--brand); }
.ws-copy { min-width: 0; flex: 1; }
.ws-name { font-weight: 550; font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ws-branch { font-size: 11px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  display: flex; align-items: center; gap: 4px; }
.i { width: 13px; height: 13px; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round;
  stroke-linejoin: round; flex: none; display: inline-block; vertical-align: -2px; }
.i.fill { fill: currentColor; stroke: none; }
.mono .i { width: 14px; height: 14px; }
.dot { width: 7px; height: 7px; border-radius: 50%; flex: none; background: var(--running); }
.dot.needs { background: var(--needs); }
.dot.idle { background: transparent; }
.main { flex: 1; min-width: 0; min-height: 0; display: flex; flex-direction: column; }
.chrome {
  display: flex; align-items: center; gap: 8px;
  padding: calc(8px + var(--safe-t)) calc(12px + var(--safe-r)) 8px 12px;
  border-bottom: 1px solid var(--hairline);
}
.nav-btn, .icon-btn {
  width: 34px; height: 34px; border-radius: var(--radius-tab);
  background: var(--subdued); color: var(--text); display: none; place-items: center; flex: none;
}
.icon-btn { display: grid; }
.tabs { flex: 1; min-width: 0; display: flex; gap: 4px; overflow-x: auto; scrollbar-width: none; }
.tabs::-webkit-scrollbar { display: none; }
.tab {
  flex: none; max-width: 180px; padding: 7px 12px; border-radius: var(--radius-tab);
  color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  font-size: 13px; display: inline-flex; align-items: center; gap: 6px;
}
.tab .i { width: 12px; height: 12px; }
.tab.sel { background: var(--selected); color: var(--text); font-weight: 600; }
.tab.busy::before { content: ""; display: inline-block; width: 6px; height: 6px; margin-right: 6px;
  border-radius: 50%; background: var(--running); vertical-align: middle; }
.status { font-size: 11px; color: var(--muted); flex: none; max-width: 40%; text-align: right; }
.stage { flex: 1; min-height: 0; position: relative; display: flex; flex-direction: column; }
.flow { flex: 1; min-height: 0; position: relative; display: flex; flex-direction: column; }
.log {
  flex: 1; min-height: 0; overflow: auto; -webkit-overflow-scrolling: touch;
  padding: 18px 18px 8px;
}
.col { max-width: 720px; margin: 0 auto; width: 100%; display: flex; flex-direction: column; gap: 16px; }
.empty { color: var(--muted); text-align: center; padding: 64px 24px; font-size: 14px; line-height: 1.5; }
.turn { max-width: 100%; }
.turn.you { display: flex; justify-content: flex-end; }
.header { font-size: 11px; color: var(--dim); margin: 0 0 6px; letter-spacing: .01em;
  display: flex; align-items: center; gap: 6px; }
.bubble {
  max-width: 80%; background: var(--well); border-radius: 16px 16px 6px 16px;
  padding: 10px 14px; font-size: var(--prose); line-height: 1.45; white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.prose { font-size: var(--prose); line-height: 1.55; white-space: pre-wrap; overflow-wrap: anywhere; color: var(--text); }
.prose.live::after { content: "▍"; margin-left: 1px; color: var(--brand); animation: caret 1s steps(1) infinite; }
@keyframes caret { 50% { opacity: 0; } }
.fold {
  display: inline-flex; align-items: center; gap: 4px; margin-top: 8px; padding: 0; border: 0; background: none;
  font-size: 12px; color: var(--muted); cursor: pointer;
}
.process { display: flex; flex-direction: column; align-items: flex-start; gap: 6px; }
.process-toggle {
  display: inline-flex; align-items: center; gap: 8px; max-width: 100%;
  padding: 2px 0; border: 0; background: none; color: var(--muted);
  font-size: 12.5px; cursor: pointer; text-align: left;
}
.process-toggle .chev { width: 10px; color: var(--dim); font-size: 11px; flex: none; }
.process.open > .process-toggle .chev { transform: rotate(90deg); }
.process-toggle .dot {
  width: 6px; height: 6px; border-radius: 50%; background: var(--running);
  flex: none; animation: pulse 1.2s ease-in-out infinite;
}
.process-toggle .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
@keyframes pulse { 50% { opacity: .35; } }
.steps {
  display: flex; flex-direction: column; gap: 8px;
  width: 100%; margin: 2px 0 4px 6px; padding-left: 12px;
  border-left: 1px solid var(--hairline);
}
.tool-body { font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--dim);
  white-space: pre-wrap; overflow-wrap: anywhere; padding: 2px 0 4px; max-width: 100%; }
.thinking { font-size: 13px; color: var(--muted); font-style: italic; white-space: pre-wrap; overflow-wrap: anywhere; }
.error-row { color: var(--failed); font-size: var(--prose); white-space: pre-wrap; }
.plan { background: var(--subdued); border: 1px solid var(--hairline); border-radius: var(--radius-card);
  padding: 12px 14px; white-space: pre-wrap; font-size: var(--prose); }
.queued { opacity: .55; }
.jump {
  position: absolute; right: 16px; bottom: 12px; display: none; z-index: 3;
  min-height: 32px; padding: 0 12px; border-radius: 999px;
  background: var(--well); border: 1px solid var(--hairline); color: var(--text);
  font-size: 12px; box-shadow: 0 8px 24px rgba(0,0,0,.35);
}
.jump.show { display: inline-flex; align-items: center; gap: 6px; }
.dock {
  padding: 8px 14px calc(10px + var(--safe-b));
  background: linear-gradient(180deg, transparent, var(--content) 28%);
}
.dock-inner { max-width: 720px; margin: 0 auto; display: flex; flex-direction: column; gap: 8px; }
.card {
  background: var(--well); border: 1px solid var(--hairline); border-radius: var(--radius-card);
  padding: 14px;
}
.card h2 { margin: 0 0 6px; font-size: 15px; font-weight: 600; display: flex; align-items: center; gap: 8px; }
.card .target { font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--text);
  white-space: pre-wrap; overflow-wrap: anywhere; }
.hint { margin: 8px 0 0; color: var(--muted); font-size: 12px; }
.actions { display: flex; gap: 8px; margin-top: 12px; flex-wrap: wrap; }
.options { display: flex; flex-direction: column; gap: 8px; margin-top: 10px; }
.composer {
  display: flex; align-items: flex-end; gap: 8px; flex-wrap: wrap;
  background: var(--well); border: 1px solid var(--hairline); border-radius: var(--radius-card);
  padding: 8px 8px 8px 14px;
}
.composer-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; }
.toolbar { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.chip, .chip-btn {
  display: inline-flex; align-items: center; gap: 5px;
  appearance: none; -webkit-appearance: none;
  background: var(--subdued); border: 1px solid var(--hairline); border-radius: 999px;
  padding: 4px 10px 4px 8px; font-size: 11px; color: var(--text); max-width: 180px;
}
.chip .i, .chip-btn .i { color: var(--muted); width: 12px; height: 12px; }
.chip select {
  appearance: none; -webkit-appearance: none;
  border: 0; background: transparent; padding: 0; max-width: 148px;
}
.chip-btn.on { background: var(--selected); color: var(--brand); border-color: rgba(245,158,11,.35); }
.chip-btn.on .i { color: var(--brand); }
.meter { font-size: 11px; color: var(--muted); margin-left: auto; padding: 0 4px;
  display: inline-flex; align-items: center; gap: 4px; }
textarea {
  width: 100%; min-height: 44px; max-height: 160px; resize: none; border: 0; background: transparent;
  padding: 8px 0; outline: none; font-size: var(--prose); line-height: 1.4;
}
.primary, .ghost, .danger {
  min-height: 36px; padding: 0 16px; border-radius: 999px; font-weight: 600; font-size: 13px;
  display: inline-flex; align-items: center; gap: 6px;
}
.empty .i { width: 28px; height: 28px; color: var(--dim); margin-bottom: 10px; display: block; margin-left: auto; margin-right: auto; }
.primary { background: var(--brand); color: var(--brand-ink); }
.ghost { background: rgba(255,255,255,.08); color: var(--text); }
.danger { background: rgba(248,113,113,.16); color: #fecaca; }
button:disabled { opacity: .4; }
.banner { font-size: 12px; color: var(--muted); padding: 0 4px; display: flex; align-items: center; gap: 6px; }
.banner.fail { color: var(--failed); }
.error-bar { display: none; margin: 0; padding: 8px 16px; color: var(--failed); font-size: 13px; }
.error-bar.show { display: block; }
#stop:disabled { display: none; }
@media (max-width: 839px) {
  .nav-btn { display: grid; }
  .sidebar {
    position: fixed; inset: 0 auto 0 0; transform: translateX(-105%);
    transition: transform .2s ease; box-shadow: 12px 0 40px rgba(0,0,0,.4);
  }
  .app.nav-open .sidebar { transform: none; }
  .app.nav-open .backdrop { display: block; }
  .status { display: none; }
}
</style>
</head>
<body>
<div class="app" id="app">
  <div class="backdrop" id="backdrop"></div>
  <aside class="sidebar" id="sidebar">
    <div class="brand"><div class="brand-mark">ORE</div><span>Workspaces</span></div>
    <div class="ws-list" id="workspaces"></div>
  </aside>
  <section class="main">
    <header class="chrome">
      <button class="nav-btn" id="nav" type="button" aria-label="Workspaces">
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M2 4h12M2 8h12M2 12h12" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
      </button>
      <div class="tabs" id="tabs"></div>
      <button class="icon-btn" id="newchat" type="button" aria-label="New chat" title="New chat">
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M7 2v10M2 7h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
      </button>
      <div class="status" id="status">Connecting…</div>
    </header>
    <p class="error-bar" id="error"></p>
    <div class="stage">
      <div class="flow">
      <div class="log" id="log"></div>
      <button type="button" class="jump" id="jump">
        <svg class="i" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 3.5v9M4.5 9.5L8 12.5 11.5 9.5"/></svg>
        Latest
      </button>
      </div>
      <div class="dock"><div class="dock-inner">
        <div id="needsyou"></div>
        <div class="banner" id="busy"></div>
        <div class="composer">
          <div class="composer-main">
            <div class="toolbar" id="toolbar">
              <label class="chip" title="Agent">
                <svg class="i" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 12.5V5.2L8 2.5l5 2.7v7.3L8 15.2z"/><path d="M8 8.2v6.5M3 5.2l5 3 5-3"/></svg>
                <select id="harness" aria-label="Agent"></select>
              </label>
              <label class="chip" title="Model">
                <svg class="i" viewBox="0 0 16 16" aria-hidden="true"><rect x="2.5" y="2.5" width="11" height="11" rx="2"/><path d="M6 2.5v11M10 2.5v11M2.5 6h11M2.5 10h11"/></svg>
                <select id="model" aria-label="Model"></select>
              </label>
              <label class="chip" id="effort-chip" hidden title="Effort">
                <svg class="i" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 12V8M7 12V5M11 12V3"/></svg>
                <select id="effort" aria-label="Effort"></select>
              </label>
              <label class="chip" title="Permissions">
                <svg class="i" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5l5 2v3.7c0 3.1-2.1 5.3-5 6.3-2.9-1-5-3.2-5-6.3V4.5z"/></svg>
                <select id="permission" aria-label="Permissions"></select>
              </label>
              <button type="button" class="chip-btn" id="fast" hidden>
                <svg class="i fill" viewBox="0 0 16 16" aria-hidden="true"><path d="M9 1.5L4 9h4l-1 5.5L13 7H9z"/></svg>
                <span id="fast-label">Fast</span>
              </button>
              <span class="meter" id="meter"></span>
            </div>
            <textarea id="draft" rows="1" placeholder="Message this agent" enterkeyhint="send"></textarea>
          </div>
          <button class="danger" id="stop" type="button" disabled>
            <svg class="i fill" viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="4" width="8" height="8" rx="1.2"/></svg>
            Stop
          </button>
          <button class="primary" id="send" type="button">
            <svg class="i" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 12.5V3.5M4.5 7L8 3.5 11.5 7"/></svg>
            <span id="send-label">Send</span>
          </button>
        </div>
      </div></div>
    </div>
  </section>
</div>
<script>
const hashToken = decodeURIComponent((location.hash || "").replace(/^#/, ""));
if (hashToken) try { sessionStorage.setItem("ore-remote-token", hashToken); } catch (e) {}
const token = hashToken || (function(){ try { return sessionStorage.getItem("ore-remote-token") || ""; } catch (e) { return ""; } })();
const headers = () => ({ "Content-Type": "application/json", "X-Ore-Token": token });
const $ = (id) => document.getElementById(id);
let state = { workspaces: [], chats: [], messages: [], permissions: [], questions: [], busy: false };
let followBottom = true;
let userScrolling = false;
let selectedWorkspace = "";
let selectedChat = "";
let expanded = new Set();
let collapsedResponses = new Set();
let didSeedCollapse = false;
let boundChat = "";
let scrollEndTimer = 0;

async function api(path, options = {}) {
  const response = await fetch(path, { ...options, headers: { ...headers(), ...(options.headers || {}) } });
  if (response.status === 401) throw new Error("This device is not paired. Scan the QR code in ORE Settings again.");
  if (!response.ok) throw new Error(await response.text() || response.statusText);
  if (response.status === 204) return null;
  return response.json();
}

function showError(message) {
  const node = $("error");
  node.textContent = message || "";
  node.classList.toggle("show", !!message);
}

function ids() {
  return { workspaceID: selectedWorkspace, chatID: selectedChat };
}

function closeNav() { $("app").classList.remove("nav-open"); }

function monogram(name) {
  const text = (name || "?").trim();
  return (text[0] || "?").toUpperCase();
}

function clip(text, n) {
  const value = String(text || "");
  return value.length > n ? value.slice(0, n) + "…" : value;
}

function icon(name) {
  const paths = {
    sparkle: '<path class="fill" d="M8 1.5l.85 4.15L13 6.5l-4.15.85L8 11.5l-.85-4.15L3 6.5l4.15-.85z"/>',
    folder: '<path d="M2.5 5.2h4.1l1.3 1.5H13.5v6.8H2.5z"/><path d="M2.5 5.2V3.8h3.6l.8 1.4"/>',
    branch: '<path d="M4.5 3.5v9M4.5 8.5c3 0 4.5-1 6.5-3v-2"/><circle cx="4.5" cy="3.5" r="1.3"/><circle cx="4.5" cy="12.5" r="1.3"/><circle cx="11" cy="3.5" r="1.3"/>',
    wrench: '<path d="M10.2 3.2a3 3 0 0 0-4 4L3 10.4 5.6 13l3.2-3.2a3 3 0 0 0 4-4L11 7.5 8.5 5z"/>',
    brain: '<path d="M5.2 5.2a2.2 2.2 0 0 1 2.6-2 2.2 2.2 0 0 1 3 1.6 2 2 0 0 1 1.5 2.2 2.2 2.2 0 0 1-1.4 2.4v1.8H6.3V9.4A2.2 2.2 0 0 1 5.2 7c0-.7.2-1.3.6-1.8z"/><path d="M8 5.5v6"/>',
    list: '<path d="M6 4h7.5M6 8h7.5M6 12h7.5"/><circle cx="3.4" cy="4" r=".9"/><circle cx="3.4" cy="8" r=".9"/><circle cx="3.4" cy="12" r=".9"/>',
    check: '<path d="M3.5 8.3L6.4 11.2 12.5 5"/>',
    x: '<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>',
    down: '<path d="M8 3.5v9M4.5 9.5L8 12.5 11.5 9.5"/>',
    up: '<path d="M8 12.5V3.5M4.5 7L8 3.5 11.5 7"/>',
    bubble: '<path d="M3 4.2h10a1.5 1.5 0 0 1 1.5 1.5v5.1A1.5 1.5 0 0 1 13 12.3H7.2L4 14.2v-1.9H3A1.5 1.5 0 0 1 1.5 10.8V5.7A1.5 1.5 0 0 1 3 4.2z"/>',
    warn: '<path d="M8 2.8 14.2 13.5H1.8z"/><path d="M8 6.5v3.2M8 11.4h.01"/>',
    plan: '<path d="M4.5 2.8h7v10.4h-7z"/><path d="M6.2 5.5h3.6M6.2 8h3.6M6.2 10.5h2.2"/>',
    shield: '<path d="M8 2.5l5 2v3.7c0 3.1-2.1 5.3-5 6.3-2.9-1-5-3.2-5-6.3V4.5z"/>',
    meter: '<path d="M8 13.2A5.2 5.2 0 1 1 13.2 8"/><path d="M8 8l3-3"/>',
    bolt: '<path class="fill" d="M9 1.5L4 9h4l-1 5.5L13 7H9z"/>'
  };
  const d = paths[name];
  if (!d) return "";
  const fill = name === "sparkle" || name === "bolt" || d.includes('class="fill"') ? " fill" : "";
  return `<svg class="i${fill}" viewBox="0 0 16 16" aria-hidden="true">${d}</svg>`;
}

function renderWorkspaces() {
  const host = $("workspaces");
  const workspaces = state.workspaces || [];
  host.innerHTML = workspaces.map(w => {
    const sel = w.id === selectedWorkspace ? " sel" : "";
    const assistant = w.kind === "assistant" ? " assistant" : "";
    const needs = w.needsYou ? " needs" : "";
    const busyChat = (state.chats || []).some(c => c.workspaceID === w.id && c.busy);
    const dot = w.needsYou ? "needs" : busyChat ? "" : "idle";
    const mark = w.kind === "assistant" ? icon("sparkle") : `<span>${escapeHtml(monogram(w.name))}</span>`;
    return `<button type="button" class="ws${sel}${assistant}" data-ws="${escapeAttr(w.id)}">
      <div class="mono">${mark}</div>
      <div class="ws-copy">
        <div class="ws-name">${escapeHtml(w.name)}</div>
        ${w.branch ? `<div class="ws-branch">${icon("branch")}${escapeHtml(w.branch)}</div>` : ""}
      </div>
      <span class="dot ${dot}${needs}"></span>
    </button>`;
  }).join("") || `<div class="empty">${icon("folder")}No workspaces yet.</div>`;
}

function renderTabs() {
  const host = $("tabs");
  const chats = (state.chats || []).filter(c => c.workspaceID === selectedWorkspace);
  host.innerHTML = chats.map(c => {
    const sel = c.id === selectedChat ? " sel" : "";
    const busy = c.busy ? " busy" : "";
    return `<button type="button" class="tab${sel}${busy}" data-chat="${escapeAttr(c.id)}">${icon("bubble")}${escapeHtml(c.title || "Chat")}</button>`;
  }).join("");
}

function formatTime(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function isLong(text) {
  const value = String(text || "");
  if (value.length > 2200) return true;
  let lines = 0;
  for (let i = 0; i < value.length; i++) {
    if (value.charCodeAt(i) === 10 && ++lines > 28) return true;
  }
  return false;
}

function preview(text) {
  const value = String(text || "");
  const lines = value.split("\n");
  if (lines.length > 8) return lines.slice(0, 8).join("\n") + "…";
  if (value.length > 700) return value.slice(0, 700) + "…";
  return value;
}

function resetTranscript() {
  expanded = new Set();
  collapsedResponses = new Set();
  didSeedCollapse = false;
  followBottom = true;
  userScrolling = false;
}

function seedCollapse(messages) {
  if (didSeedCollapse || !messages.length) return;
  didSeedCollapse = true;
  const lastTurn = messages[messages.length - 1].turn;
  messages.forEach(m => {
    if (m.kind === "agent" && m.complete && m.turn !== lastTurn && isLong(m.text)) {
      collapsedResponses.add(m.id);
    }
  });
}

function heading(m) {
  if (!m.header) return "";
  const time = formatTime(m.at);
  return `<div class="header">${icon("sparkle")}${escapeHtml(m.header)}${time ? " · " + escapeHtml(time) : ""}</div>`;
}

function processRow(m) {
  const open = expanded.has(m.id);
  const live = !m.complete;
  const label = m.title || (m.kind === "thinking" ? "Thinking" : m.kind === "activity" ? "Activity" : "Tool");
  const kindIcon = m.kind === "thinking" ? "brain" : m.kind === "activity" ? "list" : m.kind === "error" ? "warn" : "wrench";
  const chev = m.expandable ? `<span class="chev">›</span>` : "";
  const pulse = live ? `<span class="dot"></span>` : "";
  let body = "";
  if (open) {
    if (m.kind === "activity") {
      const steps = (m.steps || []).map(processRow).join("");
      body = steps ? `<div class="steps">${steps}</div>` : "";
    } else if (m.kind === "thinking") {
      body = m.text ? `<div class="thinking">${escapeHtml(m.text)}</div>` : "";
    } else if (m.detail || m.text) {
      body = `<div class="tool-body">${escapeHtml(m.detail || m.text)}</div>`;
    }
  } else if (m.kind === "thinking" && live && m.text) {
    body = `<div class="thinking">${escapeHtml(clip(m.text, 280))}</div>`;
  }
  const toggle = m.expandable
    ? `<button type="button" class="process-toggle" data-expand="${escapeAttr(m.id)}">${chev}${pulse}${icon(kindIcon)}<span class="label">${escapeHtml(label)}</span></button>`
    : `<div class="process-toggle">${pulse}${icon(kindIcon)}<span class="label">${escapeHtml(label)}</span></div>`;
  return `<div class="process${open ? " open" : ""}" data-id="${escapeAttr(m.id)}">${toggle}${body}</div>`;
}

function renderMessage(m) {
  const kind = m.kind || "agent";
  const queued = m.queued ? " queued" : "";
  const id = escapeAttr(m.id || "");
  if (kind === "you") {
    return `<div class="turn you${queued}" data-id="${id}"><div class="bubble">${escapeHtml(m.text || "")}</div></div>`;
  }
  if (kind === "tool" || kind === "activity" || kind === "thinking") {
    return `<div class="turn${queued}" data-id="${id}">${heading(m)}${processRow(m)}</div>`;
  }
  if (kind === "error") {
    const open = expanded.has(m.id);
    const detail = open && (m.detail || m.text)
      ? `<div class="tool-body">${escapeHtml(m.detail || m.text)}</div>` : "";
    return `<div class="turn error-row${queued}" data-id="${id}">
      <button type="button" class="process-toggle" data-expand="${id}">${icon("warn")}${escapeHtml(m.title || "Error")}</button>
      ${detail || `<div>${escapeHtml(m.text || "Something went wrong")}</div>`}
    </div>`;
  }
  if (kind === "plan") {
    return `<div class="turn plan${queued}" data-id="${id}">${heading(m)}${icon("plan")}${escapeHtml(m.text || "")}</div>`;
  }
  const folded = collapsedResponses.has(m.id) && isLong(m.text);
  const live = !m.complete;
  const body = folded ? preview(m.text) : (m.text || "");
  const toggle = isLong(m.text) && m.complete
    ? `<button type="button" class="fold" data-fold="${id}">${icon("down")}${folded ? "Show full response" : "Hide full response"}</button>`
    : "";
  return `<div class="turn${queued}" data-id="${id}">${heading(m)}<div class="prose${live ? " live" : ""}">${escapeHtml(body)}</div>${toggle}</div>`;
}

function atBottom(log) {
  return log.scrollHeight - log.scrollTop - log.clientHeight < 80;
}

function syncJump() {
  $("jump").classList.toggle("show", !followBottom);
}

function pinLog(log) {
  if (followBottom && !userScrolling) log.scrollTop = log.scrollHeight;
  syncJump();
}

function renderLog() {
  const log = $("log");
  const messages = state.messages || [];
  if (selectedChat !== boundChat) {
    boundChat = selectedChat;
    resetTranscript();
    log.dataset.structure = "";
  }
  seedCollapse(messages);
  if (!messages.length) {
    log.innerHTML = `<div class="empty">${icon("bubble")}No messages yet.<br>Send one to start this conversation.</div>`;
    log.dataset.structure = "";
    pinLog(log);
    return;
  }
  const expandKey = [...expanded].sort().join(",") + "/" + [...collapsedResponses].sort().join(",");
  const ids = messages.map(m => m.id).join("\n");
  const structure = ids + "|" + expandKey;
  const last = messages[messages.length - 1];
  const lastNode = last && log.querySelector(`[data-id="${CSS.escape(last.id)}"]`);
  if (log.dataset.structure === structure && lastNode) {
    const prose = lastNode.querySelector(".prose");
    const thinking = lastNode.querySelector(".thinking");
    const label = lastNode.querySelector(".process-toggle .label");
    if (prose) {
      prose.textContent = last.text || "";
      prose.classList.toggle("live", !last.complete);
    } else if (thinking) {
      thinking.textContent = last.text || "";
    } else if (label && last.title) {
      label.textContent = last.title;
    }
  } else {
    const top = log.scrollTop;
    log.dataset.structure = structure;
    log.innerHTML = `<div class="col">${messages.map(renderMessage).join("")}</div>`;
    if (!followBottom) log.scrollTop = top;
  }
  pinLog(log);
}

function renderNeedsYou() {
  const host = $("needsyou");
  const parts = [];
  (state.permissions || []).forEach(p => {
    parts.push(`<div class="card"><h2>${icon("shield")}${escapeHtml(p.action || "Permission")}</h2>
      ${p.target ? `<div class="target">${escapeHtml(p.target)}</div>` : ""}
      ${p.detail ? `<p class="hint">${escapeHtml(p.detail)}</p>` : ""}
      <div class="actions">
        <button type="button" class="primary" data-allow="${escapeAttr(p.id)}">${icon("check")} Allow</button>
        <button type="button" class="ghost" data-deny="${escapeAttr(p.id)}">${icon("x")} Deny</button>
      </div></div>`);
  });
  (state.questions || []).forEach(q => {
    const options = (q.options || []).map(label =>
      `<button type="button" class="ghost" data-answer="${escapeAttr(q.id)}" data-value="${escapeAttr(label)}">${escapeHtml(label)}</button>`
    ).join("");
    parts.push(`<div class="card"><h2>${icon("bubble")} Question</h2><p class="prose">${escapeHtml(q.prompt || "")}</p>
      <div class="options">${options}</div>
      ${q.freeform ? `<div class="actions"><input type="text" data-free="${escapeAttr(q.id)}" placeholder="Type an answer" style="flex:1;min-height:36px;background:var(--subdued);border:1px solid var(--hairline);border-radius:999px;padding:0 14px"><button type="button" class="primary" data-free-send="${escapeAttr(q.id)}">${icon("check")} Answer</button></div>` : ""}
      </div>`);
  });
  host.innerHTML = parts.join("");
}

function resizeDraft() {
  const node = $("draft");
  node.style.height = "auto";
  node.style.height = Math.min(node.scrollHeight, 160) + "px";
}

function fillSelect(node, options, selected) {
  const key = options.map(o => o.id + ":" + o.name).join("|") + "#" + (selected || "");
  if (node.dataset.key === key && (!selected || node.value === selected)) return;
  node.dataset.key = key;
  node.innerHTML = options.map(o =>
    `<option value="${escapeAttr(o.id)}"${o.id === selected ? " selected" : ""}>${escapeHtml(o.name)}</option>`
  ).join("");
  if (selected) node.value = selected;
}

function renderComposer() {
  const c = state.composer || {};
  const focused = document.activeElement && document.activeElement.id;
  const harnesses = c.harnesses || [];
  if (focused !== "harness") {
    fillSelect($("harness"), harnesses.map(h => ({ id: h.id, name: h.name })), c.harness);
  }
  const current = harnesses.find(h => h.id === ($("harness").value || c.harness)) || harnesses[0];
  const models = (current && current.models) || [];
  if (focused !== "model") {
    fillSelect($("model"), models.map(m => ({ id: m.id, name: m.name })), c.model || (models[0] && models[0].id));
  }
  const efforts = c.efforts || [];
  const effort = $("effort");
  const effortChip = $("effort-chip");
  if (effortChip) effortChip.hidden = !efforts.length;
  effort.hidden = !efforts.length;
  if (efforts.length && focused !== "effort") fillSelect(effort, efforts, c.effort);
  if (focused !== "permission") {
    fillSelect($("permission"), c.permissionModes || [], c.permissionMode);
  }
  const fast = $("fast");
  fast.hidden = !c.supportsFast;
  if (focused !== "fast") {
    fast.classList.toggle("on", !!c.fast);
    const label = $("fast-label");
    if (label) label.textContent = c.fast ? "Fast" : "Standard";
  }
  const meter = $("meter");
  meter.innerHTML = c.context ? icon("meter") + escapeHtml(c.context) : "";
  const ws = (state.workspaces || []).find(w => w.id === selectedWorkspace);
  $("draft").placeholder = ws && ws.kind === "assistant" ? "Message Assistant" : "Message this agent";
}

function render() {
  if (!selectedWorkspace && state.selectedWorkspace) selectedWorkspace = state.selectedWorkspace;
  if (!selectedChat && state.selectedChat) selectedChat = state.selectedChat;
  if (selectedWorkspace && !(state.workspaces || []).some(w => w.id === selectedWorkspace)) {
    selectedWorkspace = state.selectedWorkspace || (state.workspaces[0] && state.workspaces[0].id) || "";
  }
  const chats = (state.chats || []).filter(c => c.workspaceID === selectedWorkspace);
  if (selectedChat && !chats.some(c => c.id === selectedChat)) {
    selectedChat = state.selectedChat || (chats[0] && chats[0].id) || "";
  }
  renderWorkspaces();
  renderTabs();
  renderLog();
  renderNeedsYou();
  renderComposer();
  const hint = state.queueHint || (state.busy ? "Agent is working…" : "");
  const busy = $("busy");
  busy.className = "banner" + (state.error ? " fail" : "");
  if (hint) busy.innerHTML = icon("bolt") + escapeHtml(hint);
  else if (state.error) busy.innerHTML = icon("warn") + escapeHtml(state.error);
  else busy.textContent = "";
  const sendLabel = $("send-label");
  if (sendLabel) sendLabel.textContent = state.willQueue ? "Queue" : "Send";
  $("stop").disabled = !state.busy && !state.willQueue;
  const ws = (state.workspaces || []).find(w => w.id === selectedWorkspace);
  $("status").textContent = state.busy ? "Working" : (ws ? ws.name : "Live");
}

function escapeHtml(value) {
  return String(value || "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" }[c]));
}
function escapeAttr(value) { return escapeHtml(value); }

async function refresh() {
  try {
    const next = await api("/api/state?workspace=" + encodeURIComponent(selectedWorkspace) +
      "&chat=" + encodeURIComponent(selectedChat));
    state = next;
    showError("");
    render();
  } catch (error) {
    showError(error.message);
    $("status").textContent = "Disconnected";
  }
}

async function selectWorkspace(id) {
  selectedWorkspace = id;
  selectedChat = "";
  closeNav();
  await api("/api/select", { method: "POST", body: JSON.stringify({ workspaceID: id }) });
  await refresh();
}

async function selectChat(id) {
  selectedChat = id;
  await api("/api/select", { method: "POST", body: JSON.stringify(ids()) });
  await refresh();
}

function markScrolling() {
  userScrolling = true;
  followBottom = atBottom($("log"));
  syncJump();
  clearTimeout(scrollEndTimer);
  scrollEndTimer = setTimeout(() => {
    userScrolling = false;
    followBottom = atBottom($("log"));
    syncJump();
  }, 160);
}
$("log").addEventListener("scroll", markScrolling, { passive: true });
$("log").addEventListener("touchstart", () => { userScrolling = true; }, { passive: true });
$("log").addEventListener("click", (event) => {
  const fold = event.target.closest("[data-fold]");
  const proc = event.target.closest("[data-expand]");
  if (fold) {
    const id = fold.dataset.fold;
    if (collapsedResponses.has(id)) collapsedResponses.delete(id);
    else collapsedResponses.add(id);
    renderLog();
    return;
  }
  if (proc) {
    const id = proc.dataset.expand;
    if (expanded.has(id)) expanded.delete(id);
    else expanded.add(id);
    renderLog();
  }
});
$("jump").addEventListener("click", () => {
  followBottom = true;
  userScrolling = false;
  $("log").scrollTop = $("log").scrollHeight;
  syncJump();
});
$("nav").addEventListener("click", () => $("app").classList.toggle("nav-open"));
$("backdrop").addEventListener("click", closeNav);
$("workspaces").addEventListener("click", (event) => {
  const row = event.target.closest("[data-ws]");
  if (row) selectWorkspace(row.dataset.ws);
});
$("tabs").addEventListener("click", (event) => {
  const tab = event.target.closest("[data-chat]");
  if (tab) selectChat(tab.dataset.chat);
});
$("newchat").addEventListener("click", async () => {
  await api("/api/new-chat", { method: "POST", body: JSON.stringify({ workspaceID: selectedWorkspace }) });
  await refresh();
});
$("send").addEventListener("click", send);
$("draft").addEventListener("input", resizeDraft);
$("draft").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); send(); }
});
$("stop").addEventListener("click", async () => {
  await api("/api/stop", { method: "POST", body: JSON.stringify(ids()) });
  await refresh();
});
async function pushComposer() {
  await api("/api/composer", { method: "POST", body: JSON.stringify({
    ...ids(),
    harness: $("harness").value,
    model: $("model").value,
    effort: $("effort").hidden ? "" : $("effort").value,
    permissionMode: $("permission").value,
    fast: $("fast").classList.contains("on") ? "1" : ""
  }) });
  await refresh();
}
$("harness").addEventListener("change", () => {
  const harnesses = (state.composer && state.composer.harnesses) || [];
  const h = harnesses.find(x => x.id === $("harness").value);
  const models = (h && h.models) || [];
  const preferred = models.find(m => m.default) || models[0];
  fillSelect($("model"), models.map(m => ({ id: m.id, name: m.name })), preferred && preferred.id);
  pushComposer();
});
$("model").addEventListener("change", pushComposer);
$("effort").addEventListener("change", pushComposer);
$("permission").addEventListener("change", pushComposer);
$("fast").addEventListener("click", () => {
  $("fast").classList.toggle("on");
  const label = $("fast-label");
  if (label) label.textContent = $("fast").classList.contains("on") ? "Fast" : "Standard";
  pushComposer();
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
  resizeDraft();
  followBottom = true;
  await api("/api/send", { method: "POST", body: JSON.stringify({
    ...ids(),
    text,
    effort: $("effort").hidden ? "" : $("effort").value,
    fast: $("fast").classList.contains("on") ? "1" : ""
  }) });
  await refresh();
}

refresh();
setInterval(refresh, 1500);
</script>
</body>
</html>
"""#
}
