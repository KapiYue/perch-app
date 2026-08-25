# Perch

> **Files, images, text and links you drag in or copy get to "perch" at the top of your screen — ready to be taken anywhere.**

[中文](README.md) · [Website](https://perch.joy-coder.com) · [Download](https://perch.joy-coder.com/#download)

<!-- ![Perch demo](docs/assets/demo.gif) ← uncomment once the GIF exists (M6) -->

<!-- TODO(M6): record the demo GIF into docs/assets/demo.gif — same asset as README.md. -->

---

## ⚠️ Read this first: privacy

**Perch records everything you copy and stores it on your Mac's local disk.** That includes passwords you copy out of a password manager, one-time codes, and any other sensitive text.

**Perch does not try to guess which content is sensitive.** Heuristic "smart filtering" gives you unreliable confidence — it will miss something, and the one it misses is the one that matters. So we tell you exactly what happens and hand you the controls:

| Control | Where |
|---|---|
| Pause monitoring | **⏸** in the panel header, always visible, persists across restarts |
| Erase all data | Settings |
| Skip content the source app marks as do-not-record | Settings, **off by default** — see below |
| Ignore content copied from specific apps | Settings, **on by default**, pre-filled with Passwords and Keychain Access |

Everything lives in `~/Library/Application Support/Perch/`. **Nothing is uploaded.** No account, no cloud sync, no telemetry, no crash reporting. Perch makes no network requests while running (except the Sparkle update check, which can be disabled).

> **About passwords — please read both points.** Perch does **no content inspection whatsoever**. It never guesses whether some text looks like a password; that is a deliberate product decision (heuristics always miss something, and the one they miss is the dangerous one). It acts only on two kinds of **certain** information:
>
> **1. Markers set by the source app.** macOS has a community convention ([nspasteboard.org](http://nspasteboard.org/)) where some password managers flag the pasteboard with `org.nspasteboard.ConcealedType` and friends. With the matching switch on, flagged content never reaches the shelf. This is not guesswork — it respects an explicit declaration by the source app, and therefore **depends entirely on that app playing along**. Off by default.
>
> **2. Which app provided the content.** ⚠️ **Measured on 2026-08-25, macOS 26: Apple's built-in Passwords app sets no marker at all** when you copy a password — on the pasteboard it is indistinguishable from ordinary text, so the rule above cannot catch it. Perch therefore also keeps a **list of source apps**: nothing copied while one of them is frontmost reaches the shelf, and **not a single byte of the content is read**. This rule looks only at which app provided the content, never at the content itself. Passwords and Keychain Access are on the list by default, and you can edit it in Settings.

**If you are not comfortable with this, do not install Perch.**

Full policy: [Privacy Policy](https://perch.joy-coder.com/privacy).

---

## Permissions

| | |
|---|---|
| **What it requests** | Nothing. Perch needs no system permission that you have to approve |
| **No Accessibility access** | It does not read other apps' UI |
| **No Screen Recording** | It does not capture your screen |
| **No global mouse hook** | Which is also why there is no shake-to-summon gesture |
| **Never reads** | Contacts, Calendar, Photos, browser history |

App Sandbox is **disabled** — required for dragging content out as real files and for arbitrary path access. The cost is no Mac App Store distribution. Known and accepted trade-off.

---

## Features

### Clipboard: copy and it's on the shelf

A background timer checks the pasteboard's change count every 0.5s and only reads content when it actually changed. Type detection priority: image → file URL → link → code → plain text.

- Text, links, images and code are classified automatically; images show real thumbnails, links render green
- **Code** snippets get their language detected and shown inline (`swift` / `python` / `json`), with a
  monospaced preview; dragging one out gives it the matching extension (`.swift` / `.py`).
  **If the language can't be identified, it stays plain text** — no guessing
- **Type filter**: All / Text / Links / Images / Code, single choice. Display only — the data is
  untouched, `⌘1`–`⌘9` follow the filtered order, and collapsing the panel resets it to All
- The first nine entries get `⌘1`–`⌘9` numbers
- Up to 200 entries; oldest are dropped first (pinned entries are exempt)
- Copied file paths go to the Files section instead of taking a clipboard slot

### Four ways to take something back

| Action | Result |
|---|---|
| **Click a row** | Copies the content back to the system clipboard |
| **`⌘1`–`⌘9`** | Grab the Nth entry without leaving the keyboard (while the panel is open) |
| **Drag it out** | Lands as a real file (text → `.txt`, screenshot → `.png`) |
| **Double-click a row** | Toggles pinned state; pinned entries never expire |

### Files: a temporary shelf

- Drag in from Finder, switch Spaces or apps, drag out where you need it
- `⌘` / `Shift` to multi-select, `⌘A` to select all; then drag out / zip / pin / remove in bulk
- Space for Quick Look, double-click to open in the default app
- Right-click: Reveal in Finder / Copy Path / Rename / Pin / Remove / Share via AirDrop
- **Dropped files are copied into Perch's own storage**, so moving, renaming or deleting the original does not break the entry

### Entry point: a hot zone at the top of the screen

The entry point is defined as **a hot zone in the upper-middle of the screen — not the physical notch**:

- **Notched Macs**: the hot zone renders flush against the notch, reading as an extension of it
- **Non-notched displays** (external monitors, iMac, Mac mini): a black rounded bar of the same size is drawn at the top center
- **Multiple displays**: the panel opens on whichever screen the pointer is currently on

Three ways to summon: click the hot zone, hover it (auto-closes 0.4s after the pointer leaves), or the global shortcut. Dragging files onto the hot zone also expands the panel and accepts the drop.

**Your cursor stays put in the frontmost app** while the panel is open — you can keep typing in your editor and pull an entry out of Perch at the same time.

### Automatic cleanup

- Retention: **1 hour / 12 hours / 24 hours / 7 days / never**, default **12 hours**
- This is the **only** trigger for automatic cleanup — there are no hidden ones
- Pinned entries never expire
- Copying the same content again does not add an entry; it just resets that entry's timer

---

## Shortcuts

| Shortcut | Action |
|---|---|
| `⌃⌘V` | Toggle the panel, works globally (configurable) |
| `⌘1` – `⌘9` | Grab the Nth clipboard entry (while the panel is open; released back to other apps as soon as it closes) |
| `⌘A` | Select all files |
| `Space` | Quick Look the selection |
| `Esc` | Clear selection / close the panel |

---

## Install

### Direct download

Grab the DMG from the [website](https://perch.joy-coder.com/#download). Signed with a Developer ID and notarized by Apple, so it will not report "damaged" on first launch.

[GitHub Releases](https://github.com/KapiYue/perch-app/releases/latest) is the mirror for users outside mainland China.

### Homebrew

```bash
brew tap kapiyue/tap
brew install --cask perch
```

### Build it yourself

No Apple Developer account required — the script uses ad-hoc signing:

```bash
git clone https://github.com/KapiYue/perch-app.git
cd perch-app
./script/build_unsigned.sh
```

**Requirements**: macOS 14 Sonoma or later, Universal (Apple Silicon / Intel).

---

## Compared with similar tools

These are all good tools and we use several of them ourselves. The table is here so you can decide whether you need Perch at all.

| Capability | **Perch** | NotchDrop | Maccy | Paste | Dropover / Yoink |
|---|---|---|---|---|---|
| Clipboard history | ✅ automatic | ❌ | ✅ | ✅ | ❌ |
| File shelf | ✅ | ✅ | ❌ | ❌ | ✅ |
| **Both in one entry point** | ✅ | ❌ | ❌ | ❌ | ❌ |
| Drag content out as a real file | ✅ text & images | existing files only | ❌ | ❌ | existing files only |
| Time-based auto cleanup | ✅ configurable | partial | by count | by count | partial |
| Works without a notch | ✅ | ❌ | — | — | ✅ |
| Offline / no account | ✅ | ✅ | ✅ | ❌ needs iCloud | partial |
| Price | Free · GPL-3.0 | Free · MIT | Free · MIT | Subscription | Paid |

**What Perch does not have**, stated plainly: no cross-device sync, no cloud share links, no password detection, no Mac App Store build, no Windows version, and no tags or search on the file side. These are deliberate omissions, not gaps waiting to be filled.

> Based on publicly available versions as of August 2026. Corrections welcome via issues.

---

## Deliberate omissions

Each of these is a decision, not an unfinished feature.

- **No shake-to-summon gesture.** That interaction solves "I'm already dragging something and need a shelf right now"; Perch is for "stash it, come back later". Dropping it also drops the global mouse hook — one less source of false triggers, one less permission, one less antivirus false positive.
- **No password detection.** See the privacy section above.
- **No cloud upload, public links or iCloud sync.** This is what makes "offline" true.
- **No tags, categories or search for files.** That's a file manager's job. Shelf contents expire in hours by default; indexing them is backwards.
- **No automation or scripting engine.** It would turn a reach-up-and-use tool into one you configure first.
- **Text list rather than cards, inline copy feedback rather than a global toast, split sections rather than one list.** All confirmed after a round of rework.
  The split order is **file shelf on top, clipboard below** (decided 2026-08-21): the file grid has a near-fixed height and few items, so it never gets pushed off; the clipboard has many items, scrolls, and carries type filters, so it lives underneath where its height doesn't matter.

---

## Contributing

Issues and PRs welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

Stack: Swift 6 (strict concurrency) + SwiftUI, with AppKit for windows, drag & drop and the pasteboard. Project generated by XcodeGen.

- Feature scope and version plan: [CHANGELOG.md](CHANGELOG.md)

---

## Acknowledgements

Perch's ideas come from these projects, several of which are our daily drivers:

- [NotchDrop](https://github.com/Lakr233/NotchDrop) — the notch shelf form factor, and the direct source of "the top of the screen is the entry point"
- [Maccy](https://github.com/p0deje/Maccy) — the minimal approach to clipboard history, and the `changeCount` polling route
- [Sparkle](https://sparkle-project.org/) — automatic updates
- Dropover and Yoink — file shelf interaction details; a lot of our trade-offs only became clear after using them

The `org.nspasteboard.ConcealedType` convention comes from the [nspasteboard.org](http://nspasteboard.org/) community.

---

## License

[GPL-3.0](LICENSE) · Copyright © 2026 KapiYue

One reason only: **you may use it and modify it, but if you ship your modified
version, the source has to ship with it.** MIT does not stop someone from
reskinning Perch and selling it closed-source. GPL-3.0 does.

Nothing changes for normal users — download it, use it, install it for a
colleague, no restrictions. For anyone forking: when you distribute your
changes, they must be released under GPL-3.0 as well, with the copyright and
license notices preserved.

> Copyright stays with the maintainer, who is therefore not bound by these terms
> and may release versions under other licenses.
