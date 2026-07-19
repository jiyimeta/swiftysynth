# SwiftySynth examples

## Apple (iOS + macOS) — real-time performance demo

`Apple/` is a SwiftUI app that plays a MIDI file through
`MidiFileSequencer → Synthesizer → AVAudioEngine` (the same real-time path
Folino / swift-sheet-music use) and shows a live **render-cost meter** (% of
the real-time audio budget). It exists to reproduce, standalone, the
"debug build gets noisy/slow/silent, release is fine" problem.

### Run

1. Install XcodeGen: `brew install xcodegen`.
2. Provide a SoundFont: copy `GeneralUser-GS.sf2` into
   `Apple/SwiftySynthExample/Sounds/` (gitignored), or set `SWIFTYSYNTH_SF2`.
3. Generate + open:
   ```
   xcodegen generate --spec Apple/project.yml --project Apple
   open Apple/SwiftySynthExample.xcodeproj
   ```
4. Run `SwiftySynthExample` (iOS) or `SwiftySynthExampleMac` (macOS), press
   **Play**, and raise **layers** to add load.

### What you'll see

- **Release build:** meter stays green (single-digit % of budget), clean audio.
- **Debug build:** as layers rise the meter goes **red (>100%)**, audio breaks
  up and eventually drops out — because the unoptimized DSP can't render within
  the real-time deadline. This is NOT a bug in SwiftySynth; the render cost is
  flat over time in both builds (measured), the debug build is simply ~50–66×
  slower per operation.

Running the **Release** configuration is optimizations-off-for-your-code, not
a full Debug environment: it compiles out every `#if DEBUG` block, leaves
`DEBUG` / `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` unset, and disables
assertions (`ENABLE_NS_ASSERTIONS = NO`). This app's own build badge will
even read "Build: Release" in that scenario — "app optimizations off,
debugger-steppable" is accurate; "Debug environment" is not. See "The fix"
below for what a Release run in this repo actually gives you.

Measured on macOS, layers = 8, same MIDI file, `GeneralUser-GS.sf2`:

| build                              | current % of budget | max %  | meter | active voices |
| ----------------------------------- | -------------------- | ------ | ----- | -------------- |
| Debug (plain, no fix)               | 253–284%             | 374%   | RED   | 54–61           |
| Release (fully optimized)           | 11–14%               | 18–24% | GREEN | ~93             |
| Release + app forced `-Onone` (fix) | 24–26%               | 36%    | GREEN | 86–112          |

The "Release (fully optimized)" row is **not** what a plain Release run gives
you out of the box: the shipped `project.yml` (see below) forces both app
targets to `-Onone` in their Release configuration, as the running demo of
the fix, so a plain `xcodebuild -configuration Release` reproduces the
24–26% row. To reproduce the 11–14% fully-optimized row, remove that
`SWIFT_OPTIMIZATION_LEVEL: "-Onone"` override from both targets and rebuild.

### The fix — run Release; optionally keep your own code unoptimized too

The primary fix is simply: **run the Release configuration.** That alone is
what makes SwiftySynth (the SwiftPM dependency) compile `-O` and clears the
cliff — see the "Release (fully optimized)" baseline row above (11–14%). No
`project.yml` change is required for this part. Remember the caveat above,
though: Release is "your code's optimizations off, still debugger-steppable,"
**not** a full Debug environment — `#if DEBUG` code is compiled out,
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` is unset, and assertions are
disabled.

If you additionally want **your own app code to stay unoptimized/debuggable**
while doing that Release run — which is what this demo does, to make the
"the DSP core is fast, only my own glue code is unoptimized" split visible —
the natural first attempt is to set `SWIFT_OPTIMIZATION_LEVEL: "-O"`
project-wide for the **Debug** configuration, then override it back to
`-Onone` on the app targets. That attempt does **not** work:

> Empirically verified (build log, `xcodebuild ... -configuration Debug`,
> grepping the `swiftc` invocations per module): a project-level Debug
> `SWIFT_OPTIMIZATION_LEVEL: "-O"` **is** correctly written into the
> `.pbxproj` and **is** correctly inherited by ordinary Xcode targets (the
> app target compiled `-O` when given no target-level override). But
> SwiftySynth — a local (`path:`) SwiftPM package dependency — still compiled
> `-module-name SwiftySynth -Onone` regardless. Xcode's built-in Swift
> Package integration decides a local package's optimization level purely
> from the **active build configuration's name** (`Debug` → `-Onone`,
> `Release` → `-O`); it does not consult the enclosing project's
> `SWIFT_OPTIMIZATION_LEVEL`, so no combination of Debug-scoped settings can
> make the dependency build optimized while the configuration is named
> `Debug`.

The setting **that does work** rides on that same fact from the other side:
stay on the **Release** configuration (where SwiftySynth genuinely gets `-O`,
as confirmed by the same build-log check), and add a **target-level**
override forcing only the app's own target back to `-Onone` for Release.
Target-level overrides *do* reach ordinary targets — that's the mechanism
above that failed for the *package*, but works fine for *your own code*.
Keep in mind this still doesn't turn Release into a Debug environment (see
the caveat above) — it only gets your own target's code back to unoptimized,
debugger-steppable codegen; `#if DEBUG` blocks, assertions, and the build
badge are still governed by the Release configuration, not by this override.

**This app hardcodes that override directly on its own Release
configuration** in `Examples/Apple/project.yml` (already applied to both
`SwiftySynthExample` and `SwiftySynthExampleMac`, marked `DEMO-ONLY` in the
YAML comments), specifically so that a plain `xcodebuild -configuration
Release` on this repo reproduces the fix numbers with zero extra setup:

