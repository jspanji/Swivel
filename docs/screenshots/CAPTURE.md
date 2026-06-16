# Capturing Swivel's screenshots

The README references a few images in this folder. They're committed
separately from the markup because Swivel is a menu-bar app — its popover and
overlay can't be captured headlessly; someone has to shoot them on a real Mac.
This guide is that someone's checklist.

> **Privacy first.** These images ship in a public README. Use throwaway demo
> account names (*Personal*, *Work*, *Client A*) — never real client names,
> emails, org names, message counts, or anything you wouldn't post publicly.

## The shots

| File | What's in it | README slot | Width |
|------|--------------|-------------|-------|
| `popover.png` | The popover, 2–3 accounts, **one near a limit** so the amber/red shows | hero, top of README | `420` |
| `usage-overlay.png` | The floating Usage Overlay sitting on the desktop | "The Usage Overlay" | `360` |
| `live-usage.png` | Popover (or overlay) in **Live Usage** mode — 5h / 7d lines visible | "Live Usage" | `420` |
| `menu-bar-icon.png` *(optional)* | Close-up of the colored menu-bar icon | — | `120` |
| `switch.gif` *(optional)* | A 2–3 s switch: hotkey → Claude relaunches as the other account | — | `520` |

Make sure at least one row in `popover.png` / `live-usage.png` is near a limit
so the **signal-by-exception** coloring (neutral when healthy, amber ≥ 75 %,
red ≥ 90 %) is actually visible — an all-healthy shot undersells the design.

## How to capture

**Retina.** Shoot on a Retina display. macOS captures at 2×, so a popover
that's ~340 pt wide saves as a ~680 px PNG; the README displays it at half via
the `width=` attribute, which keeps it crisp.

**Background.** Open the UI over a calm, mid-tone wallpaper. Pure white blows
out the translucent glass; a busy photo fights it. A neutral desktop lets the
material read.

**Window shots** (overlay, menu-bar icon): `⌘⇧4`, then press **Space** to
switch to window mode, then click the window. macOS captures the drop shadow
and rounded-corner transparency for you.

**The popover is the tricky one** — it dismisses on any outside click *by
design*, so the usual "click the window" capture closes it before it shoots.
Use a timed full-screen grab, which needs no click:

1. `⌘⇧5` → **Options** → **Timer: 10 Seconds**, mode **Capture Entire Screen**.
2. Click **Capture**, open the popover, and hold the mouse still.
3. The timer fires and grabs the whole screen with the popover open.
4. Crop to the popover (leave a little of its shadow) in Preview.

**Format.** PNG for stills — lossless, and it preserves the glass edges. For
`switch.gif`, record with `⌘⇧5` → *Record Selected Portion*, then convert the
`.mov` to an optimized GIF (e.g. `ffmpeg` piped to `gifski`). GitHub won't
autoplay an `.mp4` referenced from an `<img>`, so use a GIF here — or attach
the `.mp4` to a release/issue and embed that.

**Optimize** *(optional)*: run the PNGs through ImageOptim / `oxipng` /
`pngquant` to shave the committed size.

## Wiring them in

1. Drop the file(s) into `docs/screenshots/` with the **exact names** above.
2. In `README.md`, find the matching commented `<img>` line and uncomment it
   (delete the surrounding `<!--` and `-->`).
3. Tweak `width=` if the default feels off, and refine the `alt=` text to match
   what the shot actually shows.
4. `git add docs/screenshots/<file> README.md` and commit.

### Light + dark (optional)

The glass follows the system appearance, so a Dark-mode shot looks different
from Light. To match the reader's theme, capture both
(`popover-light.png` / `popover-dark.png`) and swap the `<img>` for a
`<picture>`:

```html
<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/popover-dark.png">
    <img src="docs/screenshots/popover-light.png" width="420" alt="Swivel's popover">
  </picture>
</p>
```
