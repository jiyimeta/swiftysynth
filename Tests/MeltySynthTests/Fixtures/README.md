# Test fixtures

Committed, derived test vectors for the spike gates. The 32 MB GeneralUser GS
font itself is NOT committed (it would bloat every SwiftPM consumer's clone
forever); fixture-dependent tests reference it at an absolute path and skip
when it is absent.

## Reference SF2

- Locked path: `GeneralUser-GS.sf2`
- SHA-256: (recorded in Task 5 from the render-note sidecar)

## Pinned reference implementations (gitignored clones under `.reference/`)

| Repo | URL | Ref | Commit |
|------|-----|-----|--------|
| meltysynth (C#, canonical porting source) | https://github.com/sinshu/meltysynth | `v2.4.1` | `1ad7ba0b9f7324461b08aeca75a220ab1253de56` |
| rustysynth (oracle) | https://github.com/sinshu/rustysynth | `v1.3.6` | `8cc11fc0b10422adb54107757f100d3d6ae0ef96` |
| py-meltysynth (f64 debug microscope — never a tolerance reference) | https://github.com/sinshu/py-meltysynth | `main` | `a12a34fe811bfdfb9311c115960a7921de6e4efb` |

## Regeneration (manual — tests never invoke the oracle)

Recorded in Task 5 once the vectors are generated.
