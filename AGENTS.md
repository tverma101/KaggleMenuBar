# KaggleMenuBar

A macOS menu bar app (SwiftPM, AppKit with SwiftUI panels) showing queued and
running Kaggle notebooks. `README.md` describes the behavior users rely on;
keep it current when that behavior changes. If `AGENTS.local.md` exists, read
it too: it holds machine-specific paths and is not committed.

- Status reads go through the activity source (`auto`, `hub`, `direct`). With
  kaggle-hub installed, use its shared cache, request pacing and rate-limit
  cooldown. Never add another account-wide CLI sweep or a polling subprocess
  per notebook. `hub-template/README.md` is the hub's contract; keep the app's
  decoder and the template in step.
- Never test direct mode against a real account; use the fixtures in
  `Tests/KaggleMenuBarTests`.
- The bundle identifier, launch agent label `app.kernelwatch.KernelWatch`,
  the Darwin notification `app.kernelwatch.KernelWatch.refresh` and the
  status item autosave name are kept from the app's first name so installed
  copies keep working. Do not rename them.
- Idle collapses the item to zero width; never set `isVisible = false`, which
  loses its menu bar position. Idle and active are also announced to Hidden
  Bar (`StatusItemController.announcePresence`); keep both.
- Hide only after a successful snapshot with nothing to show: no active runs,
  or only runs on hardware the user filtered out. Setup, incomplete checks and
  errors stay reachable. Reopening the app must open the panel while idle.
- A failed check must not show an endless first-check spinner or claim idle.
  Transient failures are retried quietly once before an error shows.
- Diagnostic log entries go through `DiagnosticLog`, which redacts secrets.
  Never log tokens, keys or full Kaggle CLI configuration.
- Run `swift test` and the hub tests (`python3 -m unittest discover -s
  hub-template/tests`), then `./script/build_and_run.sh --install` for app
  changes. Check menu bar changes with `KAGGLE_MENUBAR_DEMO` scenarios and the
  `PILL_GALLERY` render, and restore normal monitoring afterwards.
- Do not start Kaggle compute or delete anything remote as part of testing.