```yaml
targets:
  SwiftySynthExample:      # and SwiftySynthExampleMac, same block
    settings:
      configs:
        Release:
          # DEMO-ONLY -- see the production warning below before copying
          # this onto a shipping app's archive configuration.
          SWIFT_OPTIMIZATION_LEVEL: "-Onone"   # keep the APP debuggable;
          # SwiftySynth still builds -O because the configuration is Release.
```

> **This is safe here because this example never ships/archives.** For any
> app you actually distribute, putting `-Onone` on the same Release
> configuration you archive with will ship an **unoptimized production
> binary**. See "For swift-sheet-music / Folino-iOS" below for the
> production-safe way to get the same effect.

Build/run the **Release** configuration when you want SwiftySynth fast and
your own code debuggable (Xcode: Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸
Build Configuration: Release; or `xcodebuild -configuration Release`).
Verified by build-log grep (`-module-name SwiftySynth -O` /
`-module-name SwiftySynthExampleMac -Onone`) and by the meter numbers in the
table above — comparable headroom to a full Release build, at layers = 8.

Note the small gap versus a fully-optimized Release build (24–26% vs.
11–14%): this app's own `RenderCore.render` — the thin per-layer dispatch
loop that calls into `Synthesizer` — is now the only unoptimized code left in
the hot path, so a `-Onone` dispatch wrapper around an `-O` DSP core still
costs a bit more than an all-`-O` build. Still solidly green, nowhere near
the Debug cliff.

Do **not** add `.unsafeFlags(["-O"])` to SwiftySynth's own `Package.swift`: it
would fix the build but make the library unusable as a versioned (`from:`)
dependency for everyone else.

### DevOptimized — recommended development configuration

`Apple/project.yml` also ships a third Xcode configuration, `DevOptimized`
(type: `release`), that gets you both halves of "The fix" above on every
day-to-day Run without remembering to swap configurations: it preserves
`#if DEBUG` / Swift `assert()`/`precondition()` and keeps your own app code
`-Onone` (debuggable), **while** SwiftySynth (the local SwiftPM dependency)
still compiles `-O` — Xcode decides a local package's optimization purely
from the build configuration's **type** (`debug` → `-Onone`, `release` →
`-O`), so any config typed `release` gets the dependency optimized,
regardless of what you name it:

```yaml
configs:
  Debug: debug
  Release: release
  DevOptimized: release

targets:
  SwiftySynthExample:      # and SwiftySynthExampleMac, same block
    settings:
      configs:
        DevOptimized:
          SWIFT_OPTIMIZATION_LEVEL: "-Onone"
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG"
          GCC_PREPROCESSOR_DEFINITIONS: "DEBUG=1 $(inherited)"
```

Verified on a fresh `-derivedDataPath` (rules out stale module-cache
effects) by build-log grep on the `swiftc` invocations:
`-module-name SwiftySynth -O` / `-module-name SwiftySynthExampleMac -Onone`
with `-DDEBUG` / `-Xcc -DDEBUG=1` active.

**Naming caveat:** name the extra configuration anything that does **not**
contain the substring `Debug`. A `release`-typed configuration literally
named `Debug-Optimized` failed to build in this Xcode toolchain (`error:
unable to resolve module dependency: 'SwiftySynth'` / "module file ... built
for incompatible target"), while the identical setup renamed to
`DevOptimized` built clean on a fresh derived-data path. The failure tracks
the **name**, not the extra config itself — a second `release`-typed
configuration is fine as long as its name doesn't contain "Debug".

(`ENABLE_NS_ASSERTIONS` — the Objective-C `NSAssert` toggle — still reads
`NO` under `DevOptimized`, inherited from the `release` config type; this app
is pure Swift so it doesn't matter here, but if you add Objective-C code and
need `NSAssert` too, add `ENABLE_NS_ASSERTIONS: YES` to the same
target-level override block.)

Build/run it via Xcode: Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Build
Configuration: `DevOptimized`; or `xcodebuild -configuration DevOptimized`.
Plain `Debug` and `Release` are unaffected by adding this configuration
(verified: both still build clean on a fresh derived-data path).

### For swift-sheet-music / Folino-iOS

The same SwiftPM-package-ignores-Debug-settings limitation applies to any
local or remote dependency, so the same two-step guidance applies — but
**Folino ships to the App Store, and its Release configuration is the
archive configuration**, so the ordering matters:

1. **Primary recommendation:** to develop/test with a working (non-cliff)
   audio path, **run the Release configuration.** That alone is what makes
   the SwiftPM dependency compile `-O` — no `project.yml` change is required
   for this step. Remember it's "your code's optimizations off," not a full
   Debug environment (see the caveat above).
2. **Optional refinement:** if you also want your own app code to stay
   `-Onone`/debuggable during those Release runs, that's a target-level
   `SWIFT_OPTIMIZATION_LEVEL: "-Onone"` override — but it **must not** land
   on the same Release configuration you archive/submit with, or the App
   Store build ships unoptimized. Scope it to one of:
   - a **dedicated local, non-distribution configuration** duplicated from
     Release (e.g. `DevOptimized` or `Profile` — see "DevOptimized" above)
     that only your own Run scheme ever selects, with the `-Onone` override
     on that duplicate. Avoid any name containing "Debug" — a `release`-typed
     configuration named `Debug-Optimized` failed to build in this Xcode
     toolchain (verified); or
   - an **uncommitted local `.xcconfig`** (outside version control) applied
     only to your personal development builds.

   Do **not** commit `-Onone` directly on Folino's real, archived Release
   configuration the way this demo app does on its own — this example gets
   away with it only because it never ships/archives.
