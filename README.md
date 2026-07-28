# Dandelion

A native macOS menu bar app for **OpenCode Zen** (pay-as-you-go) and **OpenCode Go** (subscription) - your live balance/usage at a glance, plus the full model catalog with pricing and limits, no browser or CLI required.

![platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey)
![swift](https://img.shields.io/badge/swift-6.2%2B-orange)

## Purpose

Dandelion is a **Zen/Go-only**, fully graphical dashboard, styled as a custom dark/monospace/teal "terminal" panel instead of a plain `NSMenu` dropdown. It answers three questions without opening a browser:

- How much is left in my Zen balance, and what's my auto-reload threshold / monthly limit?
- How much of my Go 5h/weekly/monthly usage window have I used, and when does it reset?
- What do all Zen/Go models cost (input/output/cache read/cache write per 1M tokens) and what are their context/output limits?

## Architecture

Dandelion is a Swift 6 / SwiftUI, menu-bar-only app (`LSUIElement`, no Dock icon, no CLI target).

```
Status bar icon (NSStatusItem)
        │ click
        ▼
Floating panel (NSPanel, custom SwiftUI content)
        ├── Zen Balance Card   ──┐
        ├── Go Usage Card       ├── RefreshCoordinator (TaskGroup, parallel fetch)
        ├── Model Catalog View  │        + auto-refresh timer + manual Refresh
        └── Settings ───────────┘
```

Because the live balance/usage endpoints are undocumented and can change without notice, every widget degrades gracefully to a "—" + *Open Console* fallback instead of crashing when discovery or parsing fails.

Design tokens (colors, monospace font, spacing) live in `Theme/TerminalTheme.swift`; the reusable ring gauge is `UI/RingGaugeView.swift`.

## Requirements

- macOS 26 ("Tahoe") or later
- Xcode 26+ (full IDE, not just Command Line Tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj` from `project.yml` (`brew install xcodegen`)
- An OpenCode account already connected on this machine (i.e. `~/.local/share/opencode/auth.json` exists - run `/connect` in OpenCode if it doesn't)

## Running locally

The `.xcodeproj` is generated from `project.yml`, so it's not checked in - generate it first:

```bash
brew install xcodegen   # if not already installed
cd dandelion
xcodegen generate
open Dandelion.xcodeproj
```

Then in Xcode: select the **Dandelion** scheme and press **Run** (⌘R). The app has `LSUIElement` set, so it won't show a Dock icon or a window - look for its icon in the menu bar and click it to open the panel.

You can also build/run from the terminal instead of the Xcode UI:

```bash
xcodebuild -project Dandelion.xcodeproj -scheme Dandelion -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Dandelion-*/Build/Products/Debug/Dandelion.app
```

### First-run permissions

- **Zen/Go catalog and key validation** work immediately as long as `auth.json` has your keys - no extra permission prompts.
- **Live Zen balance / Go usage** additionally need read access to your browser's cookie store: Chromium-based browsers (Chrome/Brave/Arc/Edge) prompt for Keychain access to decrypt cookies; Safari's cookie store requires granting the app **Full Disk Access** in System Settings → Privacy & Security. If discovery fails or is denied, use the manual cookie/workspace override field in Settings instead.

## Installing locally (no Homebrew/Cask yet)

There's no signed/notarized release or Cask published yet (`Casks/dandelion.rb` is a placeholder for that later step), so for now installing means building it yourself and copying the app out of Xcode's build output. The `install.sh` script wraps the whole flow:

```bash
./install.sh
```

This runs `xcodegen generate`, a Release build, copies `Dandelion.app` to `/Applications`, and opens it. Since this build isn't notarized, the first launch may need a right-click → **Open** (or an allow in System Settings → Privacy & Security → Security) to bypass Gatekeeper.

## License

See [LICENSE](LICENSE).
