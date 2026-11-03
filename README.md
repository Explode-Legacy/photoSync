# PhotoBridge

Free, open-source photo and file sync between iPhone, Android and Mac, over
the same Wi-Fi or Tailscale. No cloud, no account.

## How it works

- Each phone runs a small HTTP server on port `53318`.
- Phones find each other with Bonjour (`_photobridge._tcp`), a subnet scan, or
  saved addresses (home, office, Tailscale name or `100.x.y.z`).
- Both phones share an 8-character pairing code; requests without it are refused.
- New photos and videos are sent automatically to every connected device
  that allows inbound. Ledgers stop duplicates and stop received photos
  from being sent back.
- **Send files:** pick files or a folder (or use the Share menu / Open With)
  and choose which devices get them.
- **Inbound:** each device can refuse incoming photos. On by default on
  phones, off on the Mac. Files sent on purpose always arrive.

## Mac

- Photos come from a folder you choose (Settings → Photos folder), not the
  Photos app; everything in it is sent. With inbound on, received photos are
  saved there too.
- Received files go to Settings → Files folder (default ~/Downloads/PhotoBridge).
- Drop files on the Dock icon, or Finder → Open With → PhotoBridge, to send them.
- Closing the window keeps it running; quit with ⌘Q.

## Background behaviour

- **Android:** a foreground service keeps syncing even when the app is closed,
  and starts again after a reboot. On Xiaomi phones, also enable Autostart.
- **iOS:** syncs while the app is open, finishes a running batch after you
  switch away, and gets occasional background runs from iOS.

## Install

Download from [Releases](../../releases):

- `PhotoBridge.apk`: install on Android (allow installs from unknown sources).
- `PhotoBridge.ipa`: unsigned; sideload with SideStore, AltStore or similar.
- `PhotoBridge-macOS.dmg`: open it, drag PhotoBridge to Applications. It
  isn't notarized, so the first time run
  `xattr -dr com.apple.quarantine /Applications/PhotoBridge.app`
  (or System Settings → Privacy & Security → Open Anyway).

## Pairing

1. Open PhotoBridge on both phones.
2. On one phone, copy the pairing code from the home screen.
3. On the other, go to Settings → Pair and enter it.
4. Pick the other phone under Devices (scan, or add an address).

## Build

```bash
flutter pub get
flutter test
flutter build apk --release
flutter build ios --release --no-codesign
flutter build macos --release
```

The IPA is `Payload/Runner.app` from `build/ios/iphoneos/`, zipped.
