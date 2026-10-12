# Power Modes

A menu bar app that sets the macOS power mode (Low Power / Automatic / High Power) from the battery charge, with sliders for the thresholds.

## Thresholds

Each power source has two sliders:

- **High Power from** — the minimum charge for High Power. All the way right is "Never".
- **Automatic from** — the minimum charge for Automatic. Anything below it is Low Power; 0% means Low Power is never used.

Dragging one slider past the other moves the other along, so the Automatic minimum never exceeds the High Power minimum.

Defaults:

| Battery charge | On AC Power | On Battery Power |
| --- | --- | --- |
| 0–20% | Low Power | Low Power |
| 21–50% | Automatic | Low Power |
| 51–79% | Automatic | Automatic |
| 80–100% | High Power | Automatic |

| Slider | AC Power | Battery Power |
| --- | --- | --- |
| High Power from | 80% | Never |
| Automatic from | 21% | 51% |

### Hysteresis

A mode steps up as soon as the charge reaches its threshold, but steps down only once the charge is 3 points below it (`Policy.hysteresisMargin`). With the defaults, High Power on AC starts at 80% and is kept down to 77%, ending at 76%; Automatic on AC ends at 17%, and on battery at 47%. This stops the mode flipping when the charge hovers at a threshold, such as 79–80% on a charge-limited Mac.

The margin is measured from the mode the profile is in now, so it also applies to a mode set by hand in System Settings. Moving a slider applies the thresholds exactly, with no margin, so the result matches what the sliders show.

Settings are saved in the `io.github.chrisfalck.power-modes` defaults domain. "Reset to Defaults" restores the table above. "Switch modes automatically" off leaves the modes wherever they are.

## How it works

- The app re-evaluates when the charge or power source changes, on wake, every 60 seconds, and shortly after a slider settles.
- Both profiles (AC and battery) are kept at the mode their thresholds give for the current charge, so plugging in or unplugging lands in the right mode immediately.
- A mode that is already correct is left alone.
- The menu bar icon shows the mode in use: bolt (Automatic), filled bolt (High Power), leaf (Low Power), slashed bolt (switching off), warning triangle (a change failed; open the menu for the reason).
- Changes and errors are logged to `~/Library/Logs/Power Modes.log`.

### Root helper

Changing the power mode needs root, so the app calls a small helper through `sudo -n`:

- Helper: `/Library/PrivilegedHelperTools/io.github.chrisfalck.powermodes.helper` (root-owned, source in `Helper/power-modes-helper.m`).
- Rule: `/etc/sudoers.d/power-modes-helper` allows the installing user to run exactly twelve commands without a password: `--switch` or `--set`, source `b` or `c`, mode `0`, `1` or `2`.

`--switch` is used for the power source in use. It holds CoreBrightness's `CBDisplayPresetLockBrightnessUpdates` lock while `pmset` runs so the display does not dim during the transition, with a watchdog that releases the lock within 20 seconds whatever happens. It never sets a brightness level, does not wake a sleeping display, and leaves an existing lock alone. If the lock cannot be taken on an awake display, the change is refused and the app shows the error. The lock is a private API, so check the log after macOS upgrades.

`--set` is a plain `pmset -b|-c powermode N` for the source not in use, where nothing on screen changes.

If the helper reports a failure but `pmset -g custom` shows the requested mode, the app counts the change as made and logs the helper's message as a warning.

## Install

```sh
./scripts/install-app.sh
```

Builds the app, copies it to `~/Applications/Power Modes.app`, and adds the launch agent `~/Library/LaunchAgents/io.github.chrisfalck.power-modes.plist` so it starts at login (and restarts after a crash, but not after Quit).

```sh
sudo ./scripts/install-helper.sh
```

Installs the root helper and the sudoers rule, then checks that the rule is in effect.

Instead of the second command, you can click **Install Helper…** in the app's popover. It runs the same script (bundled in the app with the helper) through the macOS administrator prompt. The button shows whenever the helper is missing or the sudoers rule is not in effect.

Until the helper is installed, the app shows the modes but cannot change them.

## Checks

```sh
swift test
"$HOME/Applications/Power Modes.app/Contents/MacOS/PowerModes" --dry-run
"$HOME/Applications/Power Modes.app/Contents/MacOS/PowerModes" --snapshot /tmp/popover.png
pmset -g custom
sudo -n -l /Library/PrivilegedHelperTools/io.github.chrisfalck.powermodes.helper --set c 0
```

`swift test` covers the default thresholds at every charge for both sources, threshold boundaries and clamping, hysteresis, the both-profile plan for every combination of starting modes, and `pmset -g custom` parsing. `--dry-run` prints what the saved settings would do now without changing anything. `--snapshot` renders the popover to a PNG.

## Uninstall

```sh
./scripts/uninstall.sh
```

```sh
sudo ./scripts/uninstall.sh
```

The first removes the app and launch agent, the second the helper and sudoers rule. Power modes stay as they were last set.

## Layout

- `Sources/PowerPolicy` — thresholds, the plan, `pmset` parsing (no system calls; unit tested).
- `Sources/PowerModes` — the menu bar app.
- `Helper` — the root helper.
- `scripts` — build, install, uninstall.
