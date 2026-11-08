# ZLMod Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import the verified Zync upstream snapshot as a new `zlmod/` codebase, rename it to ZLMod, make it safe for exact no-jailbreak sideload targets, and establish clean-room feature research boundaries for `leduwn` and ZepLaoModMilanVu.

**Architecture:** ZLMod remains one dependency-free ARM64 Objective-C dylib loaded by the Zalo executable. Zync supplies the delayed bootstrap, validated runtime hook engine, preferences, native settings integration, and existing modules; `leduwn` and ZepLaoModMilanVu supply behavior ideas only. New messaging/media features are deferred until the newer decrypted IPA is available and their anchors and type encodings are verified.

**Tech Stack:** Objective-C ARC, Foundation/UIKit/QuartzCore, Mach-O `LC_LOAD_DYLIB`, Python `unittest` source/package contract tests, macOS Xcode command-line tools for native builds.

**Spec:** `docs/project/ZLMOD_DEVELOPMENT_NOTES.md`

## Global Constraints

- Target sideloaded, non-jailbroken iOS; no Theos, Logos, Substrate, or ElleKit dependency in ZLMod.
- Preserve the Zync MIT license and record upstream commit `2429c28a96e7a84ef7097ff4cd755694d0ab8d0d`.
- Do not copy AGPL-3.0 source from ZepLaoModMilanVu commit `522ee00a10aad97245add742cef37c35bc681d39`; use it only to identify behavior and candidate anchors unless the project is deliberately relicensed.
- Do not modify or overwrite the existing uncommitted files under `jailed-mod-engine/`.
- Use exact Zalo build and bundle-ID allowlists; an unknown build must fail closed with a diagnostic reason.
- All behavioral feature toggles default to off in the first ZLMod device build.
- Do not hook authentication, tokens, Keychain, payments, group ownership, or message encryption.
- Do not claim runtime success until a physical-device log proves constructor load, compatibility pass, and bootstrap completion.

## Review Focus

- A signer-remapped bundle ID must be explicitly allowed or fail closed rather than matching a broad prefix.
- A supported version with the wrong build must fail closed and report both detected values.
- Missing settings or tab-bar anchors must disable only the affected module, not prevent Zalo launch.
- A package with an already-present ZLMod load command must not receive a duplicate command.
- No AGPL implementation text or `ZX*` production symbol may enter `zlmod/Sources` while ZLMod remains MIT.

---

### Task 1: Import the Zync snapshot with provenance

**Files:**
- Create: `zlmod/Makefile`
- Create: `zlmod/LICENSE`
- Create: `zlmod/UPSTREAM.md`
- Create: `zlmod/Sources/Zync.h`
- Create: `zlmod/Sources/Zync*.m`
- Create: `zlmod/Scripts/anchors.txt`
- Create: `zlmod/Scripts/anchors-verify.sh`
- Create: `zlmod/Scripts/gates.sh`
- Create: `zlmod/Scripts/report.sh`
- Create: `zlmod/docs/*.md`
- Create: `zlmod/Tests/test_vendor_snapshot.py`

**Interfaces:**
- Consumes: Zync commit `2429c28a96e7a84ef7097ff4cd755694d0ab8d0d`.
- Produces: A tracked source snapshot in `zlmod/` without a nested `.git` directory.

- [ ] **Step 1: Write the failing snapshot test**

Add `test_upstream_provenance_is_pinned` and `test_snapshot_has_no_nested_git_directory` to assert that `UPSTREAM.md` contains the exact repository URL and commit and that `zlmod/.git` does not exist.

- [ ] **Step 2: Run the snapshot test to verify it fails**

Run: `python -m unittest zlmod.Tests.test_vendor_snapshot -v`

Expected: FAIL because the snapshot and provenance file do not exist.

- [ ] **Step 3: Import the exact upstream tree**

Clone Zync into a temporary directory at the pinned commit, export its tracked files into `zlmod/`, omit `.git`, and add `UPSTREAM.md` with the upstream URL, commit, import date, license, and the statement that later ZLMod changes are maintained in this repository.

- [ ] **Step 4: Run the snapshot test**

Run: `python -m unittest zlmod.Tests.test_vendor_snapshot -v`

Expected: PASS.

