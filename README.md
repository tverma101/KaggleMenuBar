# Kaggle (Kernel Watch)

Kaggle is a menu bar app for checking whether your Kaggle notebooks are queued or running without opening the Kaggle website.

It uses Kaggle's official command line client for sign-in and notebook status. The app does not store Kaggle credentials itself. After you choose **Connect Kaggle**, the official CLI handles its OAuth flow and stores its own credentials. The app then checks your 100 most recently run notebooks every minute and shows only queued or running jobs.

## In the menu bar

The item is a muted graphite capsule with a soft white **k**, a stack of overlapping circles, one per active notebook, and a time:

- **Sage green** circle: running. **Amber** circle: queued. Running circles come first.
- The time is how long the longest-running notebook has been going (or the longest wait, when nothing has started yet): `now`, `47m`, `1h12m`, `11h`. Kaggle reports no queue-entry time, and a re-pushed notebook keeps its previous `lastRunTime`, so the time counts from the later of `lastRunTime` and the agent's `kaggle-hub track` call. An untracked notebook whose listed time is over 12 hours old counts from when the hub first saw it active.
- Up to four circles fit; with more, the first three are followed by a pale `+N` circle.
- A hollow pale circle means the first status check is still in progress; a muted yellow `!` circle means the last check failed.

Clicking the item opens a panel listing each notebook with its status and elapsed time. Hovering shows the same summary as a tooltip.

The menu bar item stays available before connection and during the first status check. After a successful check, it hides when no notebooks are queued or running, reappears when activity is found, and stays visible if a status check fails so the error can be read. Hiding shrinks the item to zero width instead of removing it, so it keeps its menu bar position, including its side of Hidden Bar's arrow, and asks Hidden Bar to hide it fully (see below).

## Requirements

- macOS 14 or later
- Swift 6 toolchain
- Kaggle CLI installed and available to the app

Install the official CLI following its [installation guide](https://github.com/Kaggle/kaggle-cli#installation). The current CLI requires Python 3.11 or later. Then launch the app and choose **Connect Kaggle** once.

## Install

```sh
./script/build_and_run.sh --install
```

This builds and ad-hoc signs `Kaggle.app`, copies it to `/Applications` (moving any older copy to the Trash) and starts it with the launch agent `~/Library/LaunchAgents/app.kernelwatch.KernelWatch.plist`, which starts it at login and restarts it if it crashes. Quitting from the panel stays quit until the next login or launch. A failed build leaves the running app untouched. Afterwards, launch it like any other app: type "Kaggle" in Spotlight, or open it from Launchpad or Finder. Reopening the running app opens its status panel even while the menu bar item is hidden. The app is menu-bar-only and does not add a Dock icon.

## Build and run

```sh
./script/build_and_run.sh
```

The script creates `dist/Kaggle.app` and opens it from the repository without installing it. This stops the launch agent so only one copy runs; run `./script/build_and_run.sh --install` afterwards to restore normal monitoring. To build without opening the app:

```sh
swift build
```

To check the menu bar layout without a Kaggle account, launch the built app with sample data. Valid values: `mixed`, `running`, `queued`, `many`, `checking`, `error`, `idle`, `disconnected`, and `cycle` (hides and shows the item every eight seconds).

```sh
open -n --env KERNEL_WATCH_DEMO=mixed dist/Kaggle.app
```

## Menu bar managers on macOS 27

Hidden Bar 1.11.1 hides items on macOS 27 with the system's assessment-mode restriction, which only honours apps running from `/Applications`. A copy anywhere else (`dist/`, `~/Applications`) is hidden even when placed right of Hidden Bar's arrow ([dwarvesf/hidden#446](https://github.com/dwarvesf/hidden/issues/446)), so check demo runs from `dist/` with Hidden Bar expanded.

- Kaggle tells Hidden Bar when its item goes idle or active (the `com.dwarvesv.minimalbar.statusItemsIdle` and `statusItemsActive` distributed notifications). A Hidden Bar build that understands them (the local build in `~/Projects/HiddenBar`) hides the idle item while collapsed, with no gap. Other builds show the zero-width item's gap of about 10 pt.
- The local Hidden Bar build lets in apps that launch while it is collapsed and keeps new icons visible until you ⌘-drag them left of the arrow. Upstream 1.11.1 reads its sections only when it collapses, so an item that appears while collapsed can stay hidden until the next expand and collapse.
- Clicking the clock does not open Notification Center while Hidden Bar is collapsed ([dwarvesf/hidden#410](https://github.com/dwarvesf/hidden/issues/410)).

The app icon is drawn by `swift script/make_icon.swift`, which writes `Resources/AppIcon.icns`.

## What it checks

- Lists your own notebooks, sorted by most recent run.
- Checks each notebook's latest run with `kaggle kernels status`.
- Skips list entries without a usable `owner/notebook` reference; they cannot be queried by the CLI. A list containing only unusable entries reports an error rather than claiming the account is idle.
- Shows queued and running notebooks in the menu bar popover; selecting a row opens that notebook on Kaggle.
- Hides its menu bar item while connected and idle; it returns when a queued or running notebook is detected.
- Keeps setup, the first check, and status-check errors visible. Refreshing an idle account does not briefly bring the item back. Open Kaggle again to view its panel or refresh manually while hidden.
- Failed checks show a retry message instead of leaving the initial-check spinner running.
- Checks every minute while connected, with a manual refresh button. `kaggle-hub track` wakes the app with a local notification, so a tracked push appears within seconds.
- Uses `kaggle-hub monitor-snapshot`, sharing discovery, project links, status results and the request budget with repository agents. The most recently run 100 notebooks are re-listed every minute, so an untracked push appears within about two minutes; older pages are re-listed every 15 minutes. Project names appear in active notebook rows.
- Counts a just-pushed notebook that Kaggle still reports as `NEW_SCRIPT` as queued for its first hour; older `NEW_SCRIPT` drafts are ignored.
- The first full check can take several minutes on a large account. Shared requests are spaced three seconds apart. Queued/running statuses are cached for two minutes and finished runs until their listed run time changes (at most 30 days). A rate-limit response pauses all shared readers for five minutes. `kaggle-hub notebooks` shows the saved inventory without making provider requests.

The first version checks up to 100 notebooks per refresh. Kaggle exposes latest-run status per notebook, so accounts with more than 100 notebooks may need a later configurable watch list.

The app only reads status. It does not submit, edit, or delete notebooks. Connecting and refreshing uses your existing Kaggle CLI authentication; no Kaggle account calls happen until you choose **Connect Kaggle**.
