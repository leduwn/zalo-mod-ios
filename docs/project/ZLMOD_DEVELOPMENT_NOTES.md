# ZLMod development notes

Last updated: 2026-11-09 (Asia/Saigon)

## 1. Intent

ZLMod is the planned continuation of Zync for a sideloaded, non-jailbroken
Zalo iOS application. Zync supplies the runtime architecture. The existing
`leduwn` engines supply feature ideas and behavioral references only.

Existing hooks from `jailed-mod-engine` or `mod-engine` must not be copied into
ZLMod merely because they compile or pass source-level tests. Each feature will
be implemented again using Zync's anchor verification, delayed boot, runtime
method validation, module isolation, and fail-closed behavior.

## 2. Verified local IPA facts

Artifact:

```text
D:\REA\rea-zalo-ios\vn.com.vng.zingalo_26.10.02.ipa
```

Observed metadata:

| Field | Value |
|---|---|
| Display name | Zalo |
| Bundle identifier | `vn.com.vng.zingalo` |
| Version | `261002` |
| Build | `261002802` |
| IPA size | 137,438,924 bytes |
| SHA-256 | `20f8508a5db315f8240af609f6a88a947dcbeefb616b3b270bdd0a9d98957710` |
| Main executable | `Payload/Zalo.app/Zalo` |
| Main executable size | 181,589,488 bytes |
| Main Mach-O UUID | `272E892C-6D96-39F2-AC8A-C42F247E625D` |
| Main cryptid | `0` |
| Mach-O entries | 37 |
| Encrypted Mach-O entries | 0 |
| App extensions | 5 |
| Existing injected mod dylibs | 0 |

The file is suitable for patching because all inspected Mach-O images are
decrypted. A raw App Store download normally remains FairPlay encrypted; the
tool used to obtain this file therefore produced a decrypted package or
captured decrypted executables.

The root `README.md` contains older research statements, including an encrypted
`cryptid=1` target and jailbreak-oriented scope. Those statements do not
describe the IPA verified above and should not be used as the ZLMod runtime
baseline.

## 3. Zync compatibility result

The 49 class, selector, key, and URL anchors in upstream Zync Build 4 were
searched in the exact `261002` main binary. All 49 strings were present.

```text
present=49 total=49 missing=0
```

This is strong evidence that the two Zalo versions share the required runtime
surface. It is not proof of runtime compatibility because a string may exist
while its owning class, method signature, lifecycle timing, or behavior has
changed.

Upstream Zync still cannot run unchanged on this IPA because its compatibility
guard targets version `261101` and requires the original bundle identifier.

## 4. Why Zync is the preferred foundation

The existing jailed engine installs most hooks directly from its dylib
constructor. That is early in the process lifecycle and can run before the
relevant application state is ready. Its compatibility and safety layers are
substantial, but a successful build and injected load command do not prove that
the UI integration ran.

Zync has a smaller and more auditable core:

- Constructor limited to logging and launch scheduling.
- Installation after app launch with late-injection fallbacks.
- One independent installer per module.
- Runtime class discovery restricted to Zalo application images.
- Method arity and return-encoding validation.
- Deduplication and fail-safe no-op behavior.
- A plain-text boot log in the application container; viewing it in Files
  depends on the app's document-sharing configuration.

The Zync repository publishes static build gates and anchor evidence. No local
evidence currently proves its complete feature set on this user's physical
iPhone, so ZLMod must begin with a loader/settings smoke test.

## 5. Naming and product migration

The planned naming is:

| Upstream name | ZLMod name |
|---|---|
| `Zync*` Objective-C symbols | `ZLMod*` |
| `ZYNC_*` macros | `ZLMOD_*` |
| `libZync.dylib` | `libZLMod.dylib` |
| `zync.*` preference keys | `zlmod.*` |
| `vn.com.vng.zingalo.zync` suite | `vn.com.vng.zingalo.zlmod` |
| `Zync.log` | `ZLMod.log` |
| `Zync Customize` | `ZLMod Customize` |

ZLMod must preserve the upstream MIT license and attribution. The initial work
should live in a new top-level `zlmod/` directory so the current engines and
their uncommitted edits remain untouched.

## 6. Feature roadmap

### Phase 0: loadable ZLMod foundation

- Rename the Zync product and Objective-C namespace.
- Replace the single hard-coded version prefix with an explicit compatibility
  manifest.
