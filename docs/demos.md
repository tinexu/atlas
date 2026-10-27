# ATLAS demo checklists

Run every list on the real setup: **laptop alone**, then **laptop + external monitor** (if you use one).
Tick a box only when it behaves exactly as written. Anything else goes in the "Found" list at the end,
gets fixed with a test that would have caught it, and the demo is run again.

Before starting: `./scripts/build-app.sh --install`, open `/Applications/ATLAS.app`, and check
Permissions shows Accessibility, Notifications and (for Stage 7) Calendars as granted.

## Stage 1 — Automation engine and app shell
- [ ] Automations → New Automation → add "Launch App: Terminal" → Run. Terminal opens; Run History shows the run as Succeeded with the step's timing.
- [ ] Add a step with a bundle ID that doesn't exist → Run. The run fails at that step with "No installed app has the bundle identifier …", earlier steps still show as succeeded.
- [ ] Menu bar → Pause Automations. Run from the menu bar: the run is recorded as skipped. Resume.
- [ ] Close the main window. ATLAS stays in the menu bar and menu-bar runs still work.

## Stage 2 — Spaces
- [ ] Spaces → 3D world shows your rooms. Double-click Coding Lab: its apps open, status becomes Ready, ⌘1…⌘9 activate Spaces.
- [ ] Switch to another Space with "minimize previous" set: the previous Space's apps minimize.
- [ ] Edit a room object to run an action; clicking it in 3D runs it and Run History says "Room object".

## Stage 3 — Windows
- [ ] Window Manager → capture a layout called Programming with two apps side by side. Move the windows away, apply Programming: both go back.
- [ ] Attach Programming to Coding Lab's profile; activating Coding Lab ends with "Arrange windows: Programming".
- [ ] With an external monitor: unplug it. Windows on it come back to the laptop; Companion stays on screen; plug back in → "display.changed" suggestion offers a layout (if one was made for two displays).
- [ ] Save a snapshot, quit a couple of apps, restore the snapshot: they reopen and windows return.

## Stage 4 — Flow
- [ ] Open the "Coding Setup" demo; switch between 2D canvas and 3D galaxy; run it from the editor and watch nodes light up.
- [ ] Add a File Created trigger on ~/Downloads with a condition (extension pdf) → move to ~/Downloads/PDFs. Drop a PDF in Downloads: it moves; Run History shows the trigger payload.
- [ ] Break a step on purpose → the run shows the failing node, "Fix" opens the editor centred on it.

## Stage 5 — Orbit
- [ ] Orbit → Folders → add Downloads and Desktop; indexing finishes; Universe shows planets and moons.
- [ ] Rules → turn on "Screenshots into a folder"; ⌘⇧3 → the screenshot moves to Desktop/Screenshots within seconds; the index shows it at the new path.
- [ ] Duplicates → scan → trash one copy → Run History → Undo: it comes back.
- [ ] Mac Health → add a free-disk warning above current free space → Notify Me with Flow → a notification arrives.
- [ ] Search `ext:pdf size:>1mb` finds files; "Show me what's taking up storage" (Companion) lands on Largest Files.

## Stage 6 — Companion
- [ ] The robot sits in a corner, clicks pass through it. Press the Companion shortcut (or ⌘⇧Space): the palette opens with the cursor in it.
- [ ] Type "open my coding room" → preview "Activate Coding Lab — Deep Work" → Return → the robot animates and the bubble says "Coding Lab ready".
- [ ] Break a workflow (bad app ID), run it: the robot shows failure and the bubble explains the fix with a "Fix the Step" button.
- [ ] Turn AI off (Companion settings) and repeat the commands: they still work.
- [ ] Drag the robot to another place, restart ATLAS: it comes back there. Unplug the monitor it was on: it moves onto the laptop screen.

## Stage 7 — Time Architect
- [ ] Palette: "I'm going to work on my app for the next two hours" → "Activate Coding Lab — Deep Work and start a 2 h focus block" → Return. Apps open, windows arrange, the block appears on the timeline, the menu bar counts down.
- [ ] Turn on Calendar (Time Architect → Settings → Calendar). Make a "Team Sync" event 12 minutes from now. At 10 minutes the Companion offers "Save your Coding Lab layout and switch to Meeting Room?" → accept → the layout is saved and Meeting Room opens.
- [ ] Afterwards activate Coding Lab again → "Restore where you left off" brings the coding layout back.
- [ ] Automations → Describe… → "When I open Blender, activate Creative Studio" → review → Open as Draft → turn it on → open Blender → Creative Studio activates.
- [ ] Day view: drag a block, resize it, use ↑/↓ and ⇧↑/⇧↓. Week and Agenda show the same blocks; overlapping blocks are outlined red with a "Move …" fix.

## Stage 8 — Daily use
- [ ] ATLAS starts at login (menu bar → Start ATLAS at Login) from /Applications.
- [ ] Sleep the Mac for 10+ minutes during a scheduled block's start → on wake it starts (or is marked missed, per the block); nothing runs after the block has ended.
- [ ] Lock/unlock: the Companion stops animating while locked.
- [ ] Unplug the monitor mid-activation: the run finishes with a partial result, nothing hangs.
- [ ] Wi-Fi off with cloud AI on: the palette says AI failed and uses built-in commands within ~25 s.
- [ ] Turn off Accessibility in System Settings during a layout apply: the run fails cleanly with "Grant Accessibility"; ATLAS shows a banner.
- [ ] Quit ATLAS (⌘Q) while a "move file" workflow runs. Relaunch: the file is either moved or untouched, never duplicated; Run History shows the interrupted run as failed.
- [ ] ~/Library/Application Support/ATLAS/Backups has today's backup; after a week there are 7.
- [ ] File → Export Data…, then File → Import Data… on the same file: nothing changes, nothing is duplicated.
- [ ] Activity Monitor with only the menu bar and Companion showing: ATLAS under 1% CPU, Energy Impact "Low". Low Power Mode on → 3D views and the robot stop animating.

## Found
<!-- date · what happened · fixed in (commit / test name) -->
