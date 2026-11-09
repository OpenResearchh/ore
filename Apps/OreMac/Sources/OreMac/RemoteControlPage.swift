import AppKit
import Foundation

enum RemoteControlPage {
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="ORE">
<meta name="theme-color" content="#14151A">
<meta name="format-detection" content="telephone=no">
<title>ORE</title>
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="icon" type="image/png" href="/favicon.png">
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
  --inspector: 300px;
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
.main { flex: 1; min-width: 0; min-height: 0; display: flex; flex-direction: column; position: relative; }
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
  flex: none; max-width: 200px; padding: 7px 8px 7px 12px; border-radius: var(--radius-tab);
  color: var(--muted); white-space: nowrap; font-size: 13px;
  display: inline-flex; align-items: center; gap: 6px;
}
.tab .title { overflow: hidden; text-overflow: ellipsis; }
.tab .i { width: 12px; height: 12px; }
.tab.sel { background: var(--selected); color: var(--text); font-weight: 600; }
.tab.busy::before { content: ""; display: inline-block; width: 6px; height: 6px;
  border-radius: 50%; background: var(--running); }
.tab.unread .title { color: var(--text); }
.tab-close {
  width: 18px; height: 18px; border-radius: 6px; color: var(--dim);
  display: grid; place-items: center; flex: none;
}
.tab-close:hover { background: rgba(255,255,255,.08); color: var(--text); }
.status {
  font-size: 11px; color: var(--muted); flex: none; display: inline-flex; align-items: center; gap: 6px;
}
.status .live-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--dim); }
.status.ok .live-dot { background: #34d399; }
.status.wait .live-dot { background: var(--needs); animation: pulse 1.2s ease-in-out infinite; }
.status.bad .live-dot { background: var(--failed); }
.stage { flex: 1; min-height: 0; position: relative; display: flex; min-width: 0; }
.chat-col { flex: 1; min-width: 0; min-height: 0; display: flex; flex-direction: column; position: relative; }
.flow { flex: 1; min-height: 0; position: relative; display: flex; flex-direction: column; }
.log {
  flex: 1; min-height: 0; overflow: auto; -webkit-overflow-scrolling: touch;
  padding: 18px 18px 8px;
}
.col { max-width: 720px; margin: 0 auto; width: 100%; display: flex; flex-direction: column; gap: 16px; }
.empty { color: var(--muted); text-align: center; padding: 64px 24px; font-size: 14px; line-height: 1.5; }
.turn { max-width: 100%; position: relative; }
.turn.you { display: flex; justify-content: flex-end; }
.header { font-size: 11px; color: var(--dim); margin: 0 0 6px; letter-spacing: .01em;
  display: flex; align-items: center; gap: 6px; }
.bubble {
  max-width: 80%; background: var(--well); border-radius: 16px 16px 6px 16px;
  padding: 10px 14px; font-size: var(--prose); line-height: 1.45; white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.quote {
  display: flex; gap: 8px; margin: 0 0 8px; padding: 0 0 0 8px;
  border-left: 2px solid var(--brand); color: var(--muted); font-size: 12px;
}
.prose { font-size: var(--prose); line-height: 1.55; white-space: pre-wrap; overflow-wrap: anywhere; color: var(--text); }
.prose.live::after { content: "▍"; margin-left: 1px; color: var(--brand); animation: caret 1s steps(1) infinite; }
.prose code, .bubble code {
  font: 12.5px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
  background: rgba(255,255,255,.06); padding: 1px 5px; border-radius: 6px;
}
.prose a, .bubble a { color: var(--brand); text-decoration: none; }
@keyframes caret { 50% { opacity: 0; } }
.fold {
  display: inline-flex; align-items: center; gap: 4px; margin-top: 8px; padding: 0; border: 0; background: none;
  font-size: 12px; color: var(--muted); cursor: pointer;
}
.reply-btn {
  position: absolute; top: 0; opacity: .7; width: 28px; height: 28px; border-radius: 8px;
  background: var(--well); color: var(--muted); display: grid; place-items: center;
}
.turn.you .reply-btn { left: 0; }
.turn:not(.you) .reply-btn { right: 0; }
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
  max-width: 100%; min-width: 0;
}
.dock-inner { max-width: min(720px, 100%); width: 100%; margin: 0 auto; display: flex; flex-direction: column; gap: 8px; min-width: 0; }
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
  padding: 8px 8px 8px 14px; width: 100%; max-width: 100%; min-width: 0;
}
.composer-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; }
.composer-actions { display: flex; justify-content: flex-end; gap: 8px; padding: 0 4px 2px; }
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
.reply-bar {
  display: none; align-items: center; gap: 8px; padding: 6px 8px;
  background: var(--subdued); border-radius: 10px; color: var(--muted); font-size: 12px;
}
.reply-bar.show { display: flex; }
.reply-bar .quote { margin: 0; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
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
.inspector {
  width: var(--inspector); flex: none; background: var(--chrome);
  border-left: 1px solid var(--hairline); display: none; flex-direction: column; min-height: 0;
}
.app.inspect .inspector { display: flex; }
.insp-tabs { display: flex; gap: 4px; padding: 10px; border-bottom: 1px solid var(--hairline); }
.insp-tab {
  flex: 1; min-height: 32px; border-radius: 8px; color: var(--muted);
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
}
.insp-tab.on { background: var(--selected); color: var(--text); font-weight: 600; }
.insp-body { flex: 1; min-height: 0; overflow: auto; -webkit-overflow-scrolling: touch; padding: 8px; }
.file {
  display: flex; align-items: center; gap: 8px; width: 100%; text-align: left;
  padding: 6px 8px; border-radius: 8px; color: var(--text);
}
.file:hover, .file.sel { background: var(--subdued); }
.file .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.preview {
  margin: 8px; padding: 10px; background: var(--content); border-radius: 10px;
  font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
  white-space: pre-wrap; overflow-wrap: anywhere; color: var(--muted); max-height: 40%; overflow: auto;
}
.review-stat { padding: 12px; color: var(--muted); font-size: 13px; display: flex; flex-direction: column; gap: 8px; }
.review-stat b { color: var(--text); font-weight: 600; }
.install, .reconnect {
  display: none; margin: 0; padding: 8px 16px; font-size: 12px; color: var(--muted);
  background: rgba(245,158,11,.08); border-bottom: 1px solid var(--hairline);
}
.install.show, .reconnect.show { display: block; }
.phone-nav {
  display: none; flex: none; gap: 8px; padding: 6px 12px calc(8px + var(--safe-b));
  background: var(--chrome); border-top: 1px solid var(--hairline);
}
.phone-nav button {
  flex: 1; min-height: 40px; border-radius: 12px; color: var(--muted);
  display: inline-flex; align-items: center; justify-content: center; gap: 6px;
}
.phone-nav button.on { background: var(--selected); color: var(--text); font-weight: 600; }
.search {
  display: none; position: absolute; left: 12px; right: 12px; top: calc(56px + var(--safe-t)); z-index: 8;
  background: var(--chrome); border: 1px solid var(--hairline); border-radius: 12px;
  padding: 10px; box-shadow: 0 16px 40px rgba(0,0,0,.45); max-height: 50%; overflow: auto;
}
.app.searching .search { display: block; }
.search input {
  width: 100%; min-height: 36px; border-radius: 8px; border: 1px solid var(--hairline);
  background: var(--well); padding: 0 12px; margin-bottom: 8px;
}
.hit { display: block; width: 100%; text-align: left; padding: 8px; border-radius: 8px; color: var(--text); }
.hit:hover { background: var(--subdued); }
.hit .path { color: var(--brand); font-size: 11px; display: block; }
.term-dock {
  display: none; flex: none; height: 200px; background: #0c0c0d;
  border-top: 1px solid var(--hairline); flex-direction: column; min-width: 0;
}
.app.term-open .term-dock { display: flex; }
.term-chrome {
  display: flex; gap: 8px; align-items: center; padding: 6px 10px;
  border-bottom: 1px solid var(--hairline); color: var(--muted); font-size: 12px;
}
.term-chrome input {
  flex: 1; min-width: 0; min-height: 32px; background: var(--well);
  border: 1px solid var(--hairline); border-radius: 8px; padding: 0 10px;
  font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.term-log {
  flex: 1; margin: 0; overflow: auto; padding: 8px 10px;
  font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
  color: #d1d5db; white-space: pre-wrap;
}
.diff-add { color: #86efac; }
.diff-del { color: #fca5a5; }
.diff-ctx { color: var(--dim); }
.hunk { margin: 0 0 12px; font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; }
.editor {
  display: none; width: 100%; min-height: 140px; max-height: 36%; border: 0; resize: vertical;
  background: var(--content); color: var(--text); padding: 10px;
  font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.editor.show { display: block; }
.insp-tools { display: flex; gap: 6px; padding: 8px 10px; border-bottom: 1px solid var(--hairline); }
@media (min-width: 1100px) {
  .inspector { display: flex; }
  .app.inspect .inspector { display: flex; }
}
@media (max-width: 839px) {
  .nav-btn { display: grid; }
  .sidebar {
    position: fixed; inset: 0 auto 0 0; transform: translateX(-105%);
    transition: transform .2s ease; box-shadow: 12px 0 40px rgba(0,0,0,.4);
  }
  .app.nav-open .sidebar { transform: none; }
  .app.nav-open .backdrop { display: block; }
  .status { display: none; }
  .phone-nav { display: flex; }
  .inspector {
    position: fixed; inset: 0 0 0 0; width: auto; z-index: 18;
    display: none; padding-top: var(--safe-t); padding-bottom: 52px;
  }
  .app.files-open .inspector { display: flex; }
  .app.files-open .backdrop { display: block; }
  .dock { padding-bottom: 8px; }
}
@media (display-mode: standalone) {
  .chrome { padding-top: calc(10px + var(--safe-t)); }
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
      <button class="icon-btn" id="files-btn" type="button" aria-label="Files" title="Files">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M2.5 5.2h4.1l1.3 1.5H13.5v6.8H2.5z" stroke="currentColor" stroke-width="1.5"/><path d="M2.5 5.2V3.8h3.6l.8 1.4" stroke="currentColor" stroke-width="1.5"/></svg>
      </button>
      <button class="icon-btn" id="search-btn" type="button" aria-label="Search files" title="Search">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="7" cy="7" r="4.2" stroke="currentColor" stroke-width="1.5"/><path d="M10.2 10.2L13.5 13.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
      </button>
      <button class="icon-btn" id="term-btn" type="button" aria-label="Terminal" title="Terminal">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none"><path d="M3 4.5l4 3.5-4 3.5M8 12.5h5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
      </button>
      <div class="status" id="status"><span class="live-dot"></span><span id="status-label">Connecting…</span></div>
    </header>
    <p class="install" id="install">Add to Home Screen to keep this remote as an app. Share → Add to Home Screen. Pairing stays on this iPad.</p>
    <p class="reconnect" id="reconnect">Connection paused. Reconnecting to this Mac…</p>
    <p class="error-bar" id="error"></p>
    <div class="search" id="search">
      <input id="search-q" placeholder="Search file contents" enterkeyhint="search">
      <div id="search-hits"></div>
    </div>
    <div class="stage">
      <div class="chat-col">
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
            <div class="reply-bar" id="replybar">
              <div class="quote" id="replypreview"></div>
              <button type="button" class="tab-close" id="replyclear" aria-label="Clear reply">×</button>
            </div>
            <textarea id="draft" rows="1" placeholder="Message this agent" enterkeyhint="send"></textarea>
            <div class="composer-actions">
              <button class="danger" id="stop" type="button" disabled>
                <svg class="i fill" viewBox="0 0 16 16" aria-hidden="true"><rect x="4" y="4" width="8" height="8" rx="1.2"/></svg>
                Stop
              </button>
              <button class="primary" id="send" type="button">
                <svg class="i" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 12.5V3.5M4.5 7L8 3.5 11.5 7"/></svg>
                <span id="send-label">Send</span>
              </button>
            </div>
          </div>
        </div>
      </div></div>
      </div>
      <aside class="inspector" id="inspector">
        <div class="insp-tabs">
          <button type="button" class="insp-tab on" id="tab-files" data-pane="files">Files</button>
          <button type="button" class="insp-tab" id="tab-changes" data-pane="changes">Changes</button>
          <button type="button" class="insp-tab" id="tab-requests" data-pane="requests">Requests</button>
        </div>
        <div class="insp-tools">
          <button type="button" class="ghost" id="newfile">New file</button>
          <button type="button" class="primary" id="savefile" hidden>Save</button>
        </div>
        <div class="insp-body" id="inspector-body"></div>
        <textarea class="editor" id="editor" hidden></textarea>
        <pre class="preview" id="preview" hidden></pre>
      </aside>
    </div>
    <div class="term-dock" id="term-dock">
      <div class="term-chrome">
        <span>Terminal</span>
        <input id="term-cmd" placeholder="Run in this worktree" enterkeyhint="go" autocomplete="off" spellcheck="false">
        <button type="button" class="primary" id="term-run">Run</button>
      </div>
      <pre class="term-log" id="term-log"></pre>
    </div>
    <nav class="phone-nav" id="phone-nav">
      <button type="button" class="on" data-view="chat" id="view-chat">Chat</button>
      <button type="button" data-view="files" id="view-files">Files</button>
      <button type="button" data-view="changes" id="view-changes">Changes</button>
      <button type="button" data-view="term" id="view-term">Term</button>
    </nav>
  </section>
</div>
<script>
const TOKEN_KEY = "ore-remote-token";
function readStoredToken() {
  try { const v = localStorage.getItem(TOKEN_KEY); if (v) return v; } catch (e) {}
  try { const v = sessionStorage.getItem(TOKEN_KEY); if (v) return v; } catch (e) {}
  const match = document.cookie.match(/(?:^|; )ore-token=([^;]*)/);
  return match ? decodeURIComponent(match[1]) : "";
}
function persistToken(value) {
  if (!value) return;
  try { localStorage.setItem(TOKEN_KEY, value); } catch (e) {}
  try { sessionStorage.setItem(TOKEN_KEY, value); } catch (e) {}
  const secure = location.protocol === "https:" ? "; Secure" : "";
  document.cookie = "ore-token=" + encodeURIComponent(value) + "; Path=/; Max-Age=31536000; SameSite=Lax" + secure;
}
function forgetToken() {
  try { localStorage.removeItem(TOKEN_KEY); } catch (e) {}
  try { sessionStorage.removeItem(TOKEN_KEY); } catch (e) {}
  document.cookie = "ore-token=; Path=/; Max-Age=0";
}
const params = new URLSearchParams(location.search);
const hashToken = decodeURIComponent((location.hash || "").replace(/^#/, ""));
const queryToken = params.get("token") || "";
const token = hashToken || queryToken || readStoredToken();
if (token) persistToken(token);
if (hashToken || queryToken) {
  try { history.replaceState(null, "", location.pathname); } catch (e) {}
}
const standalone = window.navigator.standalone === true || window.matchMedia("(display-mode: standalone)").matches;
const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
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
let source = null;
let pollTimer = 0;
let reconnectTimer = 0;
let backoff = 500;
let live = false;
let filesCache = [];
let filesWorkspace = "";
let openFolders = new Set();
let inspectorPane = "files";
let draftReply = null;
let selectedFile = "";
let changesCache = { files: [], insertions: 0, deletions: 0, branch: "" };
let selectedChange = "";
let diffCache = null;
let searchHits = [];
let shellLog = [];

async function api(path, options = {}) {
  const response = await fetch(path, { credentials: "same-origin", ...options, headers: { ...headers(), ...(options.headers || {}) } });
  if (response.status === 401) {
    forgetToken();
    throw new Error("This device is not paired. Scan the QR code in ORE Settings again.");
  }
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
    bolt: '<path class="fill" d="M9 1.5L4 9h4l-1 5.5L13 7H9z"/>',
    reply: '<path d="M4.5 7.5H12a2 2 0 0 1 2 2V13"/><path d="M4.5 7.5 7.2 4.8M4.5 7.5 7.2 10.2"/>',
    doc: '<path d="M4.5 2.8h5.2L11.5 5v8.2h-7z"/><path d="M9.5 2.8V5h2"/>',
    search: '<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2L13.5 13.5"/>',
    term: '<path d="M3 4.5l4 3.5-4 3.5M8 12.5h5"/>'
  };
  const d = paths[name];
  if (!d) return "";
  const fill = name === "sparkle" || name === "bolt" || d.includes('class="fill"') ? " fill" : "";
  return `<svg class="i${fill}" viewBox="0 0 16 16" aria-hidden="true">${d}</svg>`;
}

function setLive(kind, label) {
  const node = $("status");
  node.className = "status " + kind;
  $("status-label").textContent = label;
  $("reconnect").classList.toggle("show", kind === "wait" || kind === "bad");
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
    const unread = c.unread ? " unread" : "";
    return `<button type="button" class="tab${sel}${busy}${unread}" data-chat="${escapeAttr(c.id)}">${icon("bubble")}<span class="title">${escapeHtml(c.title || "Chat")}</span><span class="tab-close" data-close="${escapeAttr(c.id)}" aria-label="Close">×</span></button>`;
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
  const liveRow = !m.complete;
  const label = m.title || (m.kind === "thinking" ? "Thinking" : m.kind === "activity" ? "Activity" : "Tool");
  const kindIcon = m.kind === "thinking" ? "brain" : m.kind === "activity" ? "list" : m.kind === "error" ? "warn" : "wrench";
  const chev = m.expandable ? `<span class="chev">›</span>` : "";
  const pulse = liveRow ? `<span class="dot"></span>` : "";
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
  } else if (m.kind === "thinking" && liveRow && m.text) {
    body = `<div class="thinking">${escapeHtml(clip(m.text, 280))}</div>`;
  }
  const toggle = m.expandable
    ? `<button type="button" class="process-toggle" data-expand="${escapeAttr(m.id)}">${chev}${pulse}${icon(kindIcon)}<span class="label">${escapeHtml(label)}</span></button>`
    : `<div class="process-toggle">${pulse}${icon(kindIcon)}<span class="label">${escapeHtml(label)}</span></div>`;
  return `<div class="process${open ? " open" : ""}" data-id="${escapeAttr(m.id)}">${toggle}${body}</div>`;
}

function safeHref(url) {
  const u = String(url || "");
  if (/^(https?:|mailto:|#)/i.test(u) || u.startsWith(".") || u.startsWith("/")) return u;
  return "#";
}

function renderRich(text) {
  let s = escapeHtml(text);
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) =>
    `<a href="${escapeAttr(safeHref(href))}" data-file="${escapeAttr(href)}">${label}</a>`);
  return s;
}

function replyButton(m) {
  if (m.kind !== "you" && m.kind !== "agent" && m.kind !== "plan") return "";
  return `<button type="button" class="reply-btn" data-reply="${escapeAttr(m.id)}" aria-label="Reply">${icon("reply")}</button>`;
}

function quoted(m) {
  if (!m.reply) return "";
  return `<div class="quote">↩ ${escapeHtml(m.reply.author || (m.reply.role === "assistant" ? "Agent" : "You"))} · ${escapeHtml(m.reply.text || "")}</div>`;
}

function renderMessage(m) {
  const kind = m.kind || "agent";
  const queued = m.queued ? " queued" : "";
  const id = escapeAttr(m.id || "");
  if (kind === "you") {
    return `<div class="turn you${queued}" data-id="${id}">${replyButton(m)}<div class="bubble">${quoted(m)}${renderRich(m.text || "")}</div></div>`;
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
    return `<div class="turn plan${queued}" data-id="${id}">${heading(m)}${replyButton(m)}${icon("plan")}${escapeHtml(m.text || "")}</div>`;
  }
  const folded = collapsedResponses.has(m.id) && isLong(m.text);
  const liveRow = !m.complete;
  const body = folded ? preview(m.text) : (m.text || "");
  const toggle = isLong(m.text) && m.complete
    ? `<button type="button" class="fold" data-fold="${id}">${icon("down")}${folded ? "Show full response" : "Hide full response"}</button>`
    : "";
  return `<div class="turn${queued}" data-id="${id}">${heading(m)}${replyButton(m)}<div class="prose${liveRow ? " live" : ""}">${renderRich(body)}</div>${toggle}</div>`;
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
  const idsKey = messages.map(m => m.id).join("\n");
  const structure = idsKey + "|" + expandKey;
  const last = messages[messages.length - 1];
  const lastNode = last && log.querySelector(`[data-id="${CSS.escape(last.id)}"]`);
  if (log.dataset.structure === structure && lastNode) {
    const prose = lastNode.querySelector(".prose");
    const thinking = lastNode.querySelector(".thinking");
    const label = lastNode.querySelector(".process-toggle .label");
    if (prose) {
      prose.innerHTML = renderRich(last.text || "");
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
  const bar = $("replybar");
  bar.classList.toggle("show", !!draftReply);
  if (draftReply) {
    $("replypreview").textContent = "↩ " + (draftReply.author || "Message") + " · " + (draftReply.text || "");
  }
}

function fileRow(node, depth) {
  const pad = 8 + depth * 14;
  if (node.dir) {
    const open = openFolders.has(node.path);
    const kids = open ? (node.children || []).map(child => fileRow(child, depth + 1)).join("") : "";
    return `<button type="button" class="file" style="padding-left:${pad}px" data-folder="${escapeAttr(node.path)}">${icon("folder")}<span class="name">${escapeHtml(node.name)}</span></button>${kids}`;
  }
  const sel = node.path === selectedFile ? " sel" : "";
  return `<button type="button" class="file${sel}" style="padding-left:${pad}px" data-file="${escapeAttr(node.path)}">${icon("doc")}<span class="name">${escapeHtml(node.name)}</span></button>`;
}

function renderInspector() {
  const host = $("inspector-body");
  const ws = (state.workspaces || []).find(w => w.id === selectedWorkspace);
  document.querySelectorAll(".insp-tab").forEach(tab => {
    tab.classList.toggle("on", tab.dataset.pane === inspectorPane);
  });
  const editor = $("editor");
  const preview = $("preview");
  const save = $("savefile");
  const tools = inspectorPane === "files" && !(ws && ws.kind === "assistant");
  $("newfile").hidden = !tools;
  if (inspectorPane !== "files") {
    editor.hidden = true;
    editor.classList.remove("show");
    save.hidden = true;
    preview.hidden = true;
  }
  if (ws && ws.kind === "assistant" && inspectorPane !== "requests") {
    host.innerHTML = `<div class="empty">${icon("sparkle")}Assistant has no worktree.</div>`;
    return;
  }
  if (inspectorPane === "requests") {
    host.innerHTML = $("needsyou").innerHTML || `<div class="empty">${icon("shield")}No pending requests.</div>`;
    return;
  }
  if (inspectorPane === "changes") {
    const files = changesCache.files || [];
    const head = `<div class="review-stat"><div>${icon("branch")} ${escapeHtml(changesCache.branch || "")}</div>
      <div>+${changesCache.insertions || 0} / −${changesCache.deletions || 0}</div></div>`;
    if (!files.length) {
      host.innerHTML = head + `<div class="empty">${icon("check")}No uncommitted changes.</div>`;
      return;
    }
    const list = files.map(f => {
      const sel = f.path === selectedChange ? " sel" : "";
      return `<button type="button" class="file${sel}" data-change="${escapeAttr(f.path)}">${icon("doc")}<span class="name">${escapeHtml(f.path)}</span><span class="ws-branch">+${f.insertions || 0} −${f.deletions || 0}</span></button>`;
    }).join("");
    let diffHTML = "";
    if (diffCache && diffCache.path === selectedChange) {
      if (diffCache.binary) diffHTML = `<div class="hint">Binary file</div>`;
      else diffHTML = (diffCache.hunks || []).map(h => {
        const lines = (h.lines || []).map(line => {
          const cls = line.kind === "added" ? "diff-add" : line.kind === "removed" ? "diff-del" : "diff-ctx";
          const mark = line.kind === "added" ? "+" : line.kind === "removed" ? "−" : " ";
          return `<div class="${cls}">${mark}${escapeHtml(line.text || "")}</div>`;
        }).join("");
        return `<div class="hunk">${h.header ? `<div class="diff-ctx">${escapeHtml(h.header)}</div>` : ""}${lines}</div>`;
      }).join("");
    }
    host.innerHTML = head + list + (diffHTML ? `<div class="hunk">${diffHTML}</div>` : "");
    return;
  }
  if (!filesCache.length) {
    host.innerHTML = `<div class="empty">${icon("folder")}No files yet.</div>`;
    return;
  }
  host.innerHTML = filesCache.map(node => fileRow(node, 0)).join("");
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
  renderInspector();
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
  if (live) setLive("ok", state.busy ? "Working" : (ws ? ws.name : "Live"));
}

function escapeHtml(value) {
  return String(value || "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;" }[c]));
}
function escapeAttr(value) { return escapeHtml(value); }

function applyState(next) {
  state = next;
  live = true;
  backoff = 500;
  showError("");
  render();
}

function eventQuery() {
  return "workspace=" + encodeURIComponent(selectedWorkspace) +
    "&chat=" + encodeURIComponent(selectedChat) +
    "&token=" + encodeURIComponent(token);
}

function stopSource() {
  if (source) { source.close(); source = null; }
  if (pollTimer) { clearInterval(pollTimer); pollTimer = 0; }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  live = false;
  setLive("wait", "Reconnecting");
  reconnectTimer = setTimeout(() => {
    reconnectTimer = 0;
    backoff = Math.min(backoff * 2, 8000);
    connect();
  }, backoff);
}

function startPoll() {
  if (pollTimer) return;
  refresh();
  pollTimer = setInterval(refresh, 1500);
}

function connect() {
  if (!token) {
    showError("This device is not paired. Scan the QR code in ORE Settings.");
    setLive("bad", "Not paired");
    return;
  }
  stopSource();
  if (window.EventSource) {
    source = new EventSource("/api/events?" + eventQuery());
    source.onmessage = (event) => {
      try { applyState(JSON.parse(event.data)); } catch (e) {}
    };
    source.onopen = () => { live = true; backoff = 500; $("reconnect").classList.remove("show"); };
    source.onerror = () => {
      if (source) { source.close(); source = null; }
      fetch("/api/state?" + eventQuery(), { credentials: "same-origin", headers: headers() }).then(response => {
        if (response.status === 401) {
          forgetToken();
          showError("This device is not paired. Scan the QR code in ORE Settings again.");
          setLive("bad", "Not paired");
          return;
        }
        scheduleReconnect();
      }).catch(() => scheduleReconnect());
    };
  } else {
    startPoll();
  }
}

async function refresh() {
  try {
    const next = await api("/api/state?" + eventQuery());
    applyState(next);
  } catch (error) {
    live = false;
    showError(error.message);
    setLive("bad", "Disconnected");
  }
}

async function loadFiles() {
  if (!selectedWorkspace) return;
  try {
    const next = await api("/api/files?workspace=" + encodeURIComponent(selectedWorkspace));
    filesCache = next.files || [];
    filesWorkspace = selectedWorkspace;
    renderInspector();
  } catch (e) {}
}

async function openFile(path) {
  selectedFile = path;
  inspectorPane = "files";
  renderInspector();
  try {
    const next = await api("/api/file?workspace=" + encodeURIComponent(selectedWorkspace) + "&path=" + encodeURIComponent(path));
    const preview = $("preview");
    const editor = $("editor");
    const save = $("savefile");
    if (next.binary) {
      editor.hidden = true;
      editor.classList.remove("show");
      save.hidden = true;
      preview.hidden = false;
      preview.textContent = (next.name || path) + " is a binary file.";
    } else {
      preview.hidden = true;
      editor.hidden = false;
      editor.classList.add("show");
      editor.value = next.text || "";
      save.hidden = false;
    }
  } catch (e) {}
}

async function loadChanges() {
  if (!selectedWorkspace) return;
  try {
    changesCache = await api("/api/changes?workspace=" + encodeURIComponent(selectedWorkspace));
    renderInspector();
  } catch (e) {}
}

async function openChange(path) {
  selectedChange = path;
  inspectorPane = "changes";
  renderInspector();
  try {
    diffCache = await api("/api/diff?workspace=" + encodeURIComponent(selectedWorkspace) + "&path=" + encodeURIComponent(path));
    renderInspector();
  } catch (e) {}
}

async function runSearch() {
  const q = $("search-q").value.trim();
  if (!q) return;
  const next = await api("/api/search?workspace=" + encodeURIComponent(selectedWorkspace) + "&q=" + encodeURIComponent(q));
  searchHits = next.hits || [];
  $("search-hits").innerHTML = searchHits.map(hit =>
    `<button type="button" class="hit" data-file="${escapeAttr(hit.path)}"><span class="path">${escapeHtml(hit.path)}:${hit.line}</span>${escapeHtml(hit.text)}</button>`
  ).join("") || `<div class="empty">No matches.</div>`;
}

async function runShell() {
  const command = $("term-cmd").value.trim();
  if (!command) return;
  $("term-cmd").value = "";
  const next = await api("/api/shell", { method: "POST", body: JSON.stringify({ workspaceID: selectedWorkspace, command }) });
  shellLog = next.log || [];
  renderTerminal();
}

function renderTerminal() {
  $("term-log").textContent = (shellLog || []).map(e =>
    "$ " + (e.command || "") + "\n" + (e.output || "") + (e.status === "fail" ? "\nexit " + (e.code || "") : "")
  ).join("\n\n");
  $("term-log").scrollTop = $("term-log").scrollHeight;
}

function showPane(view) {
  const files = view === "files" || view === "changes";
  $("view-chat").classList.toggle("on", view === "chat");
  $("view-files").classList.toggle("on", view === "files");
  $("view-changes").classList.toggle("on", view === "changes");
  $("view-term").classList.toggle("on", view === "term");
  $("app").classList.toggle("files-open", files);
  $("app").classList.toggle("inspect", files || view === "files");
  $("app").classList.toggle("term-open", view === "term");
  if (view === "files") { inspectorPane = "files"; loadFiles(); }
  if (view === "changes") { inspectorPane = "changes"; loadChanges(); }
  renderInspector();
}

async function selectWorkspace(id) {
  selectedWorkspace = id;
  selectedChat = "";
  filesCache = [];
  selectedFile = "";
  closeNav();
  $("app").classList.remove("files-open");
  await api("/api/select", { method: "POST", body: JSON.stringify({ workspaceID: id }) });
  connect();
  loadFiles();
}

async function selectChat(id) {
  selectedChat = id;
  await api("/api/select", { method: "POST", body: JSON.stringify(ids()) });
  connect();
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
  const reply = event.target.closest("[data-reply]");
  const file = event.target.closest("a[data-file]");
  if (file) {
    const href = file.getAttribute("data-file") || "";
    if (href.startsWith(".") || (!/^https?:/i.test(href) && href.indexOf("://") < 0)) {
      event.preventDefault();
      $("app").classList.add("inspect");
      inspectorPane = "files";
      openFile(href.replace(/^\.\//, ""));
      return;
    }
  }
  if (reply) {
    const row = (state.messages || []).find(m => m.id === reply.dataset.reply);
    if (row) {
      draftReply = {
        rowID: row.id,
        turnID: row.turn,
        role: row.kind === "you" ? "user" : "assistant",
        author: row.kind === "you" ? "You" : (row.header || "Agent"),
        text: clip(row.text || row.title || "", 120)
      };
      renderComposer();
      $("draft").focus();
    }
    return;
  }
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
$("backdrop").addEventListener("click", () => {
  closeNav();
  $("app").classList.remove("files-open");
});
$("workspaces").addEventListener("click", (event) => {
  const row = event.target.closest("[data-ws]");
  if (row) selectWorkspace(row.dataset.ws);
});
$("tabs").addEventListener("click", (event) => {
  const close = event.target.closest("[data-close]");
  if (close) {
    event.preventDefault();
    event.stopPropagation();
    api("/api/close-chat", { method: "POST", body: JSON.stringify({ workspaceID: selectedWorkspace, chatID: close.dataset.close }) })
      .then(() => connect());
    return;
  }
  const tab = event.target.closest("[data-chat]");
  if (tab) selectChat(tab.dataset.chat);
});
$("newchat").addEventListener("click", async () => {
  await api("/api/new-chat", { method: "POST", body: JSON.stringify({ workspaceID: selectedWorkspace }) });
  connect();
});
$("files-btn").addEventListener("click", () => {
  $("app").classList.toggle("inspect");
  $("app").classList.toggle("files-open");
  inspectorPane = "files";
  loadFiles();
  renderInspector();
});
$("search-btn").addEventListener("click", () => {
  $("app").classList.toggle("searching");
  if ($("app").classList.contains("searching")) $("search-q").focus();
});
$("term-btn").addEventListener("click", () => $("app").classList.toggle("term-open"));
$("tab-files").addEventListener("click", () => { inspectorPane = "files"; renderInspector(); loadFiles(); });
$("tab-changes").addEventListener("click", () => { inspectorPane = "changes"; renderInspector(); loadChanges(); });
$("tab-requests").addEventListener("click", () => { inspectorPane = "requests"; renderInspector(); });
$("inspector-body").addEventListener("click", (event) => {
  const folder = event.target.closest("[data-folder]");
  const file = event.target.closest("[data-file]");
  const change = event.target.closest("[data-change]");
  if (folder) {
    const path = folder.dataset.folder;
    if (openFolders.has(path)) openFolders.delete(path);
    else openFolders.add(path);
    renderInspector();
    return;
  }
  if (change) { openChange(change.dataset.change); return; }
  if (file) openFile(file.dataset.file);
});
$("phone-nav").addEventListener("click", (event) => {
  const btn = event.target.closest("[data-view]");
  if (btn) showPane(btn.dataset.view);
});
$("search-q").addEventListener("keydown", (event) => {
  if (event.key === "Enter") { event.preventDefault(); runSearch(); }
});
$("search-hits").addEventListener("click", (event) => {
  const hit = event.target.closest("[data-file]");
  if (!hit) return;
  $("app").classList.remove("searching");
  $("app").classList.add("inspect", "files-open");
  openFile(hit.dataset.file);
});
$("newfile").addEventListener("click", async () => {
  const path = window.prompt("New file path", "untitled.txt");
  if (!path) return;
  const next = await api("/api/new-file", { method: "POST", body: JSON.stringify({ workspaceID: selectedWorkspace, path }) });
  if (next && next.error) { showError(next.error); return; }
  await loadFiles();
  if (next && next.path) openFile(next.path);
});
$("savefile").addEventListener("click", async () => {
  if (!selectedFile) return;
  const next = await api("/api/save", { method: "POST", body: JSON.stringify({
    workspaceID: selectedWorkspace, path: selectedFile, text: $("editor").value
  }) });
  if (next && next.error) showError(next.error);
});
$("term-run").addEventListener("click", runShell);
$("term-cmd").addEventListener("keydown", (event) => {
  if (event.key === "Enter") { event.preventDefault(); runShell(); }
});
$("send").addEventListener("click", send);
$("draft").addEventListener("input", resizeDraft);
$("draft").addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); send(); }
});
$("stop").addEventListener("click", async () => {
  await api("/api/stop", { method: "POST", body: JSON.stringify(ids()) });
  refresh();
});
$("replyclear").addEventListener("click", () => { draftReply = null; renderComposer(); });
async function pushComposer() {
  await api("/api/composer", { method: "POST", body: JSON.stringify({
    ...ids(),
    harness: $("harness").value,
    model: $("model").value,
    effort: $("effort").hidden ? "" : $("effort").value,
    permissionMode: $("permission").value,
    fast: $("fast").classList.contains("on") ? "1" : ""
  }) });
  refresh();
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
  refresh();
});

async function send() {
  const text = $("draft").value.trim();
  if (!text) return;
  $("draft").value = "";
  resizeDraft();
  followBottom = true;
  const payload = {
    ...ids(),
    text,
    effort: $("effort").hidden ? "" : $("effort").value,
    fast: $("fast").classList.contains("on") ? "1" : ""
  };
  if (draftReply) {
    payload.replyRowID = draftReply.rowID;
    payload.replyTurnID = draftReply.turnID;
    payload.replyRole = draftReply.role;
    payload.replyAuthor = draftReply.author;
    payload.replyText = draftReply.text;
    draftReply = null;
    renderComposer();
  }
  await api("/api/send", { method: "POST", body: JSON.stringify(payload) });
  refresh();
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") connect();
});
window.addEventListener("pageshow", () => connect());
window.addEventListener("online", () => connect());
window.addEventListener("focus", () => { if (!live) connect(); });
if (ios && !standalone) $("install").classList.add("show");
if (standalone) $("install").classList.remove("show");
connect();
loadFiles();
</script>
</body>
</html>
"""#

    static let manifest = """
{
  "name": "ORE",
  "short_name": "ORE",
  "description": "Remote control for ORE on this Mac",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "orientation": "any",
  "background_color": "#171615",
  "theme_color": "#14151A",
  "icons": [
    {
      "src": "/apple-touch-icon.png",
      "sizes": "180x180",
      "type": "image/png",
      "purpose": "any maskable"
    }
  ]
}
"""

    static func asset(path: String) -> (type: String, data: Data)? {
        switch path {
        case "/manifest.webmanifest":
            return ("application/manifest+json", Data(manifest.utf8))
        case "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png", "/favicon.png", "/favicon.ico":
            return ("image/png", iconPNG())
        default:
            return nil
        }
    }

    static func iconPNG() -> Data { iconPNGStorage }

    private static let iconPNGStorage: Data = renderIconPNG()

    private static func renderIconPNG() -> Data {
        let size = 180
        let pixels = size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return Data() }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 23 / 255, green: 22 / 255, blue: 21 / 255, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSColor(srgbRed: 245 / 255, green: 158 / 255, blue: 11 / 255, alpha: 1).setFill()
        let inset = CGFloat(size) * 0.18
        NSBezierPath(
            roundedRect: NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2),
            xRadius: 28,
            yRadius: 28
        ).fill()
        let text = "ORE" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 26 / 255, green: 18 / 255, blue: 8 / 255, alpha: 1),
        ]
        let textSize = text.size(withAttributes: attrs)
        text.draw(
            at: NSPoint(x: (CGFloat(size) - textSize.width) / 2, y: (CGFloat(size) - textSize.height) / 2 - 2),
            withAttributes: attrs
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