- [ ] **Step 5: Commit only the imported snapshot and provenance**

```bash
git add zlmod
git commit -m "chore: import pinned Zync foundation"
```

### Task 2: Rename the product and namespace to ZLMod

**Files:**
- Rename: `zlmod/Sources/Zync.h` to `zlmod/Sources/ZLMod.h`
- Rename: `zlmod/Sources/Zync*.m` to `zlmod/Sources/ZLMod*.m`
- Modify: `zlmod/Makefile`
- Modify: `zlmod/Sources/ZLMod.h`
- Modify: `zlmod/Sources/ZLMod*.m`
- Modify: `zlmod/Scripts/*.sh`
- Modify: `zlmod/Scripts/anchors.txt`
- Modify: `zlmod/docs/*.md`
- Create: `zlmod/Tests/test_product_identity.py`

**Interfaces:**
- Consumes: The imported Zync snapshot from Task 1.
- Produces: `build/libZLMod.dylib`, `ZLMod*` Objective-C symbols, `ZLMOD_*` macros, `zlmod.*` preference keys, `vn.com.vng.zingalo.zlmod` defaults suite, and `ZLMod.log`.

- [ ] **Step 1: Write the failing identity tests**

Add tests asserting:

- `Makefile` target and install name are `build/libZLMod.dylib` and `@rpath/libZLMod.dylib`.
- Every source file uses the `ZLMod`/`ZLMOD` namespace.
- Preference keys begin with `zlmod.` and the suite is `vn.com.vng.zingalo.zlmod`.
- Runtime UI/log strings use `ZLMod Customize`, `[ZLMod]`, and `ZLMod.log`.
- The only allowed occurrences of `Zync` are provenance/history text under `UPSTREAM.md`, `LICENSE`, and documentation that explicitly discusses upstream.

- [ ] **Step 2: Run the identity tests to verify they fail**

Run: `python -m unittest zlmod.Tests.test_product_identity -v`

Expected: FAIL on the upstream names.

- [ ] **Step 3: Perform the mechanical rename**

Rename files, symbols, macros, suite names, preference keys, log labels, UI labels, Makefile output, artifact install name, scripts, and ZLMod-local documentation. Preserve upstream attribution in `UPSTREAM.md`.

- [ ] **Step 4: Run identity and snapshot tests**

Run: `python -m unittest discover -s zlmod/Tests -p "test_*.py" -v`

Expected: PASS.

- [ ] **Step 5: Commit the rename**

```bash
git add zlmod
git commit -m "refactor: rename Zync foundation to ZLMod"
```

### Task 3: Replace the single-version guard with an exact compatibility policy

**Files:**
- Modify: `zlmod/Sources/ZLMod.h`
- Modify: `zlmod/Sources/ZLModCompatibility.m`
- Modify: `zlmod/Sources/ZLModCore.m`
- Modify: `zlmod/Sources/ZLModUI.m`
- Create: `zlmod/Tests/test_compatibility_contract.py`

**Interfaces:**
- Consumes: `+[NSBundle mainBundle]` metadata and runtime anchor lookup.
- Produces: `+[ZLModCompatibility hostSupported]`, `+[ZLModCompatibility hostVersion]`, `+[ZLModCompatibility supportReason]`, and `+[ZLModCompatibility anchorExists:]`.

- [ ] **Step 1: Write failing compatibility contract tests**

Add source-contract tests asserting that the policy contains exact entries for:

- `261002` / `261002802` with `vn.com.vng.zingalo` and `vn.com.vng.zingalo2`.
- `261101` / `261101802` with the same two bundle IDs.

Assert that the implementation compares short version, build, and bundle ID exactly, provides `supportReason`, and contains no `hasPrefix:` acceptance for bundle IDs or versions.

- [ ] **Step 2: Run the compatibility tests to verify they fail**

Run: `python -m unittest zlmod.Tests.test_compatibility_contract -v`

Expected: FAIL because upstream uses one prefix and one bundle ID.

- [ ] **Step 3: Implement the exact allowlist**

Represent each supported host as an immutable dictionary or small static record containing short version, build, and allowed bundle IDs. `hostSupported` succeeds only on one complete match; `supportReason` reports unsupported bundle, unsupported version/build pair, or supported target without exposing user data.

