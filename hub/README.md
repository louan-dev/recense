# recense-hub · the offline Recense hub (FEAT-18 H1)

The hub is a small HTTPS server on a Mac we own.
Any browser on the home Wi-Fi opens `https://recense.local/` and gets Draftpad, with no internet.
The spec is `docs/specs/FEAT-18-offline-hub.md`.

- **The page:** Draftpad's offline web app, served from `editor/dist/pwa/`.
  It installs once, then opens with no network.
- **Note sync:** `POST /api/note` merges a browser's text into `draftpad.md`.
  The merge is the apps' own (`shared/notesync.swift`).
  A browser with no hub keeps writing to its own storage and catches up later.
- **Names:** Bonjour publishes `recense.local` and `mac.recense.local` (`--name mini` on the Mac mini).
- **Certificates:** our own root, which can vouch only for names under `recense.local`.
  The root's key stays in `~/.config/recense/hub-ca/`.
  The root also refuses IP addresses (2026-11-17), so it can't vouch for a router page reached by IP.
  A root made before then must be remade before any device trusts it (install.zsh alone keeps the old one):
  ```bash
  trash ~/.config/recense/hub-ca ~/.config/recense/hub/tls.p12 && zsh ~/Developer/recense/hub/scripts/hub-ca.zsh mac && launchctl kickstart -k gui/$UID/local.recense.hub
  ```
  Check: `openssl x509 -in ~/.config/recense/hub-ca/root.pem -noout -text | grep -A4 "Name Constraints"` shows `Excluded: IP`.

## Build and check
`swift build` fails inside the Claude sandbox; run it in a normal terminal.
```bash
cd ~/Developer/recense/hub && DEVELOPER_DIR=~/Developer/recense/.toolchain/CommandLineTools swift build --build-system native --scratch-path .build-sdk27 && .build-sdk27/debug/recense-hub selftest
```

## Install on this Mac (a login agent: runs while you are logged in)
```bash
zsh ~/Developer/recense/hub/install.zsh mac
```
This builds the hub and makes the certificates if they are missing.
It then starts the hub and restarts it after a crash or reboot.
Log: `~/Library/Logs/recense-hub.log`.

## Install on the Mac mini (a LaunchDaemon: runs with nobody logged in)
Edit the paths and the name in `hub/launchd/local.recense.hub.daemon.plist` first, then:
```bash
sudo cp ~/Developer/recense/hub/launchd/local.recense.hub.daemon.plist /Library/LaunchDaemons/local.recense.hub.plist && sudo chown root:wheel /Library/LaunchDaemons/local.recense.hub.plist && sudo launchctl bootstrap system /Library/LaunchDaemons/local.recense.hub.plist
```

## Trust the root on each device (once)
- Mac:
  ```bash
  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/.config/recense/hub/recense-hub-root.pem
  ```
- iPhone and iPad: AirDrop `~/.config/recense/hub/recense-hub-root.mobileconfig` to the device.
  - Install it under Settings → General → VPN & Device Management.
  - Then turn on full trust under Settings → General → About → Certificate Trust Settings → Recense Hub Root.

## Pair a browser (once per browser)
```bash
~/.local/bin/recense-hub pair
```
This prints `https://recense.local/#pair=…`. Open that link once on each device.
The page keeps the token; without it, the page still works but doesn't sync.

## Commands
`recense-hub serve [--port 443] [--shell DIR] [--note FILE] [--name mac] [--no-mdns]` · `recense-hub pair` · `recense-hub selftest`
