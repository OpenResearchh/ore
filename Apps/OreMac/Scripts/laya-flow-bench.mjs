#!/usr/bin/env node
/** 100 spoken chrome/assistant utterances against the real laya-flow.html walker. */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const htmlPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "laya-flow.html");
const BASE = "http://127.0.0.1:8765/";
const FINDER = ["revealInFinder", "openFinder"];

function loadPage() {
  const html = fs.readFileSync(htmlPath, "utf8")
    .replace(/if \(new URLSearchParams\(location\.search\)\.has\("autowalk"\)\) \{\s*run\(\);\s*\}/, "")
    .replace("await new Promise((r) => setTimeout(r, 400));", "await Promise.resolve();");
  return new JSDOM(html, {
    url: BASE,
    runScripts: "dangerously",
    pretendToBeVisual: true,
    beforeParse(window) {
      window.fetch = (url, opts) => {
        const abs = typeof url === "string" && url.startsWith("http") ? url : new URL(String(url), BASE).href;
        return fetch(abs, opts);
      };
    },
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function walk(speech) {
  const dom = loadPage();
  const { document } = dom.window;
  document.getElementById("speech").value = speech;
  document.getElementById("run").click();
  for (let i = 0; i < 180; i++) {
    const walkState = document.body.dataset.walk || "";
    if (walkState === "ok" || walkState.startsWith("error")) {
      return {
        walk: walkState,
        clicks: (document.body.dataset.clicks || "").split(",").filter(Boolean),
        assistant: document.body.dataset.assistant || "",
        rounds: [...document.querySelectorAll(".round")].map((el) => el.textContent.replace(/\s+/g, " ").trim()),
        status: document.getElementById("status").textContent,
      };
    }
    await sleep(200);
  }
  throw new Error("timeout: " + (document.body.dataset.walk || "unset"));
}

function clicksMatch(got, expected, accept) {
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  if (same(got, expected)) return true;
  if (accept?.some((alt) => same(got, alt))) return true;
  // Finder reveal vs open Finder are the same chrome family.
  const norm = (arr) => arr.map((c) => (FINDER.includes(c) ? "finder" : c));
  if (same(norm(got), norm(expected))) return true;
  if (accept?.some((alt) => same(norm(got), norm(alt)))) return true;
  return false;
}

function assistantMatch(got, expected) {
  if (expected == null) return true;
  if (typeof expected === "string") return got === expected;
  if (expected instanceof RegExp) return expected.test(got);
  return false;
}

const C = (speech, clicks, extra = {}) => ({ speech, clicks, assistant: extra.assistant ?? "", accept: extra.accept, note: extra.note });

const cases = [
  // --- the screenshot ramble and paraphrases of that same job ---
  C("open settings and turn on liquid glass then open a new terminal tab and reveal this folder in finder. open CONTRIBUTING.md",
    ["openSettings", "settingsLiquidGlass", "terminalTabCreate", "revealInFinder", "openNamedFile"]),
  C("open settings, enable liquid glass, open a new terminal tab, reveal this folder in finder, open CONTRIBUTING.md",
    ["openSettings", "settingsLiquidGlass", "terminalTabCreate", "revealInFinder", "openNamedFile"]),
  C("please open settings and turn on liquid glass then open a new terminal tab and reveal this folder in finder then open CONTRIBUTING.md",
    ["openSettings", "settingsLiquidGlass", "terminalTabCreate", "revealInFinder", "openNamedFile"]),
  C("open preferences and turn on liquid glass then create a new terminal tab and show this folder in finder. open README.md",
    ["openSettings", "settingsLiquidGlass", "terminalTabCreate", "revealInFinder", "openNamedFile"]),
  C("bring up settings and enable liquid glass then a new terminal tab and reveal in finder. open SECURITY.md",
    ["openSettings", "settingsLiquidGlass", "terminalTabCreate", "revealInFinder", "openNamedFile"]),
  C("open settings then turn on liquid glass",
    ["openSettings", "settingsLiquidGlass"]),
  C("turn on liquid glass then open a new terminal tab",
    ["settingsLiquidGlass", "terminalTabCreate"]),
  C("open a new terminal tab then reveal this folder in finder",
    ["terminalTabCreate", "revealInFinder"]),
  C("reveal this folder in finder then open CONTRIBUTING.md",
    ["revealInFinder", "openNamedFile"]),
  C("open settings then open CONTRIBUTING.md",
    ["openSettings", "openNamedFile"]),
  C("turn off liquid glass then close settings",
    ["settingsLiquidGlass", "closeSettings"]),
  C("open Package.swift then turn on liquid glass",
    ["openNamedFile", "settingsLiquidGlass"]),

  // --- settings window / panes / toggles ---
  C("open settings", ["openSettings"]),
  C("show settings", ["openSettings"]),
  C("open preferences", ["openSettings"]),
  C("close settings", ["closeSettings"]),
  C("dismiss settings", ["closeSettings"]),
  C("turn on liquid glass", ["settingsLiquidGlass"]),
  C("turn off liquid glass", ["settingsLiquidGlass"]),
  C("enable liquid glass", ["settingsLiquidGlass"]),
  C("enable Dream Mode", ["settingsDreamEnable"]),
  C("disable Dream Mode", ["settingsDreamEnable"]),
  C("turn on dream mode", ["settingsDreamEnable"]),
  C("start ORE at login", ["settingsLaunchAtLogin"]),
  C("enable hold to talk", ["settingsHoldToTalk"]),
  C("turn on spoken narration", ["settingsNarration"]),
  C("share anonymous usage data", ["settingsAnalytics"]),
  C("open appearance settings", ["openSettings"], { accept: [["appearance"], ["settingsLiquidGlass"]] }),

  // --- named files / palette ---
  C("open CONTRIBUTING.md", ["openNamedFile"]),
  C("open README.md", ["openNamedFile"]),
  C("open Package.swift", ["openNamedFile"]),
  C("open SECURITY.md", ["openNamedFile"]),
  C("open Apps/OreMac/Package.swift", ["openNamedFile"]),
  C("open the command palette", ["openFilePalette"]),
  C("open command P", ["openFilePalette"]),
  C("command palette", ["openFilePalette"]),
  C("open the file picker", ["openFilePalette"]),

  // --- terminal ---
  C("open a new terminal tab", ["terminalTabCreate"]),
  C("new terminal tab", ["terminalTabCreate"]),
  C("close this terminal tab", ["terminalTabClose"]),
  C("next terminal tab", ["terminalTabNext"]),
  C("hide the terminal", ["terminalCollapse"]),
  C("close the terminal", ["terminalCollapse"]),
  C("shut the terminal", ["terminalCollapse"]),
  C("show the terminal", ["terminalOpen"]),
  C("I don't want to see the terminal", ["terminalCollapse"]),
  C("run the project", ["terminalRun"]),

  // --- panes ---
  C("close the right sidebar", ["reviewHide"]),
  C("close the right side bar", ["reviewHide"]),
  C("hide the right review pane", ["reviewHide"]),
  C("shut the left sidebar", ["sidebarHide"]),
  C("hide the left sidebar", ["sidebarHide"]),
  C("close the left side bar", ["sidebarHide"]),
  C("show the left sidebar", ["sidebarShow"]),
  C("show the right sidebar", ["reviewShow"]),
  C("toggle the left sidebar", ["sidebarToggle"]),
  C("toggle the right review pane", ["reviewToggle"]),
  C("close the right one", ["reviewHide"]),
  C("All files tab", ["reviewAllFiles"]),
  C("open Requests", ["reviewRequests"]),
  C("collapse the left sidebar", ["sidebarHide"]),
  C("bring back the right sidebar", ["reviewShow"]),

  // --- finder ---
  C("reveal this folder in finder", ["revealInFinder"]),
  C("reveal in Finder", ["revealInFinder"]),
  C("show this folder in finder", ["revealInFinder"]),
  C("open finder", ["openFinder"], { accept: [["revealInFinder"]] }),
  C("open this folder in Finder", ["revealInFinder"]),
  C("reveal the selected folder in finder", ["revealInFinder"]),

  // --- mixed chrome sequences ---
  C("hide the left sidebar then hide the right sidebar", ["sidebarHide", "reviewHide"]),
  C("close the right sidebar then shut the left sidebar", ["reviewHide", "sidebarHide"]),
  C("hide the terminal then close the right sidebar", ["terminalCollapse", "reviewHide"]),
  C("open settings then close settings", ["openSettings", "closeSettings"]),
  C("open a new terminal tab then hide the terminal", ["terminalTabCreate", "terminalCollapse"]),
  C("open README.md then open CONTRIBUTING.md", ["openNamedFile", "openNamedFile"]),
  C("open settings then enable Dream Mode", ["openSettings", "settingsDreamEnable"]),
  C("turn on liquid glass then turn on dream mode", ["settingsLiquidGlass", "settingsDreamEnable"]),
  C("new terminal tab then next terminal tab", ["terminalTabCreate", "terminalTabNext"]),
  C("hide the left sidebar then open CONTRIBUTING.md", ["sidebarHide", "openNamedFile"]),
  C("open a new chat tab then open a new terminal tab", ["chatTabCreate", "terminalTabCreate"]),
  C("reveal in finder then hide the terminal", ["revealInFinder", "terminalCollapse"]),

  // --- assistant vs leftover ---
  C("add tests for VoiceInput", [], { assistant: "add tests for VoiceInput" }),
  C("write a unit test for the clause splitter", [], { assistant: /unit test/ }),
  C("fix the flaky HUD test", [], { assistant: /HUD/ }),
  C("refactor VoiceActionGate", [], { assistant: /VoiceActionGate/ }),
  C("close the right sidebar and then add tests for VoiceInput", ["reviewHide"], { assistant: "add tests for VoiceInput" }),
  C("hide the left sidebar then write tests for LayaEngine", ["sidebarHide"], { assistant: /LayaEngine|tests/ }),
  C("open CONTRIBUTING.md then summarize it", ["openNamedFile"], { assistant: /summarize/ }),
  C("turn on liquid glass then add a settings test", ["settingsLiquidGlass"], { assistant: /settings test/ }),
  C("hello", [], { assistant: "" }),
  C("open settings and then fix the voice hotkey debounce", ["openSettings"], { assistant: /hotkey|debounce/ }),

  // --- chat / composer / titlebar ---
  C("open a new chat tab", ["chatTabCreate"]),
  C("next chat tab", ["chatTabNext"]),
  C("previous chat tab", ["chatTabPrevious"]),
  C("open history", ["chatHistory"]),
  C("find in transcript", ["findInTranscript"]),
  C("click Review", ["workspaceReview"]),
  C("commit", ["gitCommit"]),
  C("create a pull request", ["gitShip"]),
  C("mute the assistant", ["assistantMute"]),
  C("set effort to high", ["effortHigh"]),
];

if (cases.length !== 100) {
  console.error("expected 100 cases, got", cases.length);
  process.exit(2);
}

const results = [];
let exact = 0;
let fail = 0;

for (let i = 0; i < cases.length; i++) {
  const c = cases[i];
  const n = String(i + 1).padStart(3, "0");
  process.stdout.write(`${n} `);
  try {
    const got = await walk(c.speech);
    if (got.walk !== "ok") throw new Error(got.walk + " " + got.status);
    const clicksOk = clicksMatch(got.clicks, c.clicks, c.accept);
    const asstOk = assistantMatch(got.assistant, c.assistant);
    const ok = clicksOk && asstOk;
    if (ok) {
      exact += 1;
      console.log("PASS  " + (got.clicks.join(" → ") || "(none)") + (got.assistant ? " | asst:" + got.assistant : ""));
    } else {
      fail += 1;
      console.log("FAIL  " + c.speech);
      console.log("      got    clicks=" + JSON.stringify(got.clicks) + " asst=" + JSON.stringify(got.assistant));
      console.log("      want   clicks=" + JSON.stringify(c.clicks) + " asst=" + JSON.stringify(c.assistant));
      if (got.rounds.length) console.log("      hops   " + got.rounds.join(" || "));
    }
    results.push({ n: i + 1, speech: c.speech, ok, got: got.clicks, want: c.clicks, assistant: got.assistant, wantAssistant: c.assistant, hops: got.rounds });
  } catch (err) {
    fail += 1;
    console.log("ERROR " + c.speech);
    console.log("      " + err.message);
    results.push({ n: i + 1, speech: c.speech, ok: false, error: err.message, want: c.clicks });
  }
}

const report = {
  total: cases.length,
  pass: exact,
  fail,
  pct: Math.round((exact / cases.length) * 1000) / 10,
  failed: results.filter((r) => !r.ok),
};
const out = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "laya-flow-bench.json");
fs.writeFileSync(out, JSON.stringify({ report: { total: report.total, pass: report.pass, fail: report.fail, pct: report.pct }, results }, null, 2));
console.log("\n" + exact + "/" + cases.length + " exact (" + report.pct + "%)");
console.log("wrote " + out);
if (fail) process.exitCode = 1;
