# Electroline

Electroline (Hisense) air conditioners in the Omarchy bar. One card per unit:
the room and what it reads, a power button, the setpoint as a big number with
a slider and one-degree buttons, and mode, fan speed, sleep and airflow as
labelled tiles.

## Why it goes through the cloud

The units are on the LAN but answer nothing there. A full TCP scan of both
of mine came back with every one of the 65535 ports refused, no mDNS and no
local broker: the wifi module only opens outbound connections to Hisense's
servers and waits for orders from there. So this widget takes the same path
the phone app does, through the ConnectLife cloud, using the
[connectlife](https://github.com/oyvindwe/connectlife) library.

Two consequences worth knowing. The API is undocumented and Hisense can
change it. And its author warns that polling too hard can get an account
locked, which is why the widget refreshes every two minutes while the panel
is closed and only speeds up while you are looking at it.

## Setup

```bash
~/.config/omarchy/plugins/zangetsu.electroline/scripts/setup-electroline
```

It creates a virtualenv in `~/.local/share/omarchy-electroline`, installs the
library, and walks you through the browser sign-in — the same account and the
same provider (Google, Apple, Facebook, Microsoft or a password) you use in the
app. The browser lands on a Swagger page that looks broken; the address bar is
what matters, and you paste it back.

The tokens are stored in the login keyring (`service=connectlife-omarchy`),
never on disk, and are refreshed automatically. Then add the widget to the bar
from Omarchy's settings.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Refresh interval, panel closed | 120 s | Deliberately slow. See the warning above. |
| Refresh interval, panel open | 10 s | A command takes a few seconds to come back from the cloud. |
| Python interpreter | empty | Empty means the virtualenv the setup script creates. |
| Most cloud calls per minute | 20 | A ceiling on everything the widget sends, polls included. |
| Hide when every unit is off | off | |

## How it keeps off the cloud's back

Every call, poll or command, passes the same three gates in `Service.qml`:

- **Debounce.** A control you touch does not send anything; it parks the value
  for half a second. Running along the mode buttons, or spinning the wheel over
  the temperature, leaves as a single request with the final values in it.
- **Minimum gap.** Consecutive calls keep their distance: 2.5 s between polls,
  0.9 s between commands, and one command in flight at a time.
- **Budget.** At most 20 calls a minute from the whole widget, configurable.

A call that trips a gate is deferred to the first moment it is allowed, never
dropped, so the panel still does what you asked — a little later. The panel
also polls every two minutes rather than every few seconds while it is closed.

One thing the gates cannot see: each bar gets its own copy of the widget, so a
second monitor doubles the polling. Lower the budget if you run more than one.

## Keyboard

The panel walks like every other Omarchy panel.

| Key | What it does |
|---|---|
| `j` / `k` (or ↓ / ↑) | Move through the controls, card by card |
| `h` / `l` (or ← / →) | On the temperature, one degree down or up |
| `Enter` / `Space` | Toggle power or Eco; open the tile under the cursor |
| `Enter` again, after `j`/`k` | Pick a value inside an open tile |
| `r` | Poll now |
| `Esc` | Close |

The cursor follows the mouse too, so there is only ever one highlight.

## Commands

```bash
omarchy-shell electroline status                  # "2 units · 1 on"
omarchy-shell electroline refresh                 # poll now
omarchy-shell electroline toggle                  # open/close the panel
omarchy-shell electroline power <puid> on         # one unit on or off
omarchy-shell electroline temperature <puid> 24   # setpoint in °C
```

The `puid` of each unit is printed by the setup script.

## When a control is missing

Hisense models do not all report the same properties. The widget looks for
`t_power`, `t_temp`, `f_temp_in`, `t_work_mode`, `t_fan_speed`, `t_eco`,
`t_sleep` and `t_up_down`, and hides any control whose property a unit does
not report — a card with no Sleep tile is a unit that never mentioned
`t_sleep`. To see what yours actually expose:

```bash
~/.local/share/omarchy-electroline/venv/bin/python \
  ~/.config/omarchy/plugins/zangetsu.electroline/scripts/connectlife-bridge dump
```

If a control is missing, add the real property name to `FIELDS` in
`scripts/connectlife-bridge`. The values each property takes are in the
[Home Assistant data dictionary](https://github.com/oyvindwe/connectlife-ha/blob/main/custom_components/connectlife/data_dictionaries/009.yaml)
for device type 009.

## Looking at the panel without an account

`tests/mock-cloud` is a fake cloud: two invented units whose state lives in
`~/.cache/omarchy-electroline-mock.json`. Point the widget's **Python
interpreter** setting at it and the panel works end to end — toggles, slider,
modes — without touching Hisense. Clear the setting to go back to the real
cloud.

## Tests

```bash
node tests/model-test.mjs
```

`omarchy-shell electroline error` prints why the widget is unhappy, which is
usually faster than reading the shell log.

## Licence

MIT.
