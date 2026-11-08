# ZLMod documentation

Last updated: 2026-11-09 (Asia/Saigon)

This directory records the current research and the proposed direction for a
non-jailbroken Zalo iOS mod.

## Documents

- [Zync features and usage](./ZYNC_FEATURES_AND_USAGE.md): what upstream Zync
  currently implements, how it is built and used, and the limitations of using
  it with a re-signed IPA.
- [ZLMod development notes](./ZLMOD_DEVELOPMENT_NOTES.md): verified facts about
  the local IPA, the decision to use Zync as the foundation, the feature ideas
  retained from the existing `leduwn` engines, and the validation plan for a
  newer decrypted IPA.
- [Source and feature review](./ZLMOD_SOURCE_REVIEW.md): clean-room decisions
  for ideas from `leduwn` and ZepLaoModMilanVu.

## Current decision

ZLMod will be developed from the Zync architecture. The existing
`jailed-mod-engine` and `mod-engine` remain research and feature references;
their unverified runtime hooks will not be copied directly.

The target is one Objective-C dylib for sideloaded, non-jailbroken iOS. It must
fail closed when the Zalo version, bundle identity, class, selector, method
arity, or type encoding does not match the compatibility manifest.
