# ADR-0001: Native Swift, AppKit + SwiftUI, no cross-platform framework

Status: Accepted

## Context

Hisingen is a macOS menu-bar utility (`LSUIElement`, no Dock icon) that needs
tight integration with OS-level facilities: Keychain, Notification Center, a
status-bar item, launch-at-login, and URL-scheme handling for the Volvo OAuth
redirect. It targets exactly one platform (macOS 13+) with no near-term plan
to ship on iOS, Windows, or Linux.

## Decision

Build entirely in Swift via Swift Package Manager, with AppKit for the
status-item/window chrome (`StatusItemController`) and SwiftUI for the
content views. No cross-platform UI framework.

## Alternatives considered

- **Electron / web-based shell** — would add a large runtime footprint and
  bundle size for a menu-bar-only utility, and has no first-class story for
  Keychain access or launch-at-login on macOS.
- **Flutter / React Native** — solves a multi-platform problem Hisingen
  doesn't have, and both still require a native shim for Keychain,
  `NSStatusItem`, and login-item registration, so the cross-platform layer
  buys little here.

## Consequences

macOS-only by construction; small download size; direct, first-class access
to Keychain, Notification Center, and login-item APIs without a bridging
layer. Any future non-macOS platform would need a substantial rewrite of the
UI layer, though the `Domain/` and `Services/API/` layers are already
UI-framework-agnostic (see [0003](0003-shared-vehicle-domain-provider-dtos.md)).
