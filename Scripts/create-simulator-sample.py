#!/usr/bin/env python3
"""Create a throwaway, account-free iOS project for simulator.py acceptance."""
from pathlib import Path
import tempfile

root = Path(tempfile.mkdtemp(prefix="Silkwire-SimulatorSample-", dir="/private/tmp"))
project = root / "SimulatorSample.xcodeproj"
project.mkdir()
(root / "Sample.swift").write_text('''import SwiftUI
@main struct SimulatorSample: App {
    var body: some Scene { WindowGroup {
        ZStack {
            Color(red: 0.08, green: 0.12, blue: 0.21).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(.orange)
                Text("Simulator Ready").font(.largeTitle.bold())
                Text("Silkwire build and verify fixture").font(.headline)
                Text("Throwaway app · no accounts · private device").font(.caption)
            }.foregroundStyle(.white).padding()
        }
    } }
}
''')
(project / "project.pbxproj").write_text('''// !$*UTF8*$!
{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
000000000000000000000001 = {isa = PBXProject; buildConfigurationList = 000000000000000000000010; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = 000000000000000000000002; productRefGroup = 000000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (000000000000000000000004); };
000000000000000000000002 = {isa = PBXGroup; children = (000000000000000000000005, 000000000000000000000003); sourceTree = "<group>"; };
000000000000000000000003 = {isa = PBXGroup; name = Products; children = (000000000000000000000006); sourceTree = "<group>"; };
000000000000000000000004 = {isa = PBXNativeTarget; name = SimulatorSample; productName = SimulatorSample; productType = "com.apple.product-type.application"; productReference = 000000000000000000000006; buildConfigurationList = 000000000000000000000011; buildPhases = (000000000000000000000008); buildRules = (); dependencies = (); };
000000000000000000000005 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Sample.swift; sourceTree = "<group>"; };
000000000000000000000006 = {isa = PBXFileReference; explicitFileType = wrapper.application; path = SimulatorSample.app; sourceTree = BUILT_PRODUCTS_DIR; };
000000000000000000000007 = {isa = PBXBuildFile; fileRef = 000000000000000000000005; };
000000000000000000000008 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (000000000000000000000007); runOnlyForDeploymentPostprocessing = 0; };
000000000000000000000010 = {isa = XCConfigurationList; buildConfigurations = (000000000000000000000012); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
000000000000000000000011 = {isa = XCConfigurationList; buildConfigurations = (000000000000000000000013); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
000000000000000000000012 = {isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; }; };
000000000000000000000013 = {isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "app.silkwire.simulator-sample"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; TARGETED_DEVICE_FAMILY = "1,2"; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; CODE_SIGNING_ALLOWED = NO; }; };
}; rootObject = 000000000000000000000001; }
''')
print(project)
