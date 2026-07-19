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

Measured on macOS, layers = 8, same MIDI file, `GeneralUser-GS.sf2`:

| build                              | current % of budget | max %  | meter | active voices |
| ----------------------------------- | -------------------- | ------ | ----- | -------------- |
| Debug (plain, no fix)               | 253–284%             | 374%   | RED   | 54–61           |
| Release (fully optimized)           | 11–14%               | 18–24% | GREEN | ~93             |
| Release + app forced `-Onone` (fix) | 24–26%               | 36%    | GREEN | 86–112          |

### The fix — optimize the dependency, keep your app debuggable

Release already optimizes everything, so a plain Release run is fine as-is.
For a build where **your own app code stays unoptimized/debuggable** while
**SwiftySynth (the dependency) is fast**, the natural first attempt — set
`SWIFT_OPTIMIZATION_LEVEL: "-O"` project-wide for the **Debug** configuration,
then override it back to `-Onone` on the app targets — does **not** work:

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
run the **Release** configuration (where SwiftySynth genuinely gets `-O`,
as confirmed by the same build-log check), and add a **target-level**
override forcing only the app's own target back to `-Onone` for Release.
Target-level overrides *do* reach ordinary targets — that's the mechanism
above that failed for the *package*, but works fine for *your own code*.

`Examples/Apple/project.yml` (already applied to both `SwiftySynthExample`
and `SwiftySynthExampleMac`):

```yaml
targets:
  SwiftySynthExample:      # and SwiftySynthExampleMac, same block
    settings:
      configs:
        Release:
          SWIFT_OPTIMIZATION_LEVEL: "-Onone"   # keep the APP debuggable;
          # SwiftySynth still builds -O because the configuration is Release.
```

Then build/run the **Release** configuration when you want SwiftySynth fast
and your own code debuggable (Xcode: Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸
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

For swift-sheet-music / Folino-iOS: the same limitation applies to any local
or remote SwiftPM dependency. Apply the same target-level
`SWIFT_OPTIMIZATION_LEVEL: "-Onone"` override on your own app target(s) for
the **Release** configuration in their `project.yml` / Xcode build settings,
and use a Release run (not Debug) whenever you need the dependency's DSP/hot
path to run at full speed with your own code still debuggable.
