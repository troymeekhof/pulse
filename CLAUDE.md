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

## Updates & releases (free — no Apple Developer Program)

- Repo `troymeekhof/pulse` is **public** so Sparkle can download release assets anonymously.
- **Sparkle 2** (SwiftPM) — `Updater` in PulseApp.swift starts at launch; daily automatic checks,
  installs silently (`SUAutomaticallyUpdate`); gear menu → "Check for Updates…" + version.
  Feed: `appcast.xml` on main (raw.githubusercontent). `SUPublicEDKey` in Info.plist; the EdDSA
  **private key lives only in Troy's login Keychain** — back it up with
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x <file>`; losing it means installed copies
  can never be updated again.
- `build.sh` assembles/signs in `$TMPDIR/pulse-build` (iCloud-synced ~/Documents breaks codesign),
  embeds Sparkle.framework, signs inside-out. `SIGN_IDENTITY` env var (default ad-hoc `-`);
  hardened runtime only with a real identity.
- **Ship an update:** `./release.sh 1.2 "notes"` — clean tree required. Bumps Info.plist, builds
  universal, zips + DMG, `sign_update`, GitHub release, prepends appcast item, pushes.
- Still ad-hoc signed → first install on a new Mac needs "Open Anyway" once; updates after that
  are automatic. Friend on v1.0 (pre-updater) must install the DMG manually once:
  https://github.com/troymeekhof/pulse/releases/latest/download/Pulse.dmg

## Possible follow-ups

- Developer ID + notarization if Troy ever joins the Apple Developer Program ($99/yr): set
  `SIGN_IDENTITY`, add `notarytool` + staple to release.sh. Never handle Troy's passwords.
- Ethernet link-speed indicator on the Network card (warn at 100 Mbps), Internet vs local-network
  split, built-in `networkQuality` speed test button, prefer discrete GPU on dual-GPU Intel Macs.
