# Linux core binaries

Place the Linux (`x86_64` / ELF) core binaries here **before building** the Linux
desktop app. They are **not** Flutter assets — `linux/CMakeLists.txt` installs them
next to the `keqdroid` executable, and `LinuxCorePaths` resolves them there at
runtime. (As Flutter assets they would be bundled into every platform, including the
Android APK.)

| File | Source | In git? |
|------|--------|---------|
| `xray` | the Xray core: proxy and TUN for all xray protocols; in TUN mode it owns the tun device itself | yes (committed) |
| `mihomo` | the Clash core: runs ready-made Clash configs, plain links and AmneziaWG profiles; in TUN mode it owns the tun device itself | yes |
| `geoip.dat` | enables `geoip:…` routing rules | yes |
| `geosite.dat` | enables `geosite:…` rules | yes |

Which core runs a server is decided by the server's **format**, not by a setting:
Clash YAML and AmneziaWG `.conf` only mihomo can execute, an Xray JSON config only
xray; a plain link is taken by whichever core the user picked.

Proxy mode runs the core with a local SOCKS/HTTP inbound and needs no privileges; TUN
mode asks for root via `pkexec` at connect time (or skips pkexec when the app is already
running as root, which is what a system without polkit is left with), since both cores
create the tun device themselves.

## Building mihomo

`tool/build_mihomo.ps1 -Target linux` (runs on Windows, cross-compiles). It is NOT a
stock upstream build: `tool/patches/*.patch` are applied first, and the script fails
if any of them no longer applies.

## Building xray

`tool/build_xray_cores.ps1 -Target linux` (runs on Windows, cross-compiles), from a
checkout of [Lemonochka/keqrnel](https://github.com/Lemonochka/keqrnel) next to this
repository: its `tools/patchxray` prepares the patched xray-core tree. A stock xray
lacks the patches the app relies on (process rules for the TUN, the program in the
access log, UDP bursts on the desktop), see the headers in `tool/patches/`.

`geoip.dat` / `geosite.dat` are copied from `assets/bin/windows/` so routing behaves
identically on both platforms.
