#!/usr/bin/env python3
"""Reopen an existing private test copy without environment, then reject a bad marker."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

repo = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("agent_test", repo / "Scripts/agent-test.py")
driver = importlib.util.module_from_spec(spec); spec.loader.exec_module(driver)
root = driver.checked_root(sys.argv[1])
marker = root / "session.json"
original = marker.read_bytes()
executable = root / "Silkwire Agent Test.app/Contents/MacOS/Silkwire"
library = root / "Library/workspace.json"
environment = {"PATH": "/usr/bin:/bin", "HOME": str(root), "TMPDIR": str(root / "tmp") + "/"}
checks = []


def check(ok, label):
    checks.append({"check": label, "passed": bool(ok)})
    if not ok:
        raise AssertionError(label)
    print("PASS: " + label, flush=True)


with (root / "reopen.log").open("wb") as log:
    process = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=log)
    try:
        state = driver.command(str(root), '{"action":"status"}')["state"]
        check(state["library"] == str(root / "Library") and not state["storageError"], "reopening a private copy without environment stays in its throwaway library")
        deadline = time.monotonic() + 10
        while state["connecting"] and time.monotonic() < deadline:
            time.sleep(0.1); state = driver.command(str(root), '{"action":"status"}')["state"]
        check(len(state["identities"]) == 3 and all(value.startswith("synthetic-agent-test-") for value in state["identities"].values()), "reopened private copy still uses simulated teammates")
        driver.command(str(root), '{"action":"quit"}'); process.wait(timeout=10)
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=10)
    before = hashlib.sha256(library.read_bytes()).hexdigest()
    controller = (root / "controller.json").read_bytes()
    marker.write_text("{}\n")
    process = subprocess.Popen([str(executable)], env=environment, stdout=log, stderr=log)
    try:
        request = str(uuid.uuid4())
        driver.write_json(root / "requests" / (request + ".json"), {"action": "status"})
        time.sleep(3)
        check(not (root / "responses" / (request + ".json")).exists() and (root / "controller.json").read_bytes() == controller and hashlib.sha256(library.read_bytes()).hexdigest() == before, "invalid session marker opens no library and starts no control endpoint")
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=10)
        marker.write_bytes(original)
(root / "reopen-evidence.json").write_text(json.dumps({"checks": checks, "root": str(root)}, indent=2))
