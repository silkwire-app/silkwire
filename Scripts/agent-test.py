#!/usr/bin/env python3
"""Launch a private copy of a committed Staging candidate with synthetic providers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time
import uuid


def execution_image_digest(data):
    """Hash all Mach-O bytes except signature and its size bookkeeping.

    Re-signing an app with its own preferences identity updates the signature,
    LC_CODE_SIGNATURE size and __LINKEDIT extent; executable code/data stay exact.
    """
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected a native 64-bit Mach-O candidate")
    commands, size = struct.unpack_from("<II", data, 16)
    cursor, signature, normalized_fields = 32, None, []
    for _ in range(commands):
        command, length = struct.unpack_from("<II", data, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError("Invalid Mach-O load commands")
        if command == 0x1D:
            offset, count = struct.unpack_from("<II", data, cursor + 8)
            if offset < 32 + size or offset + count > len(data):
                raise ValueError("Invalid executable signature extent")
            signature = offset; normalized_fields.append((cursor + 12, 4))
        if command == 0x19 and data[cursor + 8:cursor + 24].rstrip(b"\0") == b"__LINKEDIT":
            normalized_fields += [(cursor + 32, 8), (cursor + 48, 8)]
        cursor += length
    if signature is None:
        raise ValueError("Candidate has no embedded signature")
    image = bytearray(data[:signature])
    for offset, length in normalized_fields:
        image[offset:offset + length] = bytes(length)
    return hashlib.sha256(image).hexdigest()


def resources_digest(root):
    inventory = {}
    for directory, folders, files in os.walk(root, followlinks=False):
        for name in folders + files:
            path = Path(directory) / name
            if path.is_symlink():
                inventory[str(path.relative_to(root))] = "link:" + os.readlink(path)
            elif path.is_file():
                inventory[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashlib.sha256(json.dumps(inventory, sort_keys=True).encode()).hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def checked_root(value):
    root = Path(value)
    if (not root.is_absolute() or root.resolve() != root or
            not str(root).startswith("/private/tmp/Silkwire-AgentTest-") or
            root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o777 != 0o700):
        raise ValueError("Expected a private agent-test session directory")
    marker = json.loads((root / "session.json").read_text())
    uuid.UUID(marker["session"])
    if marker.get("simulatedTeammates") is not True:
        raise ValueError("Session is not synthetic")
    return root


def launch(candidate):
    candidate = Path(candidate).resolve(strict=True)
    info = plistlib.loads((candidate / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "app.silkwire.staging" or info.get("SilkwireEnvironment") != "staging" or info.get("SilkwireSourceStatus") != "clean":
        raise ValueError("Choose a committed Silkwire Staging candidate")
    if info.get("SilkwireAgentTestProtocol") != 2:
        raise ValueError("This candidate predates private agent-test mode. Rebuild it before testing; nothing launched.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(candidate)], check=True)
    root = Path(tempfile.mkdtemp(prefix="Silkwire-AgentTest-", dir="/private/tmp"))
    session = str(uuid.uuid4())
    marker = {"session": session, "simulatedTeammates": True, "candidate": str(candidate),
              "revision": info["SilkwireGitRevision"], "sourceDigest": info["SilkwireSourceDigest"],
              "executableSHA256": hashlib.sha256((candidate / "Contents/MacOS/Silkwire").read_bytes()).hexdigest(),
              "root": str(root), "library": str(root / "Library")}
    write_json(root / "session.json", marker)
    for name in ["requests", "responses", "tmp"]:
        (root / name).mkdir(mode=0o700)
    app = root / "Silkwire Agent Test.app"
    shutil.copytree(candidate, app, symlinks=True)
    # A separate bundle identity also isolates AppKit/SwiftUI saved preferences.
    # Record signature/configuration changes and verify all executable code/data.
    info.update(CFBundleIdentifier="app.silkwire.agent-test." + session.lower(),
                CFBundleName="Silkwire Agent Test", CFBundleDisplayName="Silkwire Agent Test",
                SilkwireAgentTest=True, SilkwireAgentTestSession=session)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    original_code = execution_image_digest((candidate / "Contents/MacOS/Silkwire").read_bytes())
    private_bytes = (app / "Contents/MacOS/Silkwire").read_bytes()
    if execution_image_digest(private_bytes) != original_code:
        raise ValueError("Private packaging changed executable code/data; nothing launched")
    resources = resources_digest(candidate / "Contents/Resources")
    if resources_digest(app / "Contents/Resources") != resources:
        raise ValueError("Private packaging changed candidate resources; nothing launched")
    marker.update(testExecutableSHA256=hashlib.sha256(private_bytes).hexdigest(), executionImageSHA256=original_code,
                  resourcesSHA256=resources,
                  testBundleID=info["CFBundleIdentifier"], metadataChanges=["bundle identity", "display name", "test session", "code signature"])
    write_json(root / "session.json", marker)
    with (root / "app.log").open("wb") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/Silkwire")], stdout=log, stderr=log,
                                   env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root),
                                        "TMPDIR": str(root / "tmp") + "/", "SILKWIRE_AGENT_TEST_ROOT": str(root)},
                                   start_new_session=True)
    marker.update(pid=process.pid, app=str(app))
    write_json(root / "session.json", marker)
    return marker


def command(root, request):
    root = checked_root(root)
    request = json.loads(request)
    if not isinstance(request, dict):
        raise ValueError("Request must be a JSON object")
    instance, response = None, None
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        control = root / "controller.json"
        if control.exists():
            current = json.loads(control.read_text())["instance"]
            if current != instance:
                instance = current
                identity = str(uuid.uuid4())
                write_json(root / "requests" / (identity + ".json"), dict(request, instance=instance))
                response = root / "responses" / (identity + ".json")
        if response and response.exists():
            result = json.loads(response.read_text())
            if request.get("action") == "screenshot" and result.get("ok"):
                result["screenshot"] = str(root / "screenshot.png")
            if result.get("ok") and result.get("result", {}).get("screenshot"):
                result["screenshot"] = result["result"]["screenshot"]
            return result
        time.sleep(0.05)
    raise TimeoutError("Private candidate did not respond; see " + str(root / "app.log"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    start = sub.add_parser("launch"); start.add_argument("candidate")
    cmd = sub.add_parser("command"); cmd.add_argument("session"); cmd.add_argument("request")
    args = parser.parse_args()
    result = launch(args.candidate) if args.action == "launch" else command(args.session, args.request)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result.get("ok", True) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError, TimeoutError) as error:
        raise SystemExit(str(error))
