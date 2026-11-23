# desk-widgets

Desktop widgets and a small desktop buddy for [Quickshell](https://quickshell.org) on Hyprland.

- `shell.qml`: weather, system (CPU, RAM, temperature), battery and network cards on the desktop layer.
- `Pet.qml`: the buddy. Its eyes follow the cursor, it reacts to clicks and drags, its mood follows
  CPU temperature, battery and time of day, and it only shows on an empty workspace.
- `helpers/`: `lock-notify`, a small C helper that tells the buddy when the screen locks and unlocks.

## Install

```sh
git clone <this repo> ~/.config/quickshell/desk-widgets
~/.config/quickshell/desk-widgets/helpers/build.sh   # needs gcc and wayland-scanner
qs -c desk-widgets -d
```

Stop it with `qs kill -c desk-widgets`.

Settings are the `readonly property` lines at the top of `shell.qml` and `Pet.qml`.
