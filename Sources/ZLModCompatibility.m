// language: Objective-C, file: ZLModCompatibility.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Host detection: exact bundle identity, version/build pair, anchor presence.

#import "ZLMod.h"
#import "ZLModCompatibilityData.h"

@implementation ZLModCompatibility

+ (BOOL)hostSupported {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = info[@"CFBundleIdentifier"] ?: @"";
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"";
    NSString *build = info[@"CFBundleVersion"] ?: @"";
    for (NSDictionary *target in ZLModSupportedHostRecords()) {
        if (![version isEqualToString:target[@"version"]]) continue;
        if (![build isEqualToString:target[@"build"]]) continue;
        for (NSString *allowedBundle in target[@"bundleIdentifiers"]) {
            if ([bundleId isEqualToString:allowedBundle]) return YES;
        }
    }
    return NO;
}

+ (NSString *)supportReason {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = info[@"CFBundleIdentifier"] ?: @"?";
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    BOOL versionBuildKnown = NO;
    for (NSDictionary *target in ZLModSupportedHostRecords()) {
        if ([version isEqualToString:target[@"version"]] && [build isEqualToString:target[@"build"]]) {
            versionBuildKnown = YES;
            for (NSString *allowedBundle in target[@"bundleIdentifiers"]) {
                if ([bundleId isEqualToString:allowedBundle]) return @"supported exact target";
            }
        }
    }
    if (versionBuildKnown) {
        return [NSString stringWithFormat:@"unsupported bundle %@", bundleId];
    }
    return [NSString stringWithFormat:@"unsupported version/build %@/%@", version, build];
}

+ (NSString *)hostVersion {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *shortVersion = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    return [NSString stringWithFormat:@"%@ (%@) — %@", shortVersion, build, [self supportReason]];
}

+ (BOOL)anchorExists:(NSString *)className {
    if (!className) return NO;
    return NSClassFromString(className) != Nil;
}

@end
