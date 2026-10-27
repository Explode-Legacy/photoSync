# PhotoBridge

Free, open-source photo sync between an iPhone and an Android phone, over the
same Wi-Fi or Tailscale. No cloud, no account.

## How it works

- Each phone runs a small HTTP server on port `53318`.
- Phones find each other with Bonjour (`_photobridge._tcp`), a subnet scan, or
  saved addresses (home, office, Tailscale name or `100.x.y.z`).
- Both phones share an 8-character pairing code; requests without it are refused.
- New photos and videos are sent automatically. Ledgers stop duplicates and
  stop received photos from being sent back.

## Background behaviour

- **Android:** a foreground service keeps syncing even when the app is closed,
  and starts again after a reboot. On Xiaomi phones, also enable Autostart.
- **iOS:** syncs while the app is open, finishes a running batch after you
  switch away, and gets occasional background runs from iOS.

## Install

Download from [Releases](../../releases):

- `PhotoBridge.apk`: install on Android (allow installs from unknown sources).
- `PhotoBridge.ipa`: unsigned; sideload with SideStore, AltStore or similar.

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
```

The IPA is `Payload/Runner.app` from `build/ios/iphoneos/`, zipped.
