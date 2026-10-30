#!/bin/bash
# Builds and installs keqdroid-network-service for local development / testing.
# Usage: sudo ./tool/macos/install_dev_helper.sh [--strict] [path-to-keqdroid.app]
set -euo pipefail

if [[ $(id -u) != 0 ]]; then
  echo "Error: Run with sudo: sudo $0 [--strict] [path-to-keqdroid.app]" >&2
  exit 1
fi

STRICT_MODE=false
if [[ "${1:-}" == "--strict" || "${1:-}" == "--release" ]]; then
  STRICT_MODE=true
  shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Detect active build if not passed
APP="${1:-}"
if [[ -z "$APP" ]]; then
  if [[ -d "$REPO_ROOT/build/macos/Build/Products/Debug/keqdroid.app" ]]; then
    APP="$REPO_ROOT/build/macos/Build/Products/Debug/keqdroid.app"
  elif [[ -d "$REPO_ROOT/build/macos/Build/Products/Release/keqdroid.app" ]]; then
    APP="$REPO_ROOT/build/macos/Build/Products/Release/keqdroid.app"
  else
    APP="$REPO_ROOT/build/macos/Build/Products/Debug/keqdroid.app"
  fi
fi

INSTALL_APP="/Applications/keqdroid.app"
RUNTIME="/Library/Application Support/com.keqdroid.keqdroid"
DAEMON="/Library/LaunchDaemons/com.keqdroid.keqdroid.network-service.plist"

if [[ ! -d "$APP" ]]; then
  echo "Error: Application bundle not found at: $APP" >&2
  echo "Build the app first: flutter build macos" >&2
  exit 1
fi

ARCH="$(uname -m)"
SWIFT_TARGET="$ARCH"
CORE_ARCH="$ARCH"
if [[ "$ARCH" == "arm64" ]]; then
  SWIFT_TARGET="arm64"
  CORE_ARCH="arm64"
elif [[ "$ARCH" == "x86_64" ]]; then
  SWIFT_TARGET="x86_64"
  CORE_ARCH="x64"
fi

echo "==> Building keqdroid-network-service..."
BUILD_DIR="$REPO_ROOT/build/macos-helper/$ARCH"
mkdir -p "$BUILD_DIR"

swift build --package-path "$REPO_ROOT/macos/NetworkService" --scratch-path "$BUILD_DIR" -c release --arch "$SWIFT_TARGET" --product keqdroid-network-service
BIN=$(swift build --package-path "$REPO_ROOT/macos/NetworkService" --scratch-path "$BUILD_DIR" -c release --arch "$SWIFT_TARGET" --show-bin-path)/keqdroid-network-service

echo "==> Staging application to $INSTALL_APP..."
rm -rf "$INSTALL_APP"
cp -R "$APP" "$INSTALL_APP"
chown -R root:wheel "$INSTALL_APP"
chmod -RN "$INSTALL_APP" 2>/dev/null || true
chmod -R go-w "$INSTALL_APP"

CODESIGN_INFO=$(codesign -d --verbose=4 "$INSTALL_APP" 2>&1)
CDHASH=$(echo "$CODESIGN_INFO" | grep -m1 '^CDHash=' | cut -d= -f2)

if [[ -z "$CDHASH" ]]; then
  echo "Codesigning $INSTALL_APP ad-hoc..."
  codesign --force --sign - --timestamp=none --options runtime "$INSTALL_APP"
  CDHASH=$(codesign -d --verbose=4 "$INSTALL_APP" 2>&1 | grep -m1 '^CDHash=' | cut -d= -f2)
fi

echo "App CDHash: $CDHASH"

if [[ "$STRICT_MODE" == "true" ]]; then
  REQUIREMENT="cdhash H\"$CDHASH\""
  echo "Using strict release CDHash requirement: $REQUIREMENT"
else
  REQUIREMENT="identifier \"com.keqdroid.keqdroid\""
  echo "Using development requirement: $REQUIREMENT"
fi

echo "==> Installing runtime to $RUNTIME..."
mkdir -p "$RUNTIME/bin" "$RUNTIME/geo" "$RUNTIME/state" "$RUNTIME/sessions"
cp -p "$BIN" "$RUNTIME/bin/keqdroid-network-service"
chmod 755 "$RUNTIME/bin/keqdroid-network-service"

