# Kaggle menu bar monitor

Source is here; the installed app is `/Applications/Kaggle.app` so Hidden Bar
can keep it visible on macOS 27. Keep the project in the excluded Projects
folder and the installed app searchable.

- All production notebook reads use the existing `kaggle-hub` shared cache,
  request pacing and rate-limit cooldown. Never add another account-wide CLI
  sweep or a polling subprocess per notebook.
- The hub source is `../vid_pdf/tools/kaggle-compute-hub`. Its README describes
  `notebooks`, `track`, `link-project`, `sync`, `check` and `cleanup-plan`.
- The newest notebook page is re-listed every minute (older pages every 15
  minutes). `track` wakes the app and sets the elapsed-time start for a
  re-pushed run. Project prefix links apply automatically; agents use `track`
  to provide exact project/task provenance.
- The installed app runs under the launch agent `app.kernelwatch.KernelWatch`.
  Idle collapses the item to zero width; never set `isVisible = false`, which
  loses its position under Hidden Bar. Idle and active are also announced to
  Hidden Bar (`StatusItemController.announcePresence`), which hides the idle
  item without the zero-width gap; keep both.
- Hide only after a successful idle snapshot. Setup, incomplete checks and
  errors stay reachable. Reopening from Spotlight must open the panel while idle.
- A failed check must not show an endless first-check spinner or claim idle.
- Run `swift test`, then `./script/build_and_run.sh --install` for app changes.
  Keep normal monitoring restored after demo checks. Do not start cloud compute
  or perform remote cleanup as part of UI verification.
