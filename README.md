# Break Time

A break reminder for [Omarchy](https://omarchy.org).

After 30 minutes at the keyboard a small card pops up:

> **Time for a break**
> Drink water, stretch your legs, don't look at screens!

A bar fills over the next 5 minutes. When it is full the card closes and the
next 30 minutes start. Not a good moment? Snooze it for 5 minutes.

![Break Time popup](preview.png)

- **Counts real screen time.** Walk away for 5 minutes and the timer starts
  over when you come back. Short pauses to read or think still count.
- **One icon in the bar.** Click it for the on/off switch and the interval
  slider (15 to 120 minutes).
- **Quiet.** No fullscreen takeover, no sound, no network. The card sits in
  the middle of every screen and waits for you.
- **Themed.** It follows the active Omarchy theme.
- **Native.** QML inside the `omarchy-shell` process you already run.

## Install

```bash
omarchy plugin add https://github.com/mjasnikovs/omarchy-breaktime.git --enable
```

The icon lands on the right of the bar. Move it with `omarchy bar move`.

> Plugins run unsandboxed inside your shell. Read the code before you enable it.

## Use

| Action | How |
|---|---|
| Open settings | Click the coffee cup in the bar |
| Turn on or off | Toggle in the panel, or Space while it is open |
| Change interval | Drag the slider, or Left / Right while the panel is open |
| Reset the timer | "Reset timer" in the panel |
| Test the popup | "Break now" in the panel, or middle-click the icon |
| Snooze 5 minutes | "Snooze 5 min" on the card, or Esc |

Keys on the card work after you click it. The card never steals focus from
what you are typing.

### Scripting

```bash
omarchy-shell mjasnikovs.breaktime status      # JSON: status, remaining seconds, break seconds left
omarchy-shell mjasnikovs.breaktime breakNow
omarchy-shell mjasnikovs.breaktime snooze
omarchy-shell mjasnikovs.breaktime reset
omarchy-shell mjasnikovs.breaktime enable
omarchy-shell mjasnikovs.breaktime disable
omarchy-shell mjasnikovs.breaktime interval 45
```

## Behaviour details

- The popup waits while the screen is locked and shows once you unlock.
- After suspend, a reminder that is more than 5 minutes overdue is dropped
  and a fresh interval starts.
- Snooze as many times as you like.
- Turning the plugin off or on starts the timer over. Off also closes an
  open break card.
- The timer survives a shell restart. If the card was up, it comes back.
- A playing video does not pause the timer. Watching is screen time too.

## Settings

Stored in `~/.config/omarchy/shell.json` on the widget entry:

```json
{ "id": "mjasnikovs.breaktime", "enabled": true, "intervalMinutes": 30 }
```

Timer state lives in `~/.local/state/omarchy/breaktime/state.json`.

## Updating

```bash
omarchy plugin update mjasnikovs.breaktime
omarchy restart shell
```

The popup is kept loaded, so new popup code needs the restart.

## Removing

```bash
omarchy plugin remove mjasnikovs.breaktime
rm -rf ~/.local/state/omarchy/breaktime
```

The first line disables the plugin and deletes its files. The second removes
the timer state.

## Development

Clone the repo somewhere outside `~/.config/omarchy/plugins` (the shell
refuses folders with symlinks, and `node_modules` has some). Needs
[bun](https://bun.sh).

```bash
bun install
bun run lint        # prettier, eslint --fix, tsc
bun test            # bun test on src/Model.mts
bun run build       # emits Model.mjs, which the QML imports
bun run prepublish  # check + build + validate the clean tree
```

`src/Model.mts` holds all the scheduling logic and has no Qt dependency. The
built `Model.mjs` is committed because `omarchy plugin add` clones the raw
repo with no build step. Run `bun run prepublish` before every push.

## License

MIT