# Install cores to runtime and ensure they are ad-hoc codesigned
CORES_SRC="$REPO_ROOT/build/macos-cores/$CORE_ARCH"
if [[ -d "$CORES_SRC" ]]; then
  for core in keqrnel mihomo; do
    if [[ -f "$CORES_SRC/$core" ]]; then
      cp -p "$CORES_SRC/$core" "$RUNTIME/bin/$core"
      chmod 755 "$RUNTIME/bin/$core"
      codesign --force --sign - --timestamp=none "$RUNTIME/bin/$core"
    fi
  done
elif [[ -d "$APP/Contents/Resources/cores" ]]; then
  for core in keqrnel mihomo; do
    if [[ -f "$APP/Contents/Resources/cores/$core" ]]; then
      cp -p "$APP/Contents/Resources/cores/$core" "$RUNTIME/bin/$core"
      chmod 755 "$RUNTIME/bin/$core"
      codesign --force --sign - --timestamp=none "$RUNTIME/bin/$core"
    fi
  done
fi

# Ensure bundled cores in application bundles are also signed
for app_dir in "$APP" "$INSTALL_APP"; do
  if [[ -d "$app_dir/Contents/Resources/cores" ]]; then
    for core in keqrnel mihomo; do
      if [[ -f "$app_dir/Contents/Resources/cores/$core" ]]; then
        codesign --force --sign - --timestamp=none "$app_dir/Contents/Resources/cores/$core" 2>/dev/null || true
      fi
    done
  fi
done

# Install geo assets to runtime
if [[ -d "$REPO_ROOT/assets/bin/linux" ]]; then
  for geo in geoip.dat geosite.dat; do
    if [[ -f "$REPO_ROOT/assets/bin/linux/$geo" ]]; then
      cp -p "$REPO_ROOT/assets/bin/linux/$geo" "$RUNTIME/geo/$geo"
      chmod 644 "$RUNTIME/geo/$geo"
    fi
  done
elif [[ -d "$APP/Contents/Resources/geo" ]]; then
  cp -p "$APP/Contents/Resources/geo"/* "$RUNTIME/geo/"
fi

# Generate core-manifest.json for runtime integrity check
python3 -c "import hashlib, json; from pathlib import Path; root = Path('$RUNTIME/bin'); cores = {c: {'sha256': hashlib.sha256((root / c).read_bytes()).hexdigest()} for c in ('keqrnel', 'mihomo') if (root / c).is_file()}; Path('$RUNTIME/core-manifest.json').write_text(json.dumps(cores, indent=2) + '\n')"
chmod 644 "$RUNTIME/core-manifest.json"

echo "$REQUIREMENT" > "$RUNTIME/client-requirement.txt"
chmod 600 "$RUNTIME/client-requirement.txt"
chown -R root:wheel "$RUNTIME"
chmod 700 "$RUNTIME/state"
chmod 711 "$RUNTIME/sessions"

echo "==> Stopping any old service instances..."
launchctl bootout system/com.keqdroid.keqdroid.network-service 2>/dev/null || true
launchctl bootout system/io.github.caocaocc.keqdroid.network-service 2>/dev/null || true
rm -f /Library/LaunchDaemons/io.github.caocaocc.keqdroid.network-service.plist 2>/dev/null || true

echo "==> Installing LaunchDaemon plist..."
cat > "$DAEMON" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.keqdroid.keqdroid.network-service</string>
  <key>ProgramArguments</key><array><string>/Library/Application Support/com.keqdroid.keqdroid/bin/keqdroid-network-service</string></array>
  <key>MachServices</key><dict><key>com.keqdroid.keqdroid.network-service</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>ExitTimeOut</key><integer>30</integer>
  <key>Umask</key><integer>63</integer>
</dict></plist>
PLIST
chown root:wheel "$DAEMON"
chmod 644 "$DAEMON"

echo "==> Starting com.keqdroid.keqdroid.network-service..."
launchctl bootstrap system "$DAEMON"

sleep 1
if launchctl print system/com.keqdroid.keqdroid.network-service | grep -q 'state = running'; then
  echo "==> Successfully installed and started keqdroid-network-service!"
else
  echo "==> Service registered; status:"
  launchctl print system/com.keqdroid.keqdroid.network-service
fi
