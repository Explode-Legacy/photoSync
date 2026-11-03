# PhotoBridge

Free, open-source photo and file sync between iPhone, Android and Mac, over
the same Wi-Fi or Tailscale. No cloud, no account.

## How it works

- Each device runs a small HTTP server on port `53318`.
- Devices find each other with Bonjour (`_photobridge._tcp`), a subnet scan,
  saved addresses (home, office, Tailscale name or `100.x.y.z`), or by
  connecting back to whoever just reached them.
- All devices share an 8-character pairing code.
- New photos and videos are sent automatically to every connected device
  that allows inbound (Settings → Auto-send to can leave some out). Ledgers
  stop duplicates and stop received photos from being sent back; photos
  deleted on the receiver can be sent again (Settings → Re-check sent photos).
- **Send files:** pick files or a folder (or use the Share menu / Open With)
  and choose which devices get them.
- **Inbound:** each device can refuse incoming photos. On by default on
  phones, off on the Mac. Files sent on purpose always arrive.
- Live Photos keep their motion part (sent as a video next to the photo);
  album names are kept.

## Security

- End to end, on every network (Tailscale included): the pairing code is
  stretched with PBKDF2-SHA256 (600,000 rounds) and split with HKDF into a
  signing key and an encryption key. The code itself is never sent.
- Every request and reply is signed (HMAC-SHA256) with a timestamp and a
  one-time nonce, so captured requests can't be replayed.
- File contents and all metadata (names, dates, locations, folders, albums)
  are encrypted with AES-256-GCM, with a fresh key per request, in 1 MB
  chunks that can't be altered, reordered or cut off unnoticed.
- Five wrong codes in a minute lock that address out for a minute.
- Only `/info` answers strangers: device name and kind, so it can be paired.

Interrupted uploads resume from the last full megabyte.

## Mac

- Photos come from a folder you choose (Settings → Photos folder), not the
  Photos app; everything in it is sent. With inbound on, received photos are
  saved there too.
- Received files go to Settings → Files folder (default ~/Downloads/PhotoBridge).
- Drop files on the Dock icon, or Finder → Open With → PhotoBridge, to send them.
- Closing the window keeps it running; quit with ⌘Q. Settings has Open at
  login and Show in menu bar only.

## Background behaviour

- **Android:** a foreground service keeps syncing even when the app is closed,
  and starts again after a reboot. On Xiaomi phones, also enable Autostart.
- **iOS:** syncs while the app is open, finishes a running batch after you
  switch away, and gets occasional background runs from iOS. Optional
  "Keep running in background" plays silence so iOS doesn't suspend it
  (costs some battery).
- Optional rules: auto-send on Wi-Fi only; pause below 15% battery (Android).

## Install

Download from [the downloads page](https://github.com/Explode-Legacy/photoSync-releases/releases)
(the app also tells you when there's a new version):

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

Android release builds are signed with the key in
`~/.android/photobridge-release.properties` (on GitHub: the
`ANDROID_RELEASE_KEYSTORE` and `ANDROID_RELEASE_PASSWORD` secrets).
