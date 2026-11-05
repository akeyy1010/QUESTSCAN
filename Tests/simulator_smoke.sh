#!/bin/bash
# Developer smoke test, not a substitute for LiDAR/camera testing on hardware.
set -euo pipefail
mkdir -p Tests/.output/screenshots
APP="Tests/.output/QUESTSCAN.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find QUESTSCAN.swiftpm -name '*.swift' ! -name Package.swift | sort)
SDKROOT="$SDK" xcrun --sdk iphonesimulator swiftc -emit-executable -whole-module-optimization \
  -parse-as-library -swift-version 5 -module-name AppModule -sdk "$SDK" \
  -target "$ARCH-apple-ios16.0-simulator" "${SOURCES[@]}" -o "$APP/QUESTSCAN"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = dict(CFBundleExecutable='QUESTSCAN', CFBundleIdentifier='com.questscan.roomstudio',
            CFBundleName='QUESTSCAN', CFBundlePackageType='APPL', CFBundleVersion='1',
            CFBundleShortVersionString='1.0.0', MinimumOSVersion='16.0',
            LSRequiresIPhoneOS=True, UIDeviceFamily=[1,2],
            UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes':True},
            NSCameraUsageDescription='空間スキャンにカメラを使用します。',
            UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'])
with (app/'Info.plist').open('wb') as f: plistlib.dump(info,f)
(app/'PkgInfo').write_bytes(b'APPL????')
PY
cp QUESTSCAN.swiftpm/Resources/PrivacyInfo.xcprivacy "$APP/PrivacyInfo.xcprivacy"
codesign --force --sign - "$APP"
xcrun simctl list devices available --json > Tests/.output/devices.json
python3 - <<'PY' > Tests/.output/selected-devices.txt
import json
with open('Tests/.output/devices.json') as f: data=json.load(f)
devices=[d for runtime,items in data['devices'].items() if 'iOS' in runtime for d in items if d.get('isAvailable')]
for family in ['iPhone','iPad']:
    selected=next((d for d in devices if family in d['name']),None)
    if selected: print(family.lower(),selected['udid'])
PY
test -s Tests/.output/selected-devices.txt
while read -r family udid; do
  xcrun simctl boot "$udid" || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl status_bar "$udid" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
  xcrun simctl install "$udid" "$APP"
  xcrun simctl launch "$udid" com.questscan.roomstudio
  sleep 6
  xcrun simctl io "$udid" screenshot "Tests/.output/screenshots/$family-home.png"
  xcrun simctl terminate "$udid" com.questscan.roomstudio
  xcrun simctl launch "$udid" com.questscan.roomstudio --questscan-demo
  sleep 8
  xcrun simctl io "$udid" screenshot "Tests/.output/screenshots/$family-demo.png"
  xcrun simctl terminate "$udid" com.questscan.roomstudio
  xcrun simctl shutdown "$udid"
  echo "PASS: $family home and procedural demo launched; screenshots captured"
done < Tests/.output/selected-devices.txt
