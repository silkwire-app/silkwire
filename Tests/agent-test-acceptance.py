#!/usr/bin/env python3
"""Mounted-window acceptance for a separately launched private candidate."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import time
import uuid

repo = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("agent_test", repo / "Scripts/agent-test.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)
candidate = Path(sys.argv[1]).resolve(strict=True)
evidence = repo / "output/acceptance" / ("agent-ui-" + str(uuid.uuid4()))
evidence.mkdir(parents=True)
checks = []
session = driver.launch(candidate)
root = Path(session["root"])


def check(condition, label):
    checks.append({"check": label, "passed": bool(condition)})
    if not condition:
        raise AssertionError(label)
    print("PASS: " + label, flush=True)


def command(action, **values):
    request = dict(action=action, **values)
    reply = driver.command(str(root), json.dumps(request))
    with (evidence / "protocol.jsonl").open("a") as file:
        file.write(json.dumps({"request": request, "reply": reply}) + "\n")
    if not reply.get("ok"):
        raise AssertionError(str(reply))
    return reply["state"]


def ready():
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        state = command("status")
        if not state["busy"] and not state["connecting"]:
            return state
        time.sleep(0.1)
    raise TimeoutError("Synthetic teammates did not settle")


def computer(action, **values):
    marker = "<<COMPUTER " + json.dumps(dict(action=action, **values)) + ">>"
    return command("computer", marker=marker)


try:
    state = ready()
    check(state["library"] == str(root / "Library") and state["storageError"] == "", "fresh candidate opens only its throwaway library")
    check(state["simulatedTeammates"] and len(state["identities"]) == 3 and all(value.startswith("synthetic-agent-test-") for value in state["identities"].values()), "all three teammates are simulated")
    check(not state["liveComputerControl"], "private copy never enables global desktop or unsandboxed computer control")
    copied = Path(session["app"]) / "Contents/MacOS/Silkwire"
    check(hashlib.sha256(copied.read_bytes()).hexdigest() == session["testExecutableSHA256"] and driver.execution_image_digest(copied.read_bytes()) == session["executionImageSHA256"], "private packaging preserves candidate executable code and data; signature changes are recorded")
    check(driver.resources_digest(Path(session["app"]) / "Contents/Resources") == session["resourcesSHA256"], "private copy preserves every candidate resource")
    check(len(state["rooms"]) == 2, "two independent test rooms are mounted")
    rooms = {room["title"]: room["id"] for room in state["rooms"]}
    token = "Private paste " + str(uuid.uuid4())
    check(computer("focus", app=state["bundleID"])["composerFocused"], "COMPUTER focus reaches the private native composer")
    x, y, width, height = state["composerFrame"]
    computer("click", x=x + width / 2, y=y + height / 2)
    state = computer("type", text=token)
    check(state["draft"] == token and state["nativeDraft"] == token, "COMPUTER click and type insert text in the private native composer")
    computer("key", keys="cmd+return")
    state = ready()
    check(state["draft"] == "", "simulated send completes and clears the composer")
    command("switchRoom", room=rooms["Test Room One"])
    ready(); time.sleep(0.3)
    command("focus")
    text = "Draft stays in Room One\nUnicode: café · 🚀"
    state = command("paste", text=text)
    check(state["draft"] == text and state["activeRoom"] == rooms["Test Room One"], "room switching directs native paste to the selected room")
    top = command("scroll", fraction=0)["lastScroll"]["after"]
    frame = command("status")["transcriptFrame"]
    x, y, width, height = frame
    moved = computer("scroll", x=x + width / 2, y=y + height / 2, dy=5)["lastScroll"]["after"]
    check(moved > top, "COMPUTER scroll moves the mounted private transcript")
    bottom = command("scroll", fraction=1)["lastScroll"]["after"]
    check(bottom > top, "mounted transcript scrolls to both ends")
    command("switchRoom", room=rooms["Test Room Two"])
    state = ready()
    check(state["draft"] == "", "the other room keeps its own draft")
    command("switchRoom", room=rooms["Test Room One"])
    state = ready()
    check(state["draft"] == text, "room switching preserves the original native draft")
    computer("screenshot", app=state["bundleID"])
    shutil.copyfile(root / "screenshot.png", evidence / "private-candidate.png")
    check((evidence / "private-candidate.png").stat().st_size > 1000, "private mounted-window screenshot captured")
    forbidden = root.parent / ("Silkwire-Private-Escape-" + str(uuid.uuid4()))
    request = {"action": "computer", "marker": "<<COMPUTER " + json.dumps({"action": "shell", "command": "touch " + str(forbidden)}) + ">>"}
    refused = driver.command(str(root), json.dumps(request))
    check(not refused["ok"] and not forbidden.exists(), "private COMPUTER endpoint refuses host shell execution")
    request["marker"] = "<<COMPUTER " + json.dumps({"action": "click", "x": state["windowFrame"][0] - 50, "y": state["windowFrame"][1] - 50}) + ">>"
    check(not driver.command(str(root), json.dumps(request))["ok"], "private COMPUTER endpoint refuses points outside its own window")
    request["marker"] = '<<COMPUTER {"action":"key","keys":"cmd+v"}>>'
    check(not driver.command(str(root), json.dumps(request))["ok"], "private COMPUTER endpoint refuses system clipboard shortcuts")
finally:
    try:
        command("quit")
    except Exception:
        # A rejected startup has no controller. Terminate only the PID we launched,
        # after verifying its command still belongs to this private session.
        import signal
        import subprocess
        process = subprocess.run(["/bin/ps", "-p", str(session["pid"]), "-o", "command="], capture_output=True, text=True)
        if process.returncode == 0 and process.stdout.strip().startswith(str(root / "Silkwire Agent Test.app/Contents/MacOS/Silkwire")):
            os.kill(session["pid"], signal.SIGTERM)
    finally:
        receipt = dict(session=session, checks=checks)
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2))
        shutil.copyfile(root / "app.log", evidence / "app.log")
        print("Evidence: " + str(evidence), flush=True)
