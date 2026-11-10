# SSHKit

SSH from Recense on the iPhone and iPad (C2, owner 2026-11-10: "SSH into a terminal from every device").

- **SSHKit:** the connection. SwiftNIO SSH, an Ed25519 key made on the device and kept in its Keychain (this device only),
  the Mac's host key pinned on first use (`Recense/ssh/pins.json`). Routes are tried in order (same Wi-Fi, then Tailscale).
  A refused key, a changed host key or no answer ends with a named error within the timeout, never a hang.
- **SSHTerminal:** the terminal screen (SwiftTerm 1.11.2, MIT), iOS only. Opened from Library › Terminal
  (`mobile/HostApp/iOS/Terminal.swift`).

No company in the path: the phone talks straight to the owner's Mac. Fetched once at setup from GitHub: swift-nio-ssh,
swift-crypto (Apple), SwiftTerm. SwiftTerm is pinned at 1.11.2: 1.13+ needs the Metal toolchain, 1.19+ runs a build plugin.

## Use
1. On the Mac: System Settings › General › Sharing › Remote Login on.
2. In Recense on the iPhone: Library › Terminal › More › Add a Mac (user name, `MacBook-Pro.local`).
3. More › Copy This iPhone's Key, then on the Mac (Universal Clipboard): `pbpaste >> ~/.ssh/authorized_keys`.
4. Tap the Mac.

## Test
`swift test` here. With `SSHKIT_LIVE_KEY=<raw Ed25519 key file>` authorized on this Mac, three live tests also run against
`127.0.0.1:22`: a command, a terminal shell, and a refused changed host key.
iOS compile: `xcodebuild -scheme SSHKit-Package -destination 'generic/platform=iOS' build`.
