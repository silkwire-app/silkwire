#!/usr/bin/env python3
"""Build, launch and capture an Xcode iOS app in a fresh, private Simulator set."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid


def run(args, log=None):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if log:
        with log.open("a") as file:
            file.write("$ " + repr(args) + "\n" + result.stdout + result.stderr + "\n")
    if result.returncode:
        raise RuntimeError("Command failed (%s): %s\n%s" % (result.returncode, repr(args), (result.stdout + result.stderr)[-4000:]))
    return result.stdout.strip()


def build(args):
    project = Path(args.project).resolve(strict=True)
    if project.suffix not in (".xcodeproj", ".xcworkspace"):
        raise ValueError("Expected an Xcode project or workspace")
    root = Path(tempfile.mkdtemp(prefix="Silkwire-Simulator-", dir="/private/tmp"))
    (root / "Devices").mkdir(mode=0o700)
    log = root / "commands.log"
    inventory = json.loads(run(["/usr/bin/xcrun", "simctl", "list", "runtimes", "-j"], log))
    runtimes = [r for r in inventory["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
    if not runtimes:
        raise RuntimeError("Install an iOS Simulator runtime in Xcode first")
    runtime = max(runtimes, key=lambda r: tuple(int(x) for x in r["version"].split(".")))
    device_types = json.loads(run(["/usr/bin/xcrun", "simctl", "list", "devicetypes", "-j"], log))["devicetypes"]
    version = [int(v) for v in runtime["version"].split(".")]
    version += [0] * (3 - len(version))
    encoded = (version[0] << 16) | (version[1] << 8) | version[2]
    device_type = args.device_type or next(d["identifier"] for d in device_types if d["name"].startswith("iPhone") and d.get("minRuntimeVersion", 0) <= encoded <= d.get("maxRuntimeVersion", 0xFFFFFFFF))
    # Every simctl operation includes --set; never target 'booted' or erase an owner's device.
    simulator = ["/usr/bin/xcrun", "simctl", "--set", str(root / "Devices")]
    udid = run(simulator + ["create", "Silkwire private test " + str(uuid.uuid4())[:8], device_type, runtime["identifier"]], log)
    receipt = {"root": str(root), "device": udid, "deviceSet": str(root / "Devices"), "project": str(project), "scheme": args.scheme, "runtime": runtime["identifier"], "status": "created"}
    (root / "session.json").write_text(json.dumps(receipt, indent=2))
    try:
        run(simulator + ["boot", udid], log)
        run(simulator + ["bootstatus", udid, "-b"], log)
        xcode = ["/usr/bin/xcodebuild", "-workspace" if project.suffix == ".xcworkspace" else "-project", str(project),
                 "-scheme", args.scheme, "-configuration", args.configuration, "-sdk", "iphonesimulator",
                 "-destination", "id=" + udid, "-derivedDataPath", str(root / "DerivedData"), "CODE_SIGNING_ALLOWED=NO"]
        # Private device sets are not in xcodebuild's destination inventory. Build
        # generically for Simulator; install and launch on our exact private UDID.
        index = xcode.index("-destination"); xcode[index + 1] = "generic/platform=iOS Simulator"
        run(xcode + ["-resultBundlePath", str(root / "Build.xcresult"), "build"], log)
        settings = json.loads(run(xcode + ["-showBuildSettings", "-json"], log))
        apps = [Path(s["buildSettings"]["TARGET_BUILD_DIR"]) / s["buildSettings"]["FULL_PRODUCT_NAME"] for s in settings if s["buildSettings"].get("WRAPPER_EXTENSION") == "app"]
        if args.product:
            apps = [app for app in apps if app.name == args.product]
        if len(apps) != 1:
            raise ValueError("Choose the app with --product NAME.app; found " + repr([str(p) for p in apps]))
        app = apps[0]
        info = plistlib.loads((app / "Info.plist").read_bytes())
        bundle = info["CFBundleIdentifier"]
        run(simulator + ["install", udid, str(app)], log)
        launch = run(simulator + ["launch", udid, bundle], log)
        time.sleep(args.wait)
        screenshot = root / "screenshot.png"
        run(simulator + ["io", udid, "screenshot", str(screenshot)], log)
        receipt.update(status="passed", app=str(app), bundleID=bundle, launch=launch, screenshot=str(screenshot), log=str(log))
        (root / "session.json").write_text(json.dumps(receipt, indent=2))
        return receipt
    except Exception as error:
        receipt.update(status="failed", error=str(error))
        (root / "session.json").write_text(json.dumps(receipt, indent=2))
        raise RuntimeError(str(error) + "\nEvidence: " + str(root)) from error
    finally:
        if not args.keep_booted:
            try:
                run(simulator + ["shutdown", udid], log)
            except RuntimeError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project"); parser.add_argument("--scheme", required=True)
    parser.add_argument("--product"); parser.add_argument("--configuration", default="Debug")
    parser.add_argument("--device-type"); parser.add_argument("--wait", type=float, default=3)
    parser.add_argument("--keep-booted", action="store_true")
    print(json.dumps(build(parser.parse_args()), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError) as error:
        raise SystemExit(str(error))
