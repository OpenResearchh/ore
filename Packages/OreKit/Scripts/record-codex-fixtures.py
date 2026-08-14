#!/usr/bin/env python3
"""Record golden transcripts from a live `codex app-server`.

Same discipline as the Claude Code recorder: capture what the CLI actually
emits, replay it through the translator in CI, and let a protocol change show up
as a failing diff rather than as a broken transcript in front of a user.

    python3 Scripts/record-codex-fixtures.py all
    swift test

Unlike the Claude recorder, this captures the *server notifications* only —
those are what the translator consumes. Requests we send are protocol we own
and are covered by their own tests.
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import time

FIXTURES = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "Tests", "OreKitTests", "Fixtures",
)
WORKSPACE = "/tmp/ore-codex-fixtures"

# Notifications that are large, machine-specific, or irrelevant to the
# transcript. Recording them would encode one machine's MCP setup into a
# fixture every other machine then has to match.
SKIP_PREFIXES = (
    "mcpServer/",
    "remoteControl/",
    "app/list",
    "fs/changed",
)


def record(name, prompt, approve=True, interrupt_after=None):
    process = subprocess.Popen(
        ["codex", "app-server"],
        cwd=WORKSPACE,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )
    lock = threading.Lock()
    lines = []
    state = {}
    done = threading.Event()

    def send(message):
        with lock:
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

    def read():
        for line in process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue

            method = message.get("method")
            if method and "id" in message:
                # A server request: answer it so the agent isn't left blocked,
                # and record it — approval flows are exactly what we want
                # covered.
                lines.append(line)
                decision = "accept" if approve else "decline"
                if method in ("execCommandApproval", "applyPatchApproval"):
                    decision = "approved" if approve else "denied"
                send({"jsonrpc": "2.0", "id": message["id"],
                      "result": {"decision": decision}})
                continue

            if method:
                if not method.startswith(SKIP_PREFIXES):
                    lines.append(line)
                if method == "turn/completed":
                    done.set()
                continue

            state[message.get("id")] = message

    threading.Thread(target=read, daemon=True).start()

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"clientInfo": {"name": "ore", "title": "ORE", "version": "0.1.0"}}})
    time.sleep(2)
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    time.sleep(1)
    send({"jsonrpc": "2.0", "id": 2, "method": "thread/start",
          "params": {"cwd": WORKSPACE, "sandbox": "workspace-write",
                     "approvalPolicy": "on-request"}})
    time.sleep(4)

    thread = state.get(2, {}).get("result", {}).get("thread")
    if not thread:
        print(f"{name}: could not start a thread")
        process.kill()
        return
    # The start reply carries the thread; the translator sees it as
    # `thread/started`, so record it in that shape.
    lines.insert(0, json.dumps({"jsonrpc": "2.0", "method": "thread/started",
                                "params": {"thread": thread}}))

    send({"jsonrpc": "2.0", "id": 3, "method": "turn/start",
          "params": {"threadId": thread["id"],
                     "input": [{"type": "text", "text": prompt}]}})

    if interrupt_after:
        time.sleep(interrupt_after)
        turn = state.get(3, {}).get("result", {}).get("turn", {})
        if turn.get("id"):
            send({"jsonrpc": "2.0", "id": 4, "method": "turn/interrupt",
                  "params": {"threadId": thread["id"], "turnId": turn["id"]}})

    done.wait(timeout=180)
    time.sleep(1)
    process.kill()

    path = os.path.abspath(os.path.join(FIXTURES, name + ".jsonl"))
    with open(path, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    print("%-22s %3d lines -> %s" % (name, len(lines), path))


SCENARIOS = {
    "codex-simple-text": lambda: record(
        "codex-simple-text", "Say exactly: hello ore. Nothing else."),
    "codex-tool-use": lambda: record(
        "codex-tool-use",
        "Run the shell command `echo ore-probe`, then say done."),
    "codex-file-change": lambda: record(
        "codex-file-change",
        "Create a file named ore.txt containing the word ore."),
}


def main():
    if len(sys.argv) < 2 or (sys.argv[1] not in SCENARIOS and sys.argv[1] != "all"):
        print(__doc__)
        print("scenarios: all, " + ", ".join(sorted(SCENARIOS)))
        return 1

    shutil.rmtree(WORKSPACE, ignore_errors=True)
    os.makedirs(WORKSPACE)
    subprocess.run(["git", "init", "-q"], cwd=WORKSPACE, check=True)

    version = subprocess.run(
        ["codex", "--version"], capture_output=True, text=True).stdout.strip()
    print("recording against: %s\n" % version)

    names = sorted(SCENARIOS) if sys.argv[1] == "all" else [sys.argv[1]]
    for name in names:
        SCENARIOS[name]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