- [ ] **Step 4: Surface compatibility diagnostics in boot and About UI**

Log the detected bundle/version/build and `supportReason`. Add the same non-sensitive values to the About section so a sideload mismatch is visible without a debugger.

- [ ] **Step 5: Run the full portable test suite**

Run: `python -m unittest discover -s zlmod/Tests -p "test_*.py" -v`

Expected: PASS.

- [ ] **Step 6: Commit the compatibility policy**

```bash
git add zlmod
git commit -m "feat: add exact ZLMod host compatibility policy"
```

### Task 4: Establish smoke-safe defaults and observable bootstrap

**Files:**
- Modify: `zlmod/Sources/ZLModPreferences.m`
- Modify: `zlmod/Sources/ZLModCore.m`
- Modify: `zlmod/Sources/ZLModUI.m`
- Create: `zlmod/Tests/test_smoke_contract.py`

**Interfaces:**
- Consumes: ZLMod preferences and installer functions.
- Produces: All behavioral toggles default off, deterministic constructor/compatibility/bootstrap/module log events, and an About page showing load state.

- [ ] **Step 1: Write failing smoke-contract tests**

Assert every declared behavioral preference is registered as `NO`; settings remains reachable; core logs `loaded`, `compatibility`, each installer result, and `boot complete`; exceptions are logged per module without aborting subsequent installers.

- [ ] **Step 2: Run the smoke tests to verify they fail**

Run: `python -m unittest zlmod.Tests.test_smoke_contract -v`

Expected: FAIL where upstream defaults or logging do not satisfy the contract.

- [ ] **Step 3: Implement minimal smoke behavior**

Keep module installation so settings and diagnostics can load, but ensure every feature checks an off-by-default preference before changing host behavior. Add explicit installer start/success/skip/failure log events without logging message contents, account identifiers, URLs containing tokens, or other PII.

- [ ] **Step 4: Run all portable tests**

Run: `python -m unittest discover -s zlmod/Tests -p "test_*.py" -v`

Expected: PASS.

- [ ] **Step 5: Commit the smoke-safe baseline**

```bash
git add zlmod
git commit -m "feat: add observable smoke-safe ZLMod bootstrap"
```

### Task 5: Integrate the existing IPA packager without duplicating injection code

**Files:**
- Create: `zlmod/Scripts/package_ipa.py`
- Create: `zlmod/Tests/test_packaging_contract.py`
- Modify: `zlmod/README.md`

**Interfaces:**
- Consumes: `jailed-mod-engine/Packaging/package_jailed_ipa.py::repackage`, a decrypted IPA, `build/libZLMod.dylib`, an explicit output path, and an explicit bundle ID.
- Produces: An unsigned IPA containing `Frameworks/libZLMod.dylib` and `LC_LOAD_DYLIB @rpath/libZLMod.dylib`.

- [ ] **Step 1: Write failing packaging tests**

Add tests asserting the wrapper:

- Requires explicit `--input`, `--output`, and `--bundle-id` arguments.
- Defaults only the dylib path to `zlmod/build/libZLMod.dylib`.
- Rejects bundle IDs absent from the ZLMod compatibility policy.
- Calls the existing `repackage` function instead of carrying a second Mach-O injector.
- Preserves duplicate-load-command protection from the existing injector.

- [ ] **Step 2: Run the packaging tests to verify they fail**

Run: `python -m unittest zlmod.Tests.test_packaging_contract -v`

Expected: FAIL because the ZLMod wrapper does not exist.

- [ ] **Step 3: Implement the thin wrapper**

Load the existing packaging module by resolved repository path, validate arguments and supported bundle ID, and call `repackage` with display name `Zalo ZLMod`. Do not copy or fork `macho_injector.py`.

- [ ] **Step 4: Run portable tests and read-only IPA preflight**

Run:

```bash
python -m unittest discover -s zlmod/Tests -p "test_*.py" -v
python zalo_nonjb_smoke/ipa_preflight.py vn.com.vng.zingalo_26.10.02.ipa --require-unencrypted-main
```

Expected: all ZLMod tests pass; preflight reports `cryptid: 0` and zero encrypted Mach-O entries.

- [ ] **Step 5: Commit packaging integration**

