# CyberView

A frameless viewer that dresses whatever it opens in the Ghostty HUD frame.
No titlebar, no chrome — just the content, the brackets, and the wallpaper
bleeding through.

## What it follows

CyberView reads the live terminal profile instead of hardcoding a look:

- `~/.config/ghostty/config` — background color, opacity, window padding
- `~/.config/ghostty/shaders/hud-overlay.glsl` — the frame geometry
- `~/.config/task-tint/task.zsh` — the color system

Every file is treated like a *task binding*: its name is hashed
(`sha256`, first 4 hex chars, mod 360) to a hue, exactly like `task <name>`.
Same file, same color, forever. Different files, a wall of tinted panes.

## Controls

| do | get |
| --- | --- |
| hover | reveal ✕ and filename |
| esc / cmd-W | close window |
| drag anywhere | move |
| drag edges | resize |
| cmd-O | open more files |
| cmd-E | expand every folded section (markdown) |
| shift-cmd-E | collapse them again |

## Renderers

1. **Images** — png, jpeg, gif, webp, tiff, heic, bmp
2. **Markdown** — this document is the demo
3. *Future* — plain text, PDF, whatever registers in `renderers`

### Markdown

- GFM tables draw as real grids
- nested lists step in
  - one level per enclosing item
- `<details>` blocks fold: click the ▸ line to open it
  - `<details open>` starts open, and `<summary><h2>…</h2></summary>` folds a whole section under a heading-sized line
  - a `#fragment` link into a folded section opens it first
- local images render inline, scaled to the page
- `#fragment` links jump to headings, and relative links open next to the document

<details>
<summary>a folded block</summary>

Hidden until the line above is clicked.

</details>

> The frame is the task signifier — its color follows the file
> and stays stable regardless of the terminal's age.

## Hacking

```sh
./build.sh              # compile + install to ~/Applications
swift set-default.swift # claim default-app bindings
swift gen-icon.swift    # regenerate the icns
```

The translucency knob is `viewerAlpha` in `Sources/main.swift`.
