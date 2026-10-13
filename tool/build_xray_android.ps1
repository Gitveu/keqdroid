# Build libxray.so for Android (arm64-v8a and armeabi-v7a).
#
# The xray-core revision and every dependency come from keqrnel's go.mod, so
# Android runs the same Xray as the desktop. keqrnel itself is not touched:
# the build reads a copy of its go.mod with one extra line that replaces
# xray-core by a patched copy of the same revision.
#
# tool/patches/xray-*.patch are applied first and the script fails if any of
# them does not apply. Read the patch headers before bumping xray in keqrnel.
#
# Like libmihomo.so, this is a plain executable in jniLibs: that is the only
# directory Android extracts with the exec bit set (see build_mihomo.ps1).
#
# -checklinkname=0: the anet dependency links into net.zoneCache in the
# standard library, which Go 1.26+ rejects without the flag.
#
# Requires: Go, git, Android NDK.
#
# Example:
#   powershell -File tool/build_xray_android.ps1

param(
    [string]$Keqrnel = (Join-Path $PSScriptRoot "..\..\keqrnel"),
    [string]$BuildDir = (Join-Path $PSScriptRoot "..\..\xray-build")
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$go = (Get-Command go -ErrorAction SilentlyContinue)
if (-not $go) { Write-Error "go not found. Install Go: https://go.dev/dl/" }
$git = (Get-Command git -ErrorAction SilentlyContinue)
if (-not $git) { Write-Error "git not found (needed to apply tool/patches)." }

$Keqrnel = (Resolve-Path $Keqrnel).Path
$goMod = Join-Path $Keqrnel "go.mod"
if (-not (Test-Path $goMod)) { Write-Error "keqrnel checkout not found: $Keqrnel" }

$m = Select-String -Path $goMod -Pattern '^\s*github\.com/xtls/xray-core\s+(\S+)' | Select-Object -First 1
if (-not $m) { Write-Error "xray-core is not required in $goMod" }
$Version = $m.Matches[0].Groups[1].Value
Write-Host "xray-core $Version (from keqrnel go.mod)"

# ---- NDK -------------------------------------------------------------------
$ndk = $env:ANDROID_NDK_HOME
if (-not $ndk) {
    $sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
           elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME }
           else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
    $ndkRoot = Join-Path $sdk "ndk"
    if (Test-Path $ndkRoot) {
        $ndk = (Get-ChildItem $ndkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
    }
}
if (-not $ndk -or -not (Test-Path $ndk)) {
    Write-Error "Android NDK not found. Set ANDROID_NDK_HOME or install NDK via Android Studio."
}
Write-Host "Using NDK: $ndk"
$tc = Join-Path $ndk "toolchains\llvm\prebuilt\windows-x86_64\bin"

# ---- Sources ---------------------------------------------------------------
# From the module cache, like build_mihomo.ps1: the exact published module,
# checksum included. The cache is read-only, so we work on a copy.
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$BuildDir = (Resolve-Path $BuildDir).Path
$src = Join-Path $BuildDir "xray-core"

if (Test-Path $src) {
    Write-Host "Removing previous source tree..."
    Get-ChildItem $src -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
    Remove-Item -Recurse -Force $src
}

Push-Location $Keqrnel
try {
    # No stderr redirection here: in PowerShell 5.1 it turns download progress
    # into NativeCommandError and aborts the script (see build_mihomo.ps1).
    & $go.Source mod download "github.com/xtls/xray-core"
    if ($LASTEXITCODE -ne 0) { Write-Error "go mod download failed for xray-core $Version" }
    $modCache = (& $go.Source env GOMODCACHE).Trim()
}
finally { Pop-Location }

$cached = Join-Path $modCache "github.com\xtls\xray-core@$Version"
if (-not (Test-Path $cached)) { Write-Error "module not found in cache: $cached" }

Write-Host "Copying sources to $src ..."
Copy-Item -Recurse -Force $cached $src
Get-ChildItem $src -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }

# ---- Patches ---------------------------------------------------------------
$patches = Get-ChildItem (Join-Path $PSScriptRoot "patches") -Filter "xray-*.patch" | Sort-Object Name
if ($patches.Count -eq 0) { Write-Error "no xray patches found in tool/patches" }

Push-Location $src
try {
    foreach ($p in $patches) {
        Write-Host ("Applying {0} ..." -f $p.Name)
        & $git.Source apply --verbose --whitespace=nowarn $p.FullName
        if ($LASTEXITCODE -ne 0) {
            Write-Error ("patch {0} does not apply to xray-core {1} - rebase it before building" -f $p.Name, $Version)
        }
    }
}
finally { Pop-Location }

# ---- Module file -----------------------------------------------------------
# A relative replace path ends up in the binary's build info; an absolute one
# would carry this machine's user name there.
Push-Location $Keqrnel
try { $rel = (Resolve-Path -Relative $src) -replace '\\', '/' }
finally { Pop-Location }

$modFile = Join-Path $BuildDir "keqrnel.mod"
$sumFile = Join-Path $BuildDir "keqrnel.sum"
$modText = [System.IO.File]::ReadAllText($goMod)
$modText = $modText.TrimEnd() + "`n`nreplace github.com/xtls/xray-core => $rel`n"
[System.IO.File]::WriteAllText($modFile, $modText)
Copy-Item -Force (Join-Path $Keqrnel "go.sum") $sumFile

# ---- Build -----------------------------------------------------------------
function Build-Xray {
    param(
        [string]$Goarch,
        [string]$Goarm,
        [string]$Goarm64,
        [string]$Cc,
        [string]$OutPath,
        [string]$Label
    )

    Push-Location $Keqrnel
    try {
        $env:CGO_ENABLED = "1"
        $env:GOOS = "android"
        $env:GOARCH = $Goarch
        if ($Goarm) { $env:GOARM = $Goarm }
        if ($Goarm64) { $env:GOARM64 = $Goarm64 }
        $env:CC = $Cc

        Write-Host "Building $Label ..."
        & $go.Source build "-modfile=$modFile" -trimpath -buildvcs=false `
            "-gcflags=all=-l=4" -ldflags "-s -w -checklinkname=0" `
            -o $OutPath github.com/xtls/xray-core/main
        if ($LASTEXITCODE -ne 0) { Write-Error "go build failed for $Label" }
    }
    finally {
        Pop-Location
        Remove-Item Env:CGO_ENABLED, Env:GOOS, Env:GOARCH, Env:CC -ErrorAction SilentlyContinue
        if ($Goarm) { Remove-Item Env:GOARM -ErrorAction SilentlyContinue }
        if ($Goarm64) { Remove-Item Env:GOARM64 -ErrorAction SilentlyContinue }
    }

    $size = (Get-Item $OutPath).Length
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $OutPath, $size)
}

Build-Xray -Goarch "arm64" -Goarm64 "v8.0" `
    -Cc (Join-Path $tc "aarch64-linux-android21-clang.cmd") `
    -OutPath (Join-Path $repoRoot "android\app\src\main\jniLibs\arm64-v8a\libxray.so") `
    -Label "libxray.so for arm64-v8a"
Build-Xray -Goarch "arm" -Goarm "7" `
    -Cc (Join-Path $tc "armv7a-linux-androideabi21-clang.cmd") `
    -OutPath (Join-Path $repoRoot "android\app\src\main\jniLibs\armeabi-v7a\libxray.so") `
    -Label "libxray.so for armeabi-v7a"

Write-Host "Done. Patched xray-core $Version built for Android."
