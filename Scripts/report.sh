#!/bin/bash
# ZLMod — build metadata + implementation report + compatibility report.
set -euo pipefail

DYLIB="${1:-build/libZLMod.dylib}"
OUTDIR="${2:-build}"
VERSION="${ZLMOD_VERSION:-build-5}"
TAG="${GITHUB_REF_NAME:-local}"
COMMIT="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"

mkdir -p "$OUTDIR"

shasum -a 256 "$DYLIB" | awk '{print $1}' > "$OUTDIR/libZLMod.dylib.sha256"

nm -m "$DYLIB" > "$OUTDIR/libZLMod.nm.txt" 2>/dev/null || true
otool -L "$DYLIB" > "$OUTDIR/libZLMod.otool-L.txt" 2>/dev/null || true
file "$DYLIB" > "$OUTDIR/libZLMod.file.txt" 2>/dev/null || true

BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M UTC")

cat > "$OUTDIR/IMPLEMENTATION-REPORT.md" <<EOF
# ZLMod — Implementation Report

- Version: ${VERSION}
- Build: ${BUILD_DATE}
- Commit: ${COMMIT}
- Artifact: $(basename "$DYLIB") ($(stat -f%z "$DYLIB" 2>/dev/null || stat -c%s "$DYLIB") bytes)
- SHA-256: $(cat "$OUTDIR/libZLMod.dylib.sha256")
- Target: iOS 15.1+, arm64 — Zalo 26.10.02 (261002802) & 26.11.01 (261101802), vn.com.vng.zingalo / vn.com.vng.zingalo2

## Modules

| Module | Deliverable |
|---|---|
| ZLModCore | constructor boot, module isolation, redacted ring-buffer + file logging, session observers |
| ZLModCompatibility | host identity + exact version/build gate + anchor checks |
| ZLModPreferences | persistent toggles, numeric/string settings, external App Group mirror + reset |
| ZLModHookEngine | runtime discovery, ABI-validated instance/class method replacement, safe property readers |
| ZLModCryptoStore | Keychain-backed AES-256-CBC + HMAC-SHA256 v2 storage box + accountScope resolver |
| ZLModPolicyStore | active chat context tracker + account-scoped per-conversation policies |
| ZLModURIFilter | in-process tracking/ad endpoint blocking (NSURLProtocol) |
| ZLModPrivacy | Mach-O verified Seen & Typing hooks (global + per-conversation) + Firebase off |
| ZLModConversationMenu | InboxContextMenuManager long-press menu + UXInboxMessageCell / ChatListItemCell blue dot |
| ZLModAntiRecall | local encrypted Ghost Preview (14-day TTL, explicit local-copy label, non-mutating) |
| ZLModUtilities | encrypted Private Notes, Quick Reply templates (composer insert only), Delay Send Undo FSM |
| ZLModTheme | optional theme presets + custom tint hex with baseline window/bar restoration |
| ZLModAds | ad request blocking + ad view neutralization |
| ZLModFeatures | Profile Music restore, Google Drive backup bridge, More tab key |
| ZLModSettings | ZLMod Customize row (cloned native cell) + navigation |
| ZLModUI | full settings dashboard + 6 child management/diagnostic controllers |
| ZLModGlass | tab bar glass material overlay (REAL_GLASS / BLUR tier) |

## Exported interface

\`\`\`
$(nm -g "$DYLIB" 2>/dev/null | head -50 || echo "nm unavailable")
\`\`\`
EOF

cat > "$OUTDIR/COMPATIBILITY-REPORT.md" <<EOF
# ZLMod — Compatibility Report

- Host: Zalo 26.10.02 (261002802) & 26.11.01 (261101802), vn.com.vng.zingalo / vn.com.vng.zingalo2, arm64
- Deployment target: iOS 15.1 (host MinimumOSVersion)
- Runtime guards: every host class/selector is resolved via NSClassFromString /
  sel_registerName and validated (arity + return encoding) before use; missing
  anchors degrade to a logged no-op — no crash path.
- Multi-account & encryption: per-conversation policies, Private Notes, and
  Anti-Recall records are scoped by verified accountScope (SHA-256 prefix of the
  active Zalo userId) and encrypted with AES-256-CBC + HMAC-SHA256 using a
  device-only iOS Keychain master key; unidentified state fails closed.
- Liquid Glass: UIGlassEffect used only when present at runtime (iOS 26+);
  otherwise system blur material. The host opts out of the iOS 26 redesign
  (UIDesignRequiresCompatibility=YES), so system glass adoption would require
  repackaging — documented in docs/ARCHITECTURE.md.
- Not ported by design (no usable iOS mechanism / server-authoritative / unsafe):
  Original Photo Default, ZCloud premium unlock, video transcode bypass,
  server TTL/upload limit override, group admin/owner spoofing, chat-head overlay.
EOF

echo "reports written to $OUTDIR"
