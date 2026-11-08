// language: Objective-C, file: ZLModURIFilter.m, target: iOS 15.1+ (Zalo 26.11.01, arm64)
// In-process URL blocking for telemetry and ad endpoints (NSURLProtocol layer).
// Patterns verified against the Zalo 26.11.01 binary:
//   %@/tracking, %@/tracking-v3, https://log.api.zaloapp.com/tracking(-rt)
//   %@/zpads/inboxnative/getads, /v1/user/core/get/ads(_out_stream|_boost|v2),
//   /v1/ads/impression, https://ads.platform.zalo.me/
// Blocked requests complete immediately with an empty 204 so callers see a
// valid empty response instead of a network error (no retry storms).
// Note: WKWebView traffic runs out-of-process and is not covered.

#import "ZLMod.h"

static BOOL gBlockTracking = NO;
static BOOL gBlockAds = NO;

static BOOL ZLModURLIsTracking(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path ?: @"";
    if ([host isEqualToString:@"log.api.zaloapp.com"]) return YES;
    if ([path hasPrefix:@"/tracking"]) return YES;      // covers /tracking, /tracking-v3, /tracking-rt
    if ([path containsString:@"/tracking-v3"]) return YES;
    if ([path containsString:@"/tracking-rt"]) return YES;
    return NO;
}

static BOOL ZLModURLIsAd(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path ?: @"";
    if ([host isEqualToString:@"ads.platform.zalo.me"]) return YES;
    if ([path containsString:@"/zpads/"]) return YES;
    if ([path containsString:@"/get/ads"]) return YES;       // /v1/user/core/get/ads, /adsv2
    if ([path containsString:@"/ads_out_stream"]) return YES;
    if ([path containsString:@"/ads_boost"]) return YES;
    if ([path containsString:@"/v1/ads/"]) return YES;       // /v1/ads/impression
    return NO;
}

@interface ZLModBlockURLProtocol : NSURLProtocol
@end

@implementation ZLModBlockURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return NO;
    if ([NSURLProtocol propertyForKey:@"ZLModHandled" inRequest:request]) return NO;
    if (gBlockTracking && ZLModURLIsTracking(request.URL)) return YES;
    if (gBlockAds && ZLModURLIsAd(request.URL)) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableRequest = [self.request mutableCopy];
    if (mutableRequest) {
        [NSURLProtocol setProperty:@YES forKey:@"ZLModHandled" inRequest:mutableRequest];
    }
    NSString *blocked = (gBlockTracking && ZLModURLIsTracking(self.request.URL)) ? @"tracking" : @"ads";
    ZLMOD_LOG(@"blocked %@ endpoint: %@%@", blocked, self.request.URL.host, self.request.URL.path);
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                    statusCode:204
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

static void ZLModURIFilterRefresh(void) {
    gBlockTracking = [[ZLModPreferences shared] boolForKey:kZLModBlockTracking];
    gBlockAds = [[ZLModPreferences shared] boolForKey:kZLModBlockAdRequests];
}

void ZLModURIFilterInstall(void) {
    ZLModURIFilterRefresh();
    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) {
        ZLModURIFilterRefresh();
    }];
    BOOL registered = [NSURLProtocol registerClass:[ZLModBlockURLProtocol class]];
    ZLModSetModuleStatus(@"URIFilter",
                         registered ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         registered ? @"NSURLProtocol registered (in-process)" : @"NSURLProtocol registration failed");
    ZLMOD_LOG(@"URL filter installed (tracking=%d ads=%d)", gBlockTracking, gBlockAds);
}
