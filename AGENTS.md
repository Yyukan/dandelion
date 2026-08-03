# AGENTS.md

Instructions for AI coding agents working in this repo. Humans should read `README.md` instead.

## Project

Dandelion is a native macOS menu bar app (SwiftUI, Swift 6, macOS 26+) for OpenCode Zen/Go balance and usage. No Dock icon, no CLI target, menu-bar-only.

## Build & run

The `.xcodeproj` is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not checked in.

```bash
xcodegen generate
xcodebuild -project Dandelion.xcodeproj -scheme Dandelion -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Dandelion-*/Build/Products/Debug/Dandelion.app
```

To install a Release build into `/Applications` and launch it, use `./install.sh` (regenerates the project, builds Release, replaces `/Applications/Dandelion.app`, launches it).

## Conventions

- Ring/circle gauges (`RingGaugeView`) are used by `GoUsageCard` and `ZenBalanceCard`. The view's own default `lineWidth` is `8`, but every call site explicitly overrides it to `3` - keep new call sites consistent with `lineWidth: 3` rather than relying on the default.
- Every live-data widget (Zen balance, Go usage) must degrade gracefully to an `unavailable`/`sessionExpired` fallback state instead of crashing when discovery or the private endpoint fails - never assume the endpoint succeeds.
- Follow the existing SwiftUI file layout: header doc comment block, then `import SwiftUI`, main view struct, private helper views, `#Preview` at the bottom.

## Git / commits

- Stage changes (`git add`) but do not commit or push unless explicitly asked to.
- When asked to commit, add Junie as co-author: `git commit --trailer "Co-authored-by: Junie <junie@jetbrains.com>"`.
- Do not push unless explicitly asked.

## Style

- Be short and on point; don't add extra explanations or code examples unless asked.
- When explaining code, reference file name and line numbers.
