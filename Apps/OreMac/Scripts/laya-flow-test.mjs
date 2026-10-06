#!/usr/bin/env node
/** Load the real laya-flow.html in JSDOM and walk live Laya through the viewer proxy. */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

const htmlPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "laya-flow.html");
const BASE = "http://127.0.0.1:8765/";

function loadPage() {
  const html = fs.readFileSync(htmlPath, "utf8").replace(
    /if \(new URLSearchParams\(location\.search\)\.has\("autowalk"\)\) \{\s*run\(\);\s*\}/,
    "",
  );
  const dom = new JSDOM(html, {
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
  return dom;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function walk(speech) {
  const dom = loadPage();
  const { document } = dom.window;
  document.getElementById("speech").value = speech;
  document.getElementById("run").click();
  for (let i = 0; i < 120; i++) {
    const walkState = document.body.dataset.walk || "";
    if (walkState === "ok" || walkState.startsWith("error")) {
      return {
        walk: walkState,
        clicks: (document.body.dataset.clicks || "").split(",").filter(Boolean),
        assistant: document.body.dataset.assistant || "",
        palette: document.body.dataset.palette,
        settings: document.body.dataset.settings,
        tabs: document.body.dataset.tabs,
        glass: document.body.dataset.glass,
        status: document.getElementById("status").textContent,
        rounds: [...document.querySelectorAll(".round")].map((el) => el.textContent.replace(/\s+/g, " ").trim()),
        layout: document.getElementById("layoutState").textContent.replace(/\s+/g, " ").trim(),
        windowClass: document.getElementById("window").className,
      };
    }
    await sleep(250);
  }
  throw new Error("walk timed out: " + (document.body.dataset.walk || "unset") + " " + document.getElementById("status").textContent);
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

const cases = [
  {
    name: "settings ramble",
    speech: "open settings and turn on liquid glass then open a new terminal tab and reveal this folder in finder. open CONTRIBUTING.md",
    clicks: ["openSettings", "settingsLiquidGlass", "terminalTabCreate", "revealInFinder", "openNamedFile"],
    assistant: "",
    extra: (got) => {
      assert(got.palette === "1", "palette should be open for CONTRIBUTING.md, got " + got.palette);
      assert(got.tabs === "2", "new terminal tab missing, tabs=" + got.tabs);
      assert(got.glass === "1", "liquid glass should be on, glass=" + got.glass);
    },
  },
  {
    name: "hide panes ramble",
    speech: "Hello, so I want to close the right side bar quickly and then also shut the left side bar close the right one as well and in the terminal I don't want to see the terminal. close the terminal shut the terminal.",
    clicks: ["reviewHide", "sidebarHide", "reviewHide", "terminalCollapse", "terminalCollapse", "terminalCollapse"],
    assistant: "",
    extra: (got) => {
      assert(got.windowClass.includes("no-left"), "left sidebar still visible: " + got.windowClass);
      assert(got.windowClass.includes("no-right"), "right review still visible: " + got.windowClass);
      assert(got.windowClass.includes("no-term"), "terminal still visible: " + got.windowClass);
    },
  },
  {
    name: "chrome then coding work",
    speech: "close the right sidebar and then add tests for VoiceInput",
    clicks: ["reviewHide"],
    assistant: "add tests for VoiceInput",
  },
  {
    name: "named files are not assistant",
    speech: "open README.md then open Package.swift",
    clicks: ["openNamedFile", "openNamedFile"],
    assistant: "",
  },
];

let failed = 0;
for (const c of cases) {
  process.stdout.write(c.name + " … ");
  try {
    const got = await walk(c.speech);
    assert(got.walk === "ok", "walk=" + got.walk + " status=" + got.status);
    assert(JSON.stringify(got.clicks) === JSON.stringify(c.clicks), "clicks " + JSON.stringify(got.clicks) + " != " + JSON.stringify(c.clicks) + "\n" + got.rounds.join("\n"));
    assert(got.assistant === c.assistant, "assistant " + JSON.stringify(got.assistant));
    c.extra?.(got);
    console.log("PASS");
    console.log("  " + got.clicks.join(" → ") || "(no clicks)");
  } catch (err) {
    failed += 1;
    console.log("FAIL");
    console.error("  " + err.message);
  }
}
if (failed) process.exit(1);
console.log("\nAll page walks passed.");
