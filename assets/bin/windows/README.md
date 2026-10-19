# Windows binaries

Put these here before `flutter run` or a release build. They're bundled at
compile time, so they have to exist first.

| File | Used for | In git? |
|------|----------|---------|
| `xray.exe` | the Xray core: Proxy and TUN for all xray protocols (VLESS, VMess, Trojan, SS, Hysteria2); in TUN mode it owns the wintun adapter itself | yes (committed) |
| `mihomo.exe` | the Clash core: ready-made Clash configs, plain links and AmneziaWG profiles; in TUN mode it owns the wintun adapter itself | yes (committed) |
| `wintun.dll` | the Windows TUN adapter, loaded at runtime by both cores | yes (committed) |
| `geoip.dat` | optional, enables `geoip:…` routing rules (xray side) | yes |
| `geosite.dat` | optional, enables `geosite:…` rules (xray side) | yes |

Proxy mode runs xray with a local SOCKS/HTTP inbound and points the Windows system
proxy at it; TUN mode runs xray with its own TUN inbound and needs the app as
administrator (plus `wintun.dll` next to xray.exe).

Build `xray.exe` with `tool/build_xray_cores.ps1 -Target windows`, from a checkout of
[Lemonochka/keqrnel](https://github.com/Lemonochka/keqrnel) next to this repository: its
`tools/patchxray` prepares the patched xray-core tree. A stock xray lacks the patches
the app relies on (process rules for the TUN, the program in the access log, a clean
stop through stdin, UDP bursts), see the headers in `tool/patches/`.

`-ldflags=-w` drops the debugger data (DWARF) and keeps the symbol table, so crash
traces still name functions. Not `-s -w`: a fully stripped unsigned exe is what
Defender once quarantined.

`mihomo.exe` is the second core, not a wrapper: which one runs a server is decided
by the server's **format** (Clash YAML and AmneziaWG `.conf` → mihomo, Xray JSON →
xray, a plain link → whichever the user picked). In TUN mode mihomo creates the
adapter itself, so it needs the same two things as xray: administrator rights
and `wintun.dll` next to the binary. Build it with `tool/build_mihomo.ps1 -Target
windows` — a patched build, see `tool/patches/`; like xray it loses only the
DWARF (`-w`), not the symbol table, to keep Defender calm.

AmneziaWG has no binary of its own any more: mihomo carries amneziawg-go and runs
the profile as `type: wireguard` with `amnezia-wg-option`.

`wintun.dll` is the official Wintun library, wintun 0.14.1 (amd64) from
https://www.wintun.net/builds/wintun-0.14.1.zip. Without it, TUN mode can't create
the adapter.

A missing binary just shows an error when you try to connect. If you'd rather not
bundle them, put the files next to `keqdroid.exe` or on `PATH`.
