#!/usr/bin/env python3
"""Build polished macOS DMG disk images with Drag-and-Drop to Applications."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
APP_NAME = "keqdroid"
BUNDLE_NAME = f"{APP_NAME}.app"


def run(*args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, text=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def get_version():
    pubspec = (ROOT / "pubspec.yaml").read_text()
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", pubspec, re.MULTILINE)
    return match.group(1) if match else "1.0.0"


def setup_dmg_window(mount_point, volname):
    """Sets icon layout and window size via AppleScript Finder automation."""
    script = f'''
    tell application "Finder"
        tell disk "{volname}"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {{400, 200, 940, 580}}
            set viewOptions to the icon view options of container window
            set icon size of viewOptions to 128
            set arrangement of viewOptions to not arranged
            set position of item "{BUNDLE_NAME}" of container window to {{140, 190}}
            set position of item "Applications" of container window to {{400, 190}}
            close
            open
            update without registering applications
            delay 1
        end tell
    end tell
    '''
    try:
        run("/usr/bin/osascript", "-e", script)
    except Exception as e:
        print(f"Notice: Finder styling skipped or unavailable: {e}")


def make_dmg(app_path, arch, output_dir):
    version = get_version()
    volname = APP_NAME
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    final_dmg = output_dir / f"{APP_NAME}-{version}-macos-{arch}.dmg"

    with tempfile.TemporaryDirectory(prefix="keqdroid-dmg-") as tmp:
        tmp_dir = Path(tmp)
        stage_dir = tmp_dir / "stage"
        stage_dir.mkdir()

        # Copy .app
        dest_app = stage_dir / BUNDLE_NAME
        print(f"==> Copying {app_path.name} to DMG stage...")
        run("/usr/bin/ditto", str(app_path), str(dest_app))

        # Bundle cores for the target architecture
        cores_src = ROOT / "build/macos-cores" / arch
        if cores_src.is_dir():
            dest_cores = dest_app / "Contents/Resources/cores"
            dest_cores.mkdir(parents=True, exist_ok=True)
            for core in ("keqrnel", "mihomo"):
                src_core = cores_src / core
                if src_core.is_file():
                    shutil.copy2(src_core, dest_cores / core)
                    print(f"==> Bundled {arch} core: {core}")

        # Ensure geo databases are present in Resources/geo
        dest_geo = dest_app / "Contents/Resources/geo"
        dest_geo.mkdir(parents=True, exist_ok=True)
        for geo in ("geoip.dat", "geosite.dat"):
            src_geo = ROOT / "assets/bin/linux" / geo
            if src_geo.is_file() and not (dest_geo / geo).is_file():
                shutil.copy2(src_geo, dest_geo / geo)

        # Prune Android-only asset duplicates (geosite/geoip) bundled by Flutter from pubspec.yaml
        # Upstream make_release.ps1 and package_linux.sh prune these to remove dead weight
        for dup in [
            dest_app / "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/bin/windows",
            dest_app / "Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/geo",
            dest_app / "Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/windows",
            dest_app / "Contents/Frameworks/App.framework/Resources/flutter_assets/assets/geo",
        ]:
            if dup.exists():
                shutil.rmtree(dup, ignore_errors=True)

        # Thin universal Mach-O binaries to target architecture (arm64 / x86_64)
        target_arch = "arm64" if arch == "arm64" else "x86_64"
        print(f"==> Thinning Mach-O binaries to target architecture ({target_arch})...")
        for binary in dest_app.rglob('*'):
            if binary.is_file() and not binary.is_symlink():
                try:
                    with open(binary, 'rb') as f:
                        magic = f.read(4)
                    if magic in {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}:
                        res = subprocess.run(["/usr/bin/lipo", "-archs", str(binary)], capture_output=True, text=True)
                        arches = res.stdout.split()
                        if len(arches) > 1 and target_arch in arches:
                            thin = binary.with_name(binary.name + ".thin")
                            run("/usr/bin/lipo", str(binary), "-thin", target_arch, "-output", str(thin))
                            thin.chmod(binary.stat().st_mode)
                            thin.replace(binary)
                except Exception as e:
                    print(f"Notice: lipo thinning skipped for {binary.name}: {e}")

        # Sign all Mach-O binaries inside dest_app (including bundled cores)
        print("==> Signing bundled binaries and cores...")
        for binary in dest_app.rglob('*'):
            if binary.is_file() and not binary.is_symlink():
                try:
                    with open(binary, 'rb') as f:
                        magic = f.read(4)
                    if magic in {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}:
                        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(binary))
                except Exception:
                    pass
        # Seal top-level app bundle
        entitlements = ROOT / "macos/Runner/Release.entitlements"
        cmd = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime"]
        if entitlements.exists():
            cmd += ["--entitlements", str(entitlements)]
        cmd.append(str(dest_app))
        run(*cmd)

        # Symlink Applications
        os.symlink("/Applications", stage_dir / "Applications")

        raw_dmg = tmp_dir / "temp.dmg"
        # Calculate size needed: app size + 40MB padding
        app_size_mb = sum(f.stat().st_size for f in dest_app.rglob('*') if f.is_file()) // (1024 * 1024)
        dmg_size_mb = max(180, app_size_mb + 40)

        print(f"==> Creating temporary disk image ({dmg_size_mb}MB)...")
        run("/usr/bin/hdiutil", "create", "-size", f"{dmg_size_mb}m", "-fs", "HFS+",
            "-volname", volname, "-ov", str(raw_dmg))

        # Mount image
        mount_point = Path(f"/Volumes/{volname}")
        if mount_point.exists():
            try:
                run("/usr/bin/hdiutil", "detach", str(mount_point), "-force")
            except Exception:
                pass
        print("==> Mounting image for configuration...")
        run("/usr/bin/hdiutil", "attach", str(raw_dmg), "-mountpoint", str(mount_point))

        try:
            # Copy contents into mounted image
            print("==> Populating disk image...")
            run("/usr/bin/ditto", str(dest_app), str(mount_point / BUNDLE_NAME))
            os.symlink("/Applications", mount_point / "Applications")

            # Apply Finder layout
            time.sleep(1)
            setup_dmg_window(mount_point, volname)
        finally:
            print("==> Unmounting disk image...")
            time.sleep(1)
            run("/usr/bin/hdiutil", "detach", str(mount_point), "-force")

        # Convert to compressed read-only DMG
        final_dmg.unlink(missing_ok=True)
        print(f"==> Compressing final DMG: {final_dmg.name}...")
        run("/usr/bin/hdiutil", "convert", str(raw_dmg), "-format", "UDZO",
            "-imagekey", "zlib-level=9", "-o", str(final_dmg))

    checksum = sha256(final_dmg)
    size_mb = final_dmg.stat().st_size / (1024 * 1024)
    print(f"\nSuccessfully generated {final_dmg.name}:")
    print(f"  Path:   {final_dmg}")
    print(f"  Size:   {size_mb:.1f} MB")
    print(f"  SHA256: {checksum}")
    return final_dmg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["all", "arm64", "x64"], default="all")
    parser.add_argument("--app", type=Path, help="Path to built keqdroid.app")
    parser.add_argument("--output", type=Path, default=ROOT / "build/macos-release")
    args = parser.parse_args()

    app = args.app
    if not app:
        release_app = ROOT / "build/macos/Build/Products/Release/keqdroid.app"
        debug_app = ROOT / "build/macos/Build/Products/Debug/keqdroid.app"
        if release_app.is_dir():
            app = release_app
        elif debug_app.is_dir():
            app = debug_app
        else:
            print("==> Building Flutter macOS release bundle...")
            run("flutter", "build", "macos", "--release", cwd=ROOT)
            app = release_app

    if not app.is_dir():
        sys.exit(f"Error: {app} not found.")

    arches = ["arm64", "x64"] if args.arch == "all" else [args.arch]
    generated = []
    for target_arch in arches:
        dmg = make_dmg(app, target_arch, args.output)
        generated.append(dmg)

    sha_file = args.output / "SHA256SUMS"
    sums = {}
    if sha_file.exists():
        for line in sha_file.read_text().splitlines():
            parts = line.strip().split(maxsplit=1)
            if len(parts) == 2:
                sums[parts[1]] = parts[0]
    for dmg in generated:
        sums[dmg.name] = sha256(dmg)
    records = "".join(f"{sums[name]}  {name}\n" for name in sorted(sums.keys()))
    sha_file.write_text(records)
    print(f"\n==> Updated {sha_file.name}:")
    print(records)


if __name__ == "__main__":
    main()