- Support the original bundle identifier and explicitly approved sideload
  identifiers.
- Keep all feature toggles off by default for the first device smoke test.
- Adapt the existing IPA packager to `libZLMod.dylib` without duplicating the
  injection implementation.
- Add load, compatibility, installer, and per-module log events.

### Phase 1: revalidate upstream Zync behavior

- Native ZLMod settings row and dashboard.
- Hide typing, global seen suppression, and read-receipt suppression.
- Tracking/Firebase controls.
- Advertisement request and view filtering.
- Profile Music, Google Drive Backup, and More Tab restoration.
- Tab-bar material overlay.

Every upstream module must be revalidated against the newly supplied IPA. A
feature is retained only when its runtime anchors and signatures still match.

### Phase 2: rewrite ideas from `leduwn`

- **Selective Seen:** choose seen/read-receipt behavior per conversation rather
  than only through a global toggle.
- **Anti-Recall:** preserve message content in a local archive before a recall
  or delete event removes it from the visible conversation.
- **Local Mark Unread:** maintain a private visual unread state without sending
  a server-side state change.
- **Conversation Menu:** expose the local actions through Zalo's existing
  conversation context menu.
- **Quick Replies:** store and insert user-defined reply templates.
- **Delayed Send:** queue a composed message locally and send it at the selected
  time while the application can execute the action safely.
- **Private Notes:** attach local notes to a conversation without sending them
  to Zalo servers.

These are behavior goals, not permission to reuse the old hook implementations.

### Phase 3: appearance and usability

- Theme presets such as Classic Blue, Dark OLED, and Pure Black.
- Chat background, bubble, typography, navigation, and tab-bar customization.
- Import/export only after a stable, versioned settings schema exists.
- Diagnostics page showing host version, bundle identifier, matched anchors,
  installed modules, and the current log location.

## 7. Non-goals and safety boundaries

ZLMod will not target:

- Paid subscription or ZCloud entitlement bypasses.
- Fake administrator, owner, or server-controlled permissions.
- Payment modification.
- Authentication, access-token, Keychain, or account takeover behavior.
- End-to-end encryption or message-transport cryptography.
- Bulk messaging, spam, or automation that harms other users.

Server-authoritative features cannot be made reliable by changing local flags
and create a disproportionate account-ban and security risk.

## 8. New IPA intake checklist

When a newer decrypted IPA is supplied:

1. Record file name, byte size, SHA-256, Zalo version/build, minimum iOS, bundle
   identifier, executable name, UUID, architectures, and `cryptid` for every
   Mach-O image.
2. Inventory embedded frameworks and app extensions.
3. Confirm no unexpected dylib is already injected.
4. Compare the application graph to the current IPA.
5. Verify the Zync/ZLMod anchor manifest against the new main binary.
6. Inspect the owning class and method type encoding for every hook candidate.
7. Create a compatibility-manifest entry for that exact build.
8. Build a load-only dylib with every feature disabled.
9. Inject, re-sign, install, and confirm the constructor and boot log.
10. Enable and test one module at a time using a disposable account.

The latest IPA should be added as a new compatibility target. Existing targets
should not be silently widened to accept an unverified version range.

## 9. Validation levels

| Level | Required evidence |
|---|---|
| Source | Code, preference keys, and module registration are internally consistent. |
| Static artifact | ARM64 dylib, valid install name, supported minimum iOS, only intended system dependencies. |
| Package | Dylib exists in the IPA and the main executable contains the expected load command. |
| Loader | Physical-device log proves the dylib constructor executed. |
| Bootstrap | Log proves compatibility passed and module installation completed. |
| Feature | A repeatable device test proves the requested behavior and its off-state restoration. |

No feature should be described as working on-device until it reaches the final
level.

## 10. First implementation milestone

The first code milestone after receiving the newer IPA should contain only:

- The renamed ZLMod core.
- Compatibility support for the new exact build and the selected sideload
  bundle identifier.
- Logging.
- The native settings entry and an About/Diagnostics screen.
- Packaging integration.
- All behavioral feature hooks disabled.

Success means the signed application launches repeatedly, `ZLMod.log` proves
the dylib booted, and `ZLMod Customize` opens. Messaging and network hooks begin
only after that milestone is demonstrated on the device.
