# Zync features and usage

Last updated: 2026-11-09 (Asia/Saigon)

Source: [d3vin4/Zync](https://github.com/d3vin4/Zync), upstream Build 4.

## 1. What Zync is

Zync is a single ARM64 Objective-C dylib intended to be loaded inside the Zalo
iOS process. It does not require Theos, Substrate, ElleKit, or a jailbreak at
runtime. It links only Apple system frameworks (`Foundation`, `UIKit`, and
`QuartzCore`).

Zync itself does **not** decrypt an App Store IPA, inject its dylib, sign the
modified application, or install it on an iPhone. Those steps belong to a
separate packaging and sideloading pipeline.

Upstream Zync currently targets:

- Zalo `26.11.01`.
- `CFBundleIdentifier = vn.com.vng.zingalo`.
- ARM64 and iOS 15.1 or newer.
- Dylib output `build/libZync.dylib`.

The compatibility check is strict. The upstream code becomes idle when either
the Zalo version or the bundle identifier does not match. In particular, a
packager that changes the bundle identifier to `vn.com.vng.zingalo2` will make
unmodified upstream Zync refuse to boot.

## 2. Runtime architecture

The dylib constructor performs only lightweight logging and registers launch
observers. Module installation happens after the app launch notification, with
fallback timers for late injection. Each module is installed independently
inside an exception boundary.

The runtime hook engine:

- Discovers Objective-C classes belonging to `Zalo.app`.
- Uses class and selector names instead of hard-coded addresses.
- Checks selector argument count and return type before replacement.
- Deduplicates each class/selector pair.
- Skips a hook when an anchor or method signature is missing.

This architecture reduces startup crashes, but static validation is not proof
that the dylib has run successfully on a physical iPhone.

## 3. Main features

The features below are implemented in the upstream source and covered by its
static checks. Their runtime behavior on this user's physical iPhone has not
yet been verified.

### Appearance

**Liquid Glass Tab Bar** places a non-interactive material overlay inside the
Zalo tab bar. It uses `UIGlassEffect` when the runtime provides it and falls
back to `systemUltraThinMaterial` blur. It does not change navigation, safe
areas, or touch handling.

This is an overlay, not adoption of the native system tab-bar redesign. Zalo's
`UIDesignRequiresCompatibility` setting prevents the process from adopting the
new design automatically.

### Privacy

- **Hide Typing Indicator** suppresses the outgoing typing-status method.
- **Control Seen Status** suppresses outgoing message-level seen events.
- **Control Read Receipts** suppresses server flush and ACK methods used for
  read receipts.
- **Disable Tracking & Analytics** intercepts known Zalo tracking URLs.
- **Disable Firebase Collection** asks supported Firebase runtime classes to
  disable analytics, performance, and crash-report collection.

The seen and read-receipt features block outgoing notifications. They do not
prevent the local Zalo UI from marking a message as read.

### Advertising

- **Hide Ads** hides known advertising views and cells.
- **Block Ad Requests** intercepts verified advertising hosts and URL paths and
  returns an empty response.

Zync uses both network and view layers because either layer alone can leave an
empty advertisement container or allow data to be requested unnecessarily.

### Feature restoration

- **Profile Music** enables the related client feature flags and getters.
- **Google Drive Backup** restores the client-side backup section when the
  underlying Zalo classes are present.
- **More Tab** writes the `enable_tabmore` feature flag.

These features expose client code already present in Zalo. They do not grant
server-side subscriptions or entitlements.

### Native settings and diagnostics

Zync clones a real Zalo settings-row model near "Tài khoản và bảo mật" and
opens a native `Zync Customize` dashboard. Settings are stored in a dedicated
defaults suite and, when available, mirrored into Zalo's settings App Group.

Runtime messages are written to the Apple system log and to `Zync.log` in the
application Documents directory, with a temporary-directory fallback. Reading
that file from the Files app requires document sharing to be enabled; otherwise
it must be retrieved from the application container or through a device-log
tool. The App Group copy is available only when the re-signed application
retains permission to use that group.

## 4. Building upstream Zync

Building requires macOS with Xcode and an iPhoneOS SDK compatible with the
Makefile.

```bash
git clone https://github.com/d3vin4/Zync.git
cd Zync
make
make gates
```

Expected output:

```text
build/libZync.dylib
```

`make gates` performs static checks for architecture, install name, minimum iOS
version, dependencies, guarded use of newer UIKit APIs, and code-signing
metadata. Passing these checks does not test launch behavior on an iPhone.

## 5. Packaging and installation flow

A no-jailbreak installation needs this complete flow:

1. Obtain an authorized decrypted Zalo IPA whose Mach-O files have
   `cryptid=0`.
2. Confirm the exact Zalo version, build, bundle identifier, architectures,
   extensions, and embedded frameworks.
3. Verify every Zync anchor against that exact binary.
4. Update the compatibility policy for the exact version and the bundle
   identifier that the signing tool will produce.
5. Copy `libZync.dylib` into `Payload/Zalo.app/Frameworks/`.
6. Add an `LC_LOAD_DYLIB` command for the embedded dylib to the main Zalo
   executable.
7. Remove or replace invalid signatures and re-sign the main app, dylib,
   frameworks, and any retained extensions with a consistent identity.
8. Install the signed IPA using the chosen sideloading tool.
9. Confirm the app launches and that the Zync load/boot messages appear in
   `Zync.log` before testing any feature.

The packager in this repository can copy a supplied dylib and add the load
command, but its default bundle identifier is `vn.com.vng.zingalo2`. That is
not accepted by upstream Zync without a compatibility change.

## 6. Using the settings after installation

When injection, compatibility, and signing all succeed:

1. Open Zalo normally.
2. Open Zalo's settings screen.
3. Find `Zync Customize` near the account/security row.
4. Open the dashboard and enable one feature at a time.
5. Close and reopen the relevant Zalo screen after changing a UI or restored
   feature flag. Relaunch Zalo if that screen was already initialized.
6. Inspect `Zync.log` through Files when document sharing is enabled, or retrieve
   it from the application container/device logs when the row or a feature does
   not appear.

Privacy hook blocks read their toggles at call time, so they are designed to
change without restarting. Previously started requests or already-created UI
objects may still require a screen refresh.

## 7. Known limitations

- Upstream Zync is version-locked to Zalo `26.11.01`.
- Its bundle check accepts only `vn.com.vng.zingalo`.
- Static anchor presence does not prove runtime method ownership or successful
  execution on a physical device.
- Re-signing can break Push Notifications, VoIP Push, Keychain Groups, App
  Groups, iCloud, Associated Domains, and app extensions when the signer does
  not own VNG's entitlements.
- Zync does not implement anti-recall, per-conversation selective seen, local
  unread state, quick replies, delayed send, private notes, or a full theme
  engine.
- It deliberately does not unlock paid/server-side features, fake group
  ownership, or modify authentication and encryption.

## 8. Safe first-device test

Use a disposable test account and enable only one feature at a time. The first
test should prove the following sequence before any messaging hooks are used:

1. The decrypted IPA, re-signed without an injected dylib, launches.
2. The IPA with only the dylib load command launches.
3. `Zync.log` contains the constructor load message.
4. The compatibility check reports supported.
5. The boot-complete message appears.
6. The settings row opens the dashboard.

This separates signing failures, loader failures, compatibility failures, and
individual feature failures.
