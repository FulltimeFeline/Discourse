# Discourse for Matrix

Discourse is a Matrix client for macOS and iOS, written in SwiftUI on top of the
[matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-components-swift). It
uses native sliding sync and the SDK's local store to open directly into cached
conversations, with a layout tuned to each platform.

The project is under active development.

## Screenshots

![Discourse on macOS](screenshots/macos.png)

| Room list | Conversation |
| :---: | :---: |
| ![Room list](screenshots/ios-rooms.png) | ![Conversation](screenshots/ios-chat.png) |

## Features

- Spaces, rooms, and direct messages, arranged in a rail that can be reordered by dragging
- End-to-end encryption, with cross-signing, key backup, and interactive device verification
- A timeline with replies, threads, edits, redactions, reactions (custom emoji included), and message search
- Voice messages, polls, stickers, and image and location sharing
- Video calls through Element Call
- Rich notifications and support for several accounts at once
- Sign-in by password, OAuth/OIDC, or SSO

## Requirements

- Xcode 26 (the deployment target is macOS and iOS 26)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- A homeserver with native sliding sync (Synapse 1.114 or later)

## Building

The Xcode project is generated from `project.yml` with XcodeGen rather than
committed directly, so generate it before opening:

```sh
git clone https://github.com/riiiiiiiley/Discourse.git
cd Discourse
xcodegen generate
open Discourse.xcodeproj
```

Build the `Discourse` scheme for macOS or `Discourse-iOS` for iOS;
dependencies are resolved automatically through Swift Package Manager. To change
build settings or add files, edit `project.yml` and regenerate rather than
modifying the project in place.

## Project structure

- `App/` — entry point, root state machine, and the window and settings scenes
- `Core/` — the SDK service, session store, media loading, notifications, and presence
- `Features/` — the room list, timeline, composer, calls, settings, and authentication
- `Models/` — value types and their mapping to the SDK's FFI

## License

Discourse is released under the [MIT License](LICENSE). The source is open; the
App Store build is a paid convenience for people who would rather not compile it
themselves.

## Acknowledgements

Discourse is developed by [riiiiiiiley](https://github.com/riiiiiiiley).

It is built on the [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk),
distributed for Swift through
[matrix-rust-components-swift](https://github.com/matrix-org/matrix-rust-components-swift).
Parts of the client — particularly session restore and the room list — were
informed by [Element X iOS](https://github.com/element-hq/element-x-ios), whose
source was a helpful reference. Video calls use
[Element Call](https://github.com/element-hq/element-call). The app implements
the [Matrix](https://matrix.org) protocol.
