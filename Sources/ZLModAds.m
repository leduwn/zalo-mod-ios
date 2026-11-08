// language: Objective-C, file: ZLModAds.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// Advertisement visibility management.
//
// Layer 1 (requests): handled by ZLModURIFilter.m — ad endpoints verified in the
//   binary: %@/zpads/inboxnative/getads, /v1/user/core/get/ads(_out_stream|_boost|v2),
//   /v1/ads/impression, https://ads.platform.zalo.me/
// Layer 2 (views): every Zalo.app view class carrying an ad marker in its name
//   (e.g. ZInstantFeedAdsView, LocationOAAdsCell — both present in the dumps)
//   is neutralized on insertion: didMoveToSuperview forces hidden, and
//   setHidden: is pinned to YES while the toggle is on. Turning the toggle off
//   restores normal behaviour on the next call.

#import "ZLMod.h"

typedef void (*ZLModV0)(id, SEL);
typedef void (*ZLModV1Bool)(id, SEL, BOOL);

static BOOL ZLModAdsClassNameMatches(Class cls) {
    NSString *name = [NSString stringWithUTF8String:class_getName(cls)].lowercaseString;
    if ([name containsString:@"adsview"]) return YES;
    if ([name containsString:@"adscell"]) return YES;
    if ([name containsString:@"adsbanner"]) return YES;
    if ([name containsString:@"advert"]) return YES;
    if ([name containsString:@"promoted"]) return YES;
    return NO;
}

static BOOL ZLModAdsClassIsView(Class cls) {
    Class cursor = cls;
    while (cursor) {
        if (cursor == [UIView class]) return YES;
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

static NSUInteger ZLModAdsHardenViews(void) {
    SEL didMoveSel = sel_registerName("didMoveToSuperview");
    SEL setHiddenSel = sel_registerName("setHidden:");
    __block NSUInteger hookCount = 0;

    ZLModEnumerateAppClasses(^(Class cls) {
        if (!ZLModAdsClassIsView(cls)) return;
        if (!ZLModAdsClassNameMatches(cls)) return;

        if (ZLModClassHasInstanceMethod(cls, didMoveSel)) {
            IMP original = class_getMethodImplementation(cls, didMoveSel);
            if (ZLModReplaceMethod(cls, didMoveSel, 0, "v", ^(id self) {
                ((ZLModV0)original)(self, didMoveSel);
                if ([[ZLModPreferences shared] boolForKey:kZLModHideAds]) {
                    ((void (*)(id, SEL, BOOL))class_getMethodImplementation([UIView class], setHiddenSel))(self, setHiddenSel, YES);
                }
            })) {
                hookCount++;
            }
        }

        if (ZLModClassHasInstanceMethod(cls, setHiddenSel)) {
            IMP original = class_getMethodImplementation(cls, setHiddenSel);
            if (ZLModReplaceMethod(cls, setHiddenSel, 1, "v", ^(id self, BOOL hidden) {
                BOOL force = [[ZLModPreferences shared] boolForKey:kZLModHideAds];
                ((ZLModV1Bool)original)(self, setHiddenSel, force ? YES : hidden);
            })) {
                hookCount++;
            }
        }
    });
    return hookCount;
}

void ZLModAdsInstall(void) {
    NSUInteger count = ZLModAdsHardenViews();
    ZLModSetModuleStatus(@"Ads",
                         count > 0 ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"viewHooks=%lu", (unsigned long)count]);
    ZLMOD_LOG(@"ads module installed (hooks=%lu)", (unsigned long)count);
}
