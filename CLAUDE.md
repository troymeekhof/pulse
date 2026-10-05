# Pulse — project handoff for Claude Code

Native SwiftUI **menu bar system monitor** for macOS 13+ (universal: Apple Silicon + Intel).
Owner: Troy Meekhof (Mid-July Media). Built in Claude Cowork, now moving to Claude Code so it can
be built, signed, notarized and shipped with automatic updates.

Troy prefers brief, actionable answers. Don't over-explain; ask only on real decisions.

## What it does

- Menu bar label (rasterized NSImage — `MenuBarExtra` only renders ONE Image/Text reliably, so the
  icon + numbers are drawn via `ImageRenderer` as a template image). Modes: GPU+Mem, +Watts, GPU,
  Memory, Watts, Network ↓↑, Disk R/W, icon only. Icon becomes a thermometer while throttling.
- Popover (372 pt wide) with tabs **System | Network & Disk**; full "Open Dashboard" window shows all.
- **System**: GPU ring + sparkline, memory ring + App/Wired/Compressed/Cached bar, power card, thermal card.
- **Power**: SMC `PSTR` (fallback `PDTR`, then battery V×A). Integrated to Wh, persisted as minute
  (48 h) + hour (400 d) buckets in `~/Library/Application Support/Pulse/energy.json`. Totals for
  1 h / 24 h / 30 d / 1 y, 30-day projection, $ estimate at user-set $/kWh (default $0.18).
- **Thermal**: `ProcessInfo.thermalState` + `pmset -g therm` (CPU_Speed_Limit), polled every 3 s.
- **Network**: getifaddrs AF_LINK counters (32-bit wrap handled), skips lo/awdl/llw/bridge/etc.
- **Disk**: one **DriveCard per physical drive** (IOBlockStorageDriver stats). Boot drive first, then
  internals, then externals in plug-in order; cards appear/disappear live. Volumes mapped to drives by
  walking the IORegistry up from each mounted `/dev/diskNsM` (APFS-aware). Free space deduped per container.
- **NAS card**: `nettop -L 1 -n -x -J bytes_in,bytes_out` (process rows followed by connection rows),
  flows to ports 445/139 SMB, 548 AFP, 2049 NFS, 873 rsync, 5000/5001 DSM, 6690 Synology Drive.
  Mounted shares from getmntinfo. NOTE: Finder/Resolve SMB traffic is carried by the kernel and shows
  as "macOS file sharing (kernel)" — per-app attribution of SMB is not possible without root.
- **Top Apps**: per-app network (nettop) + disk (`proc_pid_rusage` RUSAGE_INFO_V2), every 2 s, off main thread.
- Settings (gear): refresh rate, menu bar mode, launch at login (SMAppService), $/kWh, reset energy, quit.

## Layout

```
Package.swift                     SwiftPM, macOS 13, links IOKit + ServiceManagement
Sources/Pulse/PulseApp.swift      @main, MenuBarExtra + Window, MenuBarLabel, LaunchAtLogin
Sources/Pulse/Monitor.swift       @MainActor ObservableObject, tick loop, GPU/memory/thermal readers, History
Sources/Pulse/Power.swift         SMC reader, PowerReader, EnergyStore, projections
Sources/Pulse/Throughput.swift    NetReader, DiskReader (per-drive), formatters
Sources/Pulse/ProcessIO.swift     nettop + proc_pid_rusage sampler, NAS flows, mounted shares
Sources/Pulse/Views/Theme.swift   colors, Card, Ring, Sparkline, DualSparkline, DriveCard, AppIORow…
Sources/Pulse/Views/DashboardView.swift   popover + window layout
Resources/Info.plist              LSUIElement, bundle id com.midjulymedia.pulse, v1.0
Resources/Pulse.icns, make_icon.py
build.sh                          ./build.sh | --install | --package (universal + ~/Downloads/Pulse.dmg)
```

## Build

- `./build.sh --install` — release build, bundle, ad-hoc sign, copy to /Applications, launch.
- `./build.sh --package` — universal (lipo arm64 + x86_64) app → `~/Downloads/Pulse.dmg`
  (drag-to-Applications + "How to open Pulse.txt").
- Compiles cleanly with Xcode CLT (Swift 6 toolchain, Swift 5 mode). Existing warnings are only
  Sendable/self-capture warnings in `Task.detached` blocks — harmless, fine to clean up.
- Verified working on Troy's 16" M1 MacBook Pro and a 15" 2017 Intel MacBook Pro (Ventura 13.7,
  dual GPU Radeon Pro 555 + Intel HD 630 — GPU reader currently takes the first IOAccelerator with
  PerformanceStatistics; may need to prefer the discrete GPU).

## Current state / known issues

- Distribution is **ad-hoc signed** → Gatekeeper warning on other Macs ("Open Anyway" needed).
- A friend already has v1.0 (no updater). They must install the first updater-enabled build once.
- Old installer workarounds (`Install Pulse*.command`, `PulseInstaller*.zip`) in ~/Downloads are
  obsolete — can be deleted.

## Next steps (what Troy asked for: "ship this properly and automatically")

1. `git init`, `.gitignore` (already present), first commit.
2. **GitHub**: repo **already created** — `https://github.com/troymeekhof/pulse` (PRIVATE, empty).
   Add it as `origin` and push `main`. Because it's private, Sparkle can't download release assets
   from it anonymously: either make it public, or create a public releases-only repo
   (e.g. `troymeekhof/pulse-releases`) for appcast.xml + update archives. Ask Troy which.
3. **Sparkle 2** auto-updates: add via SwiftPM, embed `Sparkle.framework` in
   `Contents/Frameworks` (add rpath `@executable_path/../Frameworks`), `SUFeedURL` +
   `SUPublicEDKey` in Info.plist, `SPUStandardUpdaterController`, "Check for Updates…" in gear menu,
   automatic daily checks. Generate EdDSA keys with Sparkle's `generate_keys` (private key stays in
   Troy's Keychain). Appcast hosted from the GitHub repo/Pages; archives in GitHub Releases.
4. **Developer ID** (Troy enrolling in Apple Developer Program): sign with
   `--options runtime --timestamp`, sign Sparkle's nested helpers properly (don't rely on `--deep`),
   notarize with `xcrun notarytool submit --keychain-profile pulse-notary --wait`, staple app + DMG.
   No sandbox (app needs IOKit SMC, nettop, pmset). Never handle Troy's passwords — he runs
   `notarytool store-credentials` himself.
5. A single `./release.sh <version>` that bumps CFBundleShortVersionString/CFBundleVersion, builds
   universal, signs, notarizes, staples, makes DMG + Sparkle zip, signs the update, updates
   appcast.xml, creates the GitHub release and uploads assets.
6. Possible follow-ups Troy mentioned: Ethernet link-speed indicator on the Network card
   (warn at 100 Mbps), Internet vs local-network split, built-in `networkQuality` speed test button,
   prefer discrete GPU on dual-GPU Intel Macs.
