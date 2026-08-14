#!/usr/bin/env python3
"""Record golden transcripts from a live Claude Code CLI.

The driver's translator is the part of ORE most exposed to CLI protocol churn,
so it is tested against bytes a real CLI actually produced. Re-run this after a
`claude` upgrade and diff the result: a protocol change then shows up as a
failing test instead of as a user-visible regression weeks later.

    python3 Scripts/record-fixtures.py all
    python3 Scripts/record-fixtures.py tool-use
    swift test

Each scenario costs one short model request on the signed-in subscription.
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
# The `simple-text` fixture asserts on this directory name.
WORKSPACE = "/tmp/ore-probe"

BASE_ARGUMENTS = [
    "claude", "-p",
    "--output-format", "stream-json",
    "--input-format", "stream-json",
    "--include-partial-messages",
    # Required whenever stream-json output is used with --print.
    "--verbose",
    "--permission-prompt-tool", "stdio",
    # Record against a clean configuration so a fixture doesn't encode one
    # machine's settings, hooks or plugins.
    "--setting-sources", "",
    "--model", "sonnet",
]


def record(name, prompt, mode="default", permission="allow", interrupt_after=None):
    process = subprocess.Popen(
        BASE_ARGUMENTS + ["--permission-mode", mode],
        cwd=WORKSPACE,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    lock = threading.Lock()
    lines = []
    done = threading.Event()

    def send(message):
        with lock:
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

    def read():
        for line in process.stdout:
            line = line.rstrip("\n")
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue

            kind, subtype = message.get("type"), message.get("subtype")
            # Hook chatter is diagnostics rather than protocol, and a single
            # hook response can be larger than the whole transcript.
            if kind == "system" and subtype and subtype.startswith("hook_"):
                continue
            lines.append(line)

            if kind == "control_request" and message["request"].get("subtype") == "can_use_tool":
                if permission == "deny":
                    body = {"behavior": "deny", "message": "ORE: user denied via test rig"}
                else:
                    body = {
                        "behavior": "allow",
                        # Mandatory: the CLI rejects an allow without it.
                        "updatedInput": message["request"].get("input", {}),
                    }
                send({
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": message["request_id"],
                        "response": body,
                    },
                })

            if kind == "result":
                done.set()
        done.set()

    threading.Thread(target=read, daemon=True).start()
    send({"type": "control_request", "request_id": "init_1",
          "request": {"subtype": "initialize", "hooks": None}})
    time.sleep(1)
    send({"type": "user",
          "message": {"role": "user", "content": [{"type": "text", "text": prompt}]}})

    if interrupt_after:
        time.sleep(interrupt_after)
        send({"type": "control_request", "request_id": "int_1",
              "request": {"subtype": "interrupt"}})

    done.wait(timeout=180)
    time.sleep(0.5)
    process.kill()

    path = os.path.abspath(os.path.join(FIXTURES, name + ".jsonl"))
    with open(path, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    print("%-18s %3d lines -> %s" % (name, len(lines), path))


SCENARIOS = {
    "simple-text": lambda: record(
        "simple-text", "Say exactly: hello ore. Nothing else."),
    "tool-use": lambda: record(
        "tool-use", "Run the bash command: echo ore-permission-probe. Then say done."),
    "permission-allow": lambda: record(
        "permission-allow",
        "Create a file named allowed.txt containing the word ore. Use the Write tool.",
        permission="allow"),
    "permission-deny": lambda: record(
        "permission-deny",
        "Create a file named probe.txt containing the word ore. Use the Write tool.",
        permission="deny"),
    "interrupt": lambda: record(
        "interrupt",
        "Count slowly from 1 to 500, one number per line, in your reply text.",
        interrupt_after=5),
    "plan-mode": lambda: record(
        "plan-mode",
        "Propose a one-line plan to add a second line to notes.txt. Keep it very short.",
        mode="plan", permission="deny"),
}


def seed_workspace():
    """Files some scenarios need to exist before the agent looks."""
    with open(os.path.join(WORKSPACE, "notes.txt"), "w") as handle:
        handle.write("hello\n")


def main():
    if len(sys.argv) < 2 or (sys.argv[1] not in SCENARIOS and sys.argv[1] != "all"):
        print(__doc__)
        print("scenarios: all, " + ", ".join(sorted(SCENARIOS)))
        return 1

    shutil.rmtree(WORKSPACE, ignore_errors=True)
    os.makedirs(WORKSPACE)
    subprocess.run(["git", "init", "-q"], cwd=WORKSPACE, check=True)
    seed_workspace()

    version = subprocess.run(
        ["claude", "--version"], capture_output=True, text=True
    ).stdout.strip()
    print("recording against: %s\n" % version)

    names = sorted(SCENARIOS) if sys.argv[1] == "all" else [sys.argv[1]]
    for name in names:
        SCENARIOS[name]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
