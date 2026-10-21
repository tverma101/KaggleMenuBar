# kaggle-hub reference implementation

`kaggle-hub` is a small executable that sits between the Kaggle CLI and its callers. The KaggleMenuBar app and your own scripts or agents can all call it, so they share one cache and one request budget instead of each polling Kaggle on its own. This directory is the public reference for its contract. It uses only the Python 3.11+ standard library.

## Contract

`kaggle-hub monitor-snapshot` prints one JSON object on stdout and exits 0:

```json
{"activeRuns":[{"ref":"owner/slug","title":"str","status":"QUEUED","lastRunAt":"2026-10-19T12:00:00.000000","project":null}],
 "notebooksChecked":1,"unavailableCount":0,"checkedAt":1792411200.0}
```

- `status` is `QUEUED` or `RUNNING`.
- `lastRunAt` is UTC with no zone suffix, in the format `%Y-%m-%dT%H:%M:%S.%f`, or `null`.
- `project` is a string or `null`.
- `notebooksChecked` counts the usable notebooks in the Kaggle list, plus tracked notebooks that the list does not show yet.
- `unavailableCount` counts notebooks Kaggle refused to report on (403, 404 or "Cannot access kernel"), plus list rows that had no valid `owner/slug` ref.
- `checkedAt` is the Unix time in seconds when the snapshot finished.
- Nothing else is printed to stdout.

On failure the command exits 2 and prints exactly one line to stderr, `kaggle-hub: <message>`. Messages are at most 300 characters and have `Bearer` tokens, `KGAT_` keys and `api_key`, `token` or `secret` values removed.

`kaggle-hub track REF [--project NAME]` records that a notebook was just pushed. `REF` is `owner/slug` or `https://www.kaggle.com/code/owner/slug`. The notebook's elapsed time starts now, and the next snapshot re-checks its status. On macOS the command then posts the Darwin notification `app.kernelwatch.KernelWatch.refresh` so the app refreshes. It prints `{"ref":"owner/slug","trackedAt":1792411200.0}`.

## How a snapshot works

The hub runs `kaggle kernels list --mine --sort-by dateRun --page-size 100 --format json` and then `kaggle kernels status REF` only for notebooks that may have changed. All other notebooks are assumed finished. A notebook gets a status call when any of these holds:

1. It was last seen as queued, running or unknown (or never checked), and its listed run time is within the last 13 hours.
2. Its listed run time changed since the previous snapshot.
3. It is one of the 5 most recent runs within 24 hours and its last check is more than 120 seconds old.
4. It was tracked within the last hour.

`CANCEL_REQUESTED` is reported as `RUNNING`. `NEW_SCRIPT` is reported as `QUEUED` when the run started within the last hour, and is otherwise treated as an inactive draft. An unrecognized status is an error.

`lastRunAt` is the track time if it is newer than the listed run time. Otherwise, if the notebook was first seen active more than 12 hours after its listed run time, it is that first-seen time. Otherwise it is the listed run time, or the first-seen time when there is no listed run time.

## Shared state and request budget

- State lives in `$KAGGLE_HUB_STATE_DIR`, default `~/.local/state/kaggle-hub-template/` (mode 0700), as one JSON file written atomically. A `flock` on a lock file serializes processes for the whole snapshot.
- Kaggle CLI calls are spaced at least `$KAGGLE_HUB_MIN_INTERVAL` seconds apart across processes (default 2.0).
- Each CLI call times out after 60 seconds.
- When the CLI reports `429` with `Too Many Requests` or `rate limit`, the hub stores a 300 second cooldown. Until it ends, every snapshot fails with `kaggle-hub: Kaggle rate limit: retry in N seconds.` without calling the CLI.
- The Kaggle executable is `$KAGGLE_CLI_PATH` if set, otherwise `kaggle` from `PATH`.
- Set `KAGGLE_HUB_NO_NOTIFY=1` to skip the Darwin notification, which the tests do.

## Install

```sh
install -m 755 hub-template/kaggle-hub ~/.local/bin/kaggle-hub
```

The app looks for the executable at `$KAGGLE_HUB_PATH`, then `~/.local/bin/kaggle-hub`, then `/opt/homebrew/bin/kaggle-hub`. If none exists, the app polls the Kaggle CLI directly.

## Calling track from a script

Call `track` right after a successful push so the app shows the run at once:

```sh
kaggle kernels push -p ./my-notebook && kaggle-hub track owner/slug --project my-project
```

## Tests

```sh
python3 -I -m unittest discover -s hub-template/tests -v
```

The tests replace the Kaggle CLI with a fake script and use a temporary state directory, so they make no network calls.