```bash
git add zlmod
git commit -m "feat: integrate ZLMod IPA packaging"
```

### Task 6: Record clean-room feature candidates from `leduwn` and MilanVu

**Files:**
- Create: `docs/ZLMOD_SOURCE_REVIEW.md`
- Create: `zlmod/THIRD_PARTY_NOTICES.md`
- Create: `zlmod/Tests/test_license_boundary.py`
- Modify: `docs/README.md`
- Modify: `docs/ZLMOD_DEVELOPMENT_NOTES.md`

**Interfaces:**
- Consumes: behavior descriptions from the local engines and ZepLaoModMilanVu commit `522ee00a10aad97245add742cef37c35bc681d39`.
- Produces: A provenance/license notice and a prioritized clean-room feature matrix; no production hook code.

- [ ] **Step 1: Write the failing license-boundary test**

Assert that `THIRD_PARTY_NOTICES.md` identifies Zync/MIT and ZepLaoModMilanVu/AGPL-3.0, and that no `ZX*` production filenames or symbols exist under `zlmod/Sources`.

- [ ] **Step 2: Run the boundary test to verify it fails**

Run: `python -m unittest zlmod.Tests.test_license_boundary -v`

Expected: FAIL because the notice and source-review document do not exist.

- [ ] **Step 3: Write the feature-source review**

Classify candidates as follows:

- **Implement after new-IPA verification:** anti-recall local cache/history/marker, per-conversation selective seen, local unread, quick replies, delayed send, private notes, default Original photo, developer-only runtime scanner, and in-app log viewer.
- **Retain from Zync first:** typing/seen/read-receipt privacy, tracking/Firebase controls, ad filtering, restored client features, settings integration, and tab-bar material.
- **Defer:** video-transcode bypass, larger upload limits, TTL override, floating overlay bubble, and editable runtime `rules.json`.
- **Reject:** paid/server entitlement bypass, fake roles, authentication/encryption modification, spam, or account automation.

For each candidate, record source of the idea, required new-IPA anchors, local/server authority, privacy impact, failure mode, and the evidence required before implementation.

- [ ] **Step 4: Add third-party notices without importing AGPL code**

Document Zync's imported MIT snapshot and MilanVu's AGPL repository as a research reference. State explicitly that no MilanVu implementation is copied into the MIT ZLMod source at this milestone.

- [ ] **Step 5: Run all portable tests**

Run: `python -m unittest discover -s zlmod/Tests -p "test_*.py" -v`

Expected: PASS.

- [ ] **Step 6: Commit documentation and license boundary**

```bash
git add docs zlmod/THIRD_PARTY_NOTICES.md zlmod/Tests/test_license_boundary.py
git commit -m "docs: define ZLMod clean-room feature backlog"
```

### Task 7: Run native gates when a macOS/Xcode builder is available

**Files:**
- Modify only if a gate exposes a ZLMod-owned defect.

**Interfaces:**
- Consumes: The completed ZLMod source tree and an iPhoneOS SDK.
- Produces: `zlmod/build/libZLMod.dylib` with an ARM64 slice and static verification report.

- [ ] **Step 1: Run the native build**

Run: `cd zlmod && make clean && make`

Expected: `build/libZLMod.dylib` is created successfully.

- [ ] **Step 2: Run artifact gates**

Run: `cd zlmod && make gates`

Expected: ARM64, minimum iOS 15.1, `@rpath/libZLMod.dylib`, system-only dependencies, guarded newer UIKit APIs, and a valid ad-hoc signature all pass.

- [ ] **Step 3: Run the complete portable suite again**

Run: `python -m unittest discover -s zlmod/Tests -p "test_*.py" -v`

Expected: PASS.

- [ ] **Step 4: Commit only fixes required by native gates**

```bash
git add zlmod
git commit -m "fix: satisfy ZLMod native artifact gates"
```

## Deferred feature plans

After the newer decrypted IPA is supplied and its exact anchors are recorded,
create separate implementation plans for:

1. Anti-recall storage, history, and marker UI.
2. Per-conversation privacy and local unread state.
3. Quick reply, delayed send, and private notes.
4. Original-media defaults and appearance themes.

Each plan must produce one independently testable module and must not inherit
unverified selectors from any prior Zalo version.
