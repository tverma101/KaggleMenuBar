# Kaggle (Kernel Watch)

Kaggle is a menu bar app for checking whether your Kaggle notebooks are queued or running without opening the Kaggle website.

It uses Kaggle's official command line client for sign-in and notebook status. The app does not store Kaggle credentials itself. After you choose **Connect Kaggle**, the official CLI handles its OAuth flow and stores its own credentials. The app then checks your 100 most recently run notebooks every two minutes and shows only queued or running jobs.

## In the menu bar

The item is a Kaggle-blue capsule with Kaggle's white **k**, a stack of overlapping circles, one per active notebook, and a time:

- **Green** circle: running. **Orange** circle: queued. Running circles come first.
- The time is how long the longest-running notebook has been going (or the longest wait, when nothing has started yet), from Kaggle's `lastRunTime`: `now`, `47m`, `1h12m`, `11h`.
- Up to four circles fit; with more, the first three are followed by a white `+N` circle.
- A hollow white circle means the first status check is still in progress; a yellow `!` circle means the last check failed.

Clicking the item opens a panel listing each notebook with its status and elapsed time. Hovering shows the same summary as a tooltip.

The menu bar item stays available before connection and during the first status check. After a successful check, it hides when no notebooks are queued or running, reappears when activity is found, and stays visible if a status check fails so the error can be read.

## Requirements

- macOS 14 or later
- Swift 6 toolchain
- Kaggle CLI installed and available to the app

Install the official CLI following its [installation guide](https://github.com/Kaggle/kaggle-cli#installation). The current CLI requires Python 3.11 or later. Then launch the app and choose **Connect Kaggle** once.

## Install

```sh
./script/build_and_run.sh --install
```

This builds `Kaggle.app`, copies it to `~/Applications` (moving any older copy to the Trash) and opens it. Afterwards, launch it like any other app: type "Kaggle" in Spotlight, or open it from Launchpad or Finder. The app is menu-bar-only and does not add a Dock icon.

## Build and run

```sh
./script/build_and_run.sh
```

The script creates `dist/Kaggle.app` and opens it from the repository without installing it. To build without opening the app:

```sh
swift build
```

To check the menu bar layout without a Kaggle account, launch the built app with sample data. Valid values: `mixed`, `running`, `queued`, `many`, `checking`, `error`, `idle`, `disconnected`, and `cycle` (hides and shows the item every eight seconds).

```sh
open -n --env KERNEL_WATCH_DEMO=mixed dist/Kaggle.app
```

## Menu bar managers on macOS 27

Hidden Bar 1.11.1 hides items on macOS 27 with the system's assessment-mode restriction. Two known problems follow from that, and neither can be fixed inside this app:

- The item can stay hidden while Hidden Bar is collapsed even after you ⌘-drag it to the visible side ([dwarvesf/hidden#429](https://github.com/dwarvesf/hidden/issues/429)). Hidden Bar also reads its sections only when it collapses, so an item that appears while it is collapsed stays hidden until the next expand and collapse.
- Clicking the clock does not open Notification Center while Hidden Bar is collapsed ([dwarvesf/hidden#410](https://github.com/dwarvesf/hidden/issues/410)).

The app icon is drawn by `swift script/make_icon.swift`, which writes `Resources/AppIcon.icns`.

## What it checks

- Lists your own notebooks, sorted by most recent run.
- Checks each notebook's latest run with `kaggle kernels status`.
- Shows queued and running notebooks in the menu bar popover; selecting a row opens that notebook on Kaggle.
- Hides its menu bar item while connected and idle; it returns when a queued or running notebook is detected.
- Refreshes every two minutes while connected, with a manual refresh button.

The first version checks up to 100 notebooks per refresh. Kaggle exposes latest-run status per notebook, so accounts with more than 100 notebooks may need a later configurable watch list.

The app only reads status. It does not submit, edit, or delete notebooks. Connecting and refreshing uses your existing Kaggle CLI authentication; no Kaggle account calls happen until you choose **Connect Kaggle**.
