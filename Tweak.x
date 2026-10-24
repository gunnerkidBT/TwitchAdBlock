#import <dlfcn.h>
#import <os/log.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <AVFoundation/AVFoundation.h>
#import "Tweak.h"
#import "SettingsKeys.h"

NSBundle *tweakBundle;
NSUserDefaults *tweakDefaults;
TWAdBlockAssetResourceLoaderDelegate *assetResourceLoaderDelegate;

// Ad-domain blocklist — requests to these hosts are failed immediately.
// `exact` is matched as-is; `suffixes` match the bare domain OR any subdomain
// (so `amazon-adsystem.com` blocks `aax-eu.amazon-adsystem.com` etc.).
// Non-static so the shared __NSURLSessionLocal hook in Emotes.x reuses it.
BOOL twab_isAdHost(NSString *host) {
  if (!host.length) return NO;
  static NSSet *exact;
  static NSArray *suffixes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    exact = [NSSet setWithObjects:
      @"edge.ads.twitch.tv",
      @"spade.twitch.tv",
      @"secure-sts-prod.imrworldwide.com",
      nil];
    suffixes = @[ @"amazon-adsystem.com" ];
  });
  if ([exact containsObject:host]) return YES;
  for (NSString *s in suffixes) {
    if ([host isEqualToString:s] ||
        [host hasSuffix:[@"." stringByAppendingString:s]]) return YES;
  }
  return NO;
}

// Playlist + HLS segment hosts. Non-static so the shared
// __NSURLSessionLocal hook in Emotes.x can use the same matcher.
// Twitch 29.4.2 uses regional / cloudfront subdomains beyond the two
// exact hosts of older builds.
BOOL twab_isPlaylistHost(NSString *host) {
  if (!host.length) return NO;
  return [host isEqualToString:@"usher.ttvnw.net"] ||
         [host isEqualToString:@"playlist.ttvnw.net"] ||
         [host hasSuffix:@".playlist.ttvnw.net"] ||   // use22.playlist.ttvnw.net etc.
         [host hasSuffix:@".hls.ttvnw.net"];          // <id>.j.cloudfront.hls.ttvnw.net etc.
}

// Stricter: hosts that serve the MASTER playlist (the one Luminous V1
// proxies know how to rewrite). Variant playlists + segments live on
// other hosts and must NOT be rewritten — the Luminous protocol can't
// handle them and the rewritten URL is meaningless to the proxy.
BOOL twab_isMasterPlaylistHost(NSString *host) {
  if (!host.length) return NO;
  return [host isEqualToString:@"usher.ttvnw.net"];
}

// ─── External-playback (Cast / AirPlay) detection ──────────────────────────
//
// When the stream goes to a TV (Chromecast or AirPlay video), the TV fetches
// the URL itself — it can't reproduce our proxy rewrite (Luminous URL / Basic
// auth / local twab: scheme), so a rewritten URL makes it crash or go
// "offline". We therefore skip proxy rewriting only while external playback is
// actually happening; normal phone viewing keeps full ad-blocking. (The cast
// stream itself is unavoidably un-ad-blocked — we can't reach the TV's fetches.)
//
// IMPORTANT: "actively casting" means a Cast session with media LOADED and not
// idle — NOT merely "connected". A connected session lingers after you stop
// casting, and using that as the signal wrongly disabled the proxy during
// normal viewing (the earlier regression). We go one level deeper:
//   currentCastSession -> remoteMediaClient -> mediaStatus -> playerState
// and require playerState to be non-idle. All via objc_msgSend so we don't link
// GoogleCast; guarded by +isSharedInstanceInitialized so we never trip the SDK.
static BOOL twab_isActivelyCasting(void) {
  Class ctxCls = objc_getClass("GCKCastContext");
  if (!ctxCls) return NO;
  if ([ctxCls respondsToSelector:@selector(isSharedInstanceInitialized)] &&
      !((BOOL (*)(id, SEL))objc_msgSend)(ctxCls, @selector(isSharedInstanceInitialized)))
    return NO;
  if (![ctxCls respondsToSelector:@selector(sharedInstance)]) return NO;
  id ctx = ((id (*)(id, SEL))objc_msgSend)(ctxCls, @selector(sharedInstance));
  if (![ctx respondsToSelector:@selector(sessionManager)]) return NO;
  id mgr = ((id (*)(id, SEL))objc_msgSend)(ctx, @selector(sessionManager));
  if (![mgr respondsToSelector:@selector(currentCastSession)]) return NO;
  id session = ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(currentCastSession));
  if (!session || ![session respondsToSelector:@selector(remoteMediaClient)]) return NO;
  id rmc = ((id (*)(id, SEL))objc_msgSend)(session, @selector(remoteMediaClient));
  if (!rmc || ![rmc respondsToSelector:@selector(mediaStatus)]) return NO;
  id status = ((id (*)(id, SEL))objc_msgSend)(rmc, @selector(mediaStatus));
  if (!status) return NO;  // nothing loaded on the receiver → not actively casting
  if (![status respondsToSelector:@selector(playerState)]) return YES;
  NSInteger ps = ((NSInteger (*)(id, SEL))objc_msgSend)(status, @selector(playerState));
  return ps != 0 && ps != 1;  // GCKMediaPlayerState: 0 Unknown, 1 Idle → not active
}

// AirPlay: audio routed to an AirPlay output. Covers AirPlay video (the case
// that breaks); also true during screen mirroring, where skipping the proxy is
// unnecessary but harmless (that mirrored stream just isn't ad-blocked).
static BOOL twab_isAirPlaying(void) {
  AVAudioSession *s = [AVAudioSession sharedInstance];
  for (AVAudioSessionPortDescription *o in s.currentRoute.outputs)
    if ([o.portType isEqualToString:AVAudioSessionPortAirPlay]) return YES;
  return NO;
}

// Skip the proxy while the stream is on an external device. Logs only when it
// actually skips (rare — external playback only), matching the proxy-debug
// logging style. Non-static so Emotes.x's __NSURLSessionLocal hook can use it.
BOOL twab_isExternalPlayback(void) {
  BOOL cast = twab_isActivelyCasting();
  BOOL air = cast ? NO : twab_isAirPlaying();
  if (cast || air)
    os_log(OS_LOG_DEFAULT,
        "[TWAB-Ext] external playback (cast=%d airplay=%d) — skipping proxy", cast, air);
  return cast || air;
}

// Server-side video ad blocking

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  // Targeted diagnostic — only video-path hosts. See the same comment in
  // Emotes.x's __NSURLSessionLocal hook: per-URL logging at Twitch's
  // request rate overflows the log buffers and we lose the lines that
  // actually matter ([TWAB-Proxy], rewrite confirmations).
  NSString *_host = request.URL.host;
  if (_host && (twab_isPlaylistHost(_host) ||
                [_host hasSuffix:@"ttvnw.net"])) {
    os_log(OS_LOG_DEFAULT,
      "[TWAB-URL] NSURLSession host=%{public}@ path=%{public}@",
      _host, request.URL.path ?: @"?");
  }
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if (twab_isAdHost(request.URL.host))
    return nil;
  if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
  ((NSMutableURLRequest *)request).HTTPBody = [request.HTTPBody twab_requestDataForRequest:request];
  if (![tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled]) return %orig;
  if (!twab_isMasterPlaylistHost(request.URL.host)) return %orig;
  if (twab_isExternalPlayback()) return %orig;  // Cast/AirPlay — send a clean URL
  // V2 URL rewrite only on this shadowed public hook (video traffic goes
  // through __NSURLSessionLocal in Emotes.x which has the richer routing
  // logic including CONNECT fallback + subscriber bypass). Try each
  // configured proxy until one rewrites successfully.
  for (NSString *proxyAddr in twab_effectiveProxyAddresses()) {
    NSURL *proxyURL = twab_normalizedProxyURL(proxyAddr);
    if (!proxyURL) continue;
    NSURL *rewritten = [request.URL twab_URLWithProxyURL:proxyURL];
    if (![rewritten isEqual:request.URL]) {
      ((NSMutableURLRequest *)request).URL = rewritten;
      NSString *auth = twab_basicAuthHeader(proxyURL);
      if (auth) [(NSMutableURLRequest *)request setValue:auth forHTTPHeaderField:@"Authorization"];
      break;
    }
  }
  return %orig;
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if (twab_isAdHost(request.URL.host))
    return nil;
  if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
  bodyData = [bodyData twab_requestDataForRequest:request];
  if (![tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled]) return %orig;
  if (!twab_isMasterPlaylistHost(request.URL.host)) return %orig;
  if (twab_isExternalPlayback()) return %orig;  // Cast/AirPlay — send a clean URL
  for (NSString *proxyAddr in twab_effectiveProxyAddresses()) {
    NSURL *proxyURL = twab_normalizedProxyURL(proxyAddr);
    if (!proxyURL) continue;
    NSURL *rewritten = [request.URL twab_URLWithProxyURL:proxyURL];
    if (![rewritten isEqual:request.URL]) {
      ((NSMutableURLRequest *)request).URL = rewritten;
      NSString *auth = twab_basicAuthHeader(proxyURL);
      if (auth) [(NSMutableURLRequest *)request setValue:auth forHTTPHeaderField:@"Authorization"];
      break;
    }
  }
  return %orig;
}
%end

%hook AVURLAsset
- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
  // AVURLAsset hits are rare (one per stream-load), so log unconditionally.
  if (URL.host && ([URL.host hasSuffix:@"ttvnw.net"] || [URL.host hasSuffix:@"twitch.tv"])) {
    os_log(OS_LOG_DEFAULT,
      "[TWAB-URL] AVAsset host=%{public}@ scheme=%{public}@ path=%{public}@ playlist=%d",
      URL.host, URL.scheme ?: @"?", URL.path ?: @"/", twab_isPlaylistHost(URL.host));
  }
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled] ||
      ![tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled] ||
      ![URL.scheme isEqualToString:@"https"] || !twab_isPlaylistHost(URL.host))
    return %orig;
  // While casting / AirPlaying, don't rewrite — the TV can't reproduce the
  // proxy URL / twab: scheme. Send a clean, playable URL instead.
  if (twab_isExternalPlayback()) return %orig;
  // Only the master playlist host (usher.ttvnw.net) can be V2-rewritten.
  // Variant playlists + segments fall through to the AVAssetResourceLoaderDelegate
  // path below, which proxies them via its own NSURLSession. Try each
  // configured proxy until one rewrites successfully. AVURLAsset accepts
  // extra HTTP headers via the undocumented AVURLAssetHTTPHeaderFieldsKey
  // option — used here to inject Basic auth for proxies that need it.
  if (twab_isMasterPlaylistHost(URL.host)) {
    for (NSString *proxyAddr in twab_effectiveProxyAddresses()) {
      NSURL *proxyURL = twab_normalizedProxyURL(proxyAddr);
      if (!proxyURL) continue;
      NSURL *rewritten = [URL twab_URLWithProxyURL:proxyURL];
      if (![rewritten isEqual:URL]) {
        NSString *auth = twab_basicAuthHeader(proxyURL);
        if (auth) {
          NSMutableDictionary *opts = options.mutableCopy ?: [NSMutableDictionary dictionary];
          NSMutableDictionary *headers = [opts[@"AVURLAssetHTTPHeaderFieldsKey"] mutableCopy] ?: [NSMutableDictionary dictionary];
          headers[@"Authorization"] = auth;
          opts[@"AVURLAssetHTTPHeaderFieldsKey"] = headers;
          options = opts;
        }
        return %orig(rewritten, options);
      }
    }
  }
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"twab";
  URL = components.URL;
  if ((self = %orig)) {
    [self.resourceLoader setDelegate:assetResourceLoaderDelegate
                               queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
  }
  return self;
}
%end

// Asset resource loader delegate hook — present in older Twitch versions; silently skipped if missing.
%hook _TtC6Twitch27AssetResourceLoaderDelegate
%new
- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSURL *URL = loadingRequest.request.URL;
  if (![URL.scheme isEqualToString:@"twab"]) return NO;
  AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  components.scheme = @"https";
  NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
  request.URL = components.URL;
  NSString *proxy = [tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled]
                        ? [tweakDefaults stringForKey:TWABKeyAdBlockProxy]
                        : PROXY_ADDR;
  NSURLSession *session = [[NSURLSession alloc] twab_proxySessionWithAddress:proxy];
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) return [loadingRequest finishLoadingWithError:error];
                loadingRequest.contentInformationRequest.contentType = AVFileTypeMPEG4;
                [dataRequest respondWithData:data];
                [loadingRequest finishLoading];
              }] resume];
  return YES;
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
  return ![self handleLoadingRequest:loadingRequest] ? %orig : YES;
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
  return ![self handleLoadingRequest:renewalRequest] ? %orig : YES;
}
%end

%hook AVPlayer
- (instancetype)init {
  if ((self = %orig)) {
    [self addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:NULL];
  }
  return self;
}
%new
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
  if ([keyPath isEqualToString:@"status"] &&
      [change[NSKeyValueChangeNewKey] integerValue] == AVPlayerStatusReadyToPlay)
    [self play];
}
%end

// Client-side video ad blocking

static void removeAdControllers(void *ptr) {
  if (((uintptr_t)ptr & 0xFFFF800000000000) != 0) return;
  id obj = (__bridge id)ptr;
  Ivar theaterAdControllerIvar =
      class_getInstanceVariable(object_getClass(obj), "theaterAdController");
  if (!theaterAdControllerIvar) return;
  id theaterAdController = object_getIvar(obj, theaterAdControllerIvar);
  const char *ivars[] = {"displayAdController", "streamDisplayAdStateManager", "vastAdController"};
  for (int i = 0; i < sizeof(ivars) / sizeof(ivars[0]); i++) {
    Ivar adControllerIvar =
        class_getInstanceVariable(object_getClass(theaterAdController), ivars[i]);
    if (adControllerIvar) object_setIvar(theaterAdController, adControllerIvar, nil);
  }
}

static void *(*orig_swift_unknownObjectWeakAssign)(void *, void *);
static void *hook_swift_unknownObjectWeakAssign(void *ref, void *value) {
  void *result = orig_swift_unknownObjectWeakAssign(ref, value);
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return result;
  removeAdControllers(value);
  return result;
}

static void *(*orig_swift_unknownObjectWeakLoadStrong)(void *);
static void *hook_swift_unknownObjectWeakLoadStrong(void *ref) {
  void *result = orig_swift_unknownObjectWeakLoadStrong(ref);
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return result;
  removeAdControllers(result);
  return result;
}

// Block ads in feed tab — hook old TKURLSessionClient name (pre-29.x) and
// Apollo name (29.x+). Whichever class doesn't exist at runtime is silently
// skipped. Both hook bodies delegate to the same helper so adding another
// client class in a future Twitch version means one more hook block but no
// duplicated logic.

// Keep Live Feed Playing, byte level. Independent of which operation carries
// it, whether the JSON arrives in one chunk, or whether it parses at all:
// rewrite the number after "maxStreamWatchSeconds": / "maxWatchSeconds": in
// the raw bytes to 1,000,000 (JS-timer-safe; see NSData+TwitchAdBlock.m).
// Also traces every response carrying such a field, so a new source shows up
// in the log. (A key split across two chunks would slip past; rare, and the
// JSON-level pass catches whole documents anyway.)
static NSData *twab_rewriteWatchLimitBytes(NSData *data, NSURLRequest *request, NSString *via) {
  if (data.length < 20 || ![tweakDefaults boolForKey:TWABKeyAdBlockEnabled] ||
      ![tweakDefaults boolForKey:TWABKeyDisableWatchLimit]) return data;
  if ([data rangeOfData:[@"atchSeconds\"" dataUsingEncoding:NSUTF8StringEncoding]
                options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) return data;
  NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (!s) return data;  // chunk split mid-UTF-8 sequence; JSON pass may still catch it
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression regularExpressionWithPattern:
            @"(\"(?:maxStreamWatchSeconds|maxWatchSeconds)\"\\s*:\\s*)(\\d+)" options:0 error:nil];
  });
  NSArray<NSTextCheckingResult *> *matches = [re matchesInString:s options:0 range:NSMakeRange(0, s.length)];
  if (!matches.count) return data;
  // React Native's Live feed (31.x) still cut off with 1,000,000, so its JS
  // evidently clamps large values; for it, null — "no limit configured" — is
  // used instead (JS doesn't schema-check, and treats a missing limit as none).
  // Native Apollo parses against the schema, so it keeps the big number.
  NSString *replacement = [via isEqualToString:@"RCTHTTPRequestHandler"] ? @"null" : @"1000000";
  NSMutableArray *seen = [NSMutableArray array];
  NSMutableString *out = [s mutableCopy];
  BOOL changed = NO;
  // Back to front so earlier ranges stay valid.
  for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
    [seen insertObject:[s substringWithRange:m.range] atIndex:0];
    NSRange num = [m rangeAtIndex:2];
    if (![[s substringWithRange:num] isEqualToString:replacement]) {
      [out replaceCharactersInRange:num withString:replacement];
      changed = YES;
    }
  }
  os_log(OS_LOG_DEFAULT, "[TWAB-Watch] watch limit in %{public}@%{public}@ via %{public}@: %{public}@ -> %{public}@",
         request.URL.host ?: @"?", request.URL.path ?: @"", via,
         [seen componentsJoinedByString:@", "], replacement);
  return changed ? [out dataUsingEncoding:NSUTF8StringEncoding] : data;
}

static NSData *twab_filteredFeedData(id delegate, NSData *data, NSURLSessionDataTask *dataTask) {
  data = twab_rewriteWatchLimitBytes(data, dataTask.currentRequest, NSStringFromClass([delegate class]));
  // Ad-block (ad strip, watch limit) and Hide Stories (empties the Stories
  // shelf response) both filter here; each is gated inside on its own toggle.
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled] &&
      ![tweakDefaults boolForKey:TWABKeyHideStories]) return data;
  return [data twab_responseDataForRequest:dataTask.currentRequest];
}

// Keep Live Feed Playing — the native feed prefetch (31.x). The React Native
// Live feed's first page is fetched natively (DiscoveryFeedPreloadGqlFetcher,
// behind ios_discovery_feed_native_gql_prefetch) outside every network hook
// above, then handed to JS by the bridge method -awaitFeedPreload:rejecter:.
// Its watch limit is what the feed actually enforces. Wrap that method's
// resolve block so whatever it hands JS (JSON text or parsed objects) has
// maxStreamWatchSeconds / maxWatchSeconds nulled — "no limit" to JS.
typedef void (^twab_rnResolve)(id result);
typedef void (^twab_rnReject)(NSString *code, NSString *message, NSError *error);

static NSUInteger twab_preloadLimitsNulled;

static id twab_nullWatchLimits(id obj, NSUInteger depth) {
  if (!obj || depth > 40) return obj;
  if ([obj isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *d = [(NSDictionary *)obj mutableCopy];
    for (id key in [d allKeys]) {
      if ([key isEqual:@"maxStreamWatchSeconds"] || [key isEqual:@"maxWatchSeconds"]) {
        if (d[key] != (id)kCFNull) {
          os_log(OS_LOG_DEFAULT, "[TWAB-Watch] feed preload: %{public}@ %{public}@ -> null", key, d[key]);
          d[key] = (id)kCFNull;
          twab_preloadLimitsNulled++;
        }
      } else {
        d[key] = twab_nullWatchLimits(d[key], depth + 1);
      }
    }
    return d;
  }
  if ([obj isKindOfClass:NSArray.class]) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
    for (id v in (NSArray *)obj) [a addObject:twab_nullWatchLimits(v, depth + 1) ?: (id)kCFNull];
    return a;
  }
  if ([obj isKindOfClass:NSString.class] && [(NSString *)obj containsString:@"atchSeconds"]) {
    // JSON text (possibly escaped inside another JSON string).
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      re = [NSRegularExpression regularExpressionWithPattern:
              @"(\\\\?\"(?:maxStreamWatchSeconds|maxWatchSeconds)\\\\?\"\\s*:\\s*)\\d+" options:0 error:nil];
    });
    NSString *s = obj;
    NSUInteger before = [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!before) return obj;
    os_log(OS_LOG_DEFAULT, "[TWAB-Watch] feed preload: nulled %lu watch limit(s) in JSON text", (unsigned long)before);
    twab_preloadLimitsNulled += before;
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length)
                                   withTemplate:@"$1null"];
  }
  return obj;
}

static void twab_hookFeedPreload(void) {
  SEL sel = NSSelectorFromString(@"awaitFeedPreload:rejecter:");
  BOOL found = NO;
  unsigned int count = 0;
  const char **names = objc_copyClassNamesForImage(NSBundle.mainBundle.executablePath.UTF8String, &count);
  for (unsigned int i = 0; i < count; i++) {
    // Only bridge-module-ish classes; avoids realizing thousands of classes.
    if (!strstr(names[i], "RN") && !strstr(names[i], "Preload") && !strstr(names[i], "Feed")) continue;
    Class cls = objc_getClass(names[i]);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) continue;
    Class sup = class_getSuperclass(cls);
    if (sup && class_getInstanceMethod(sup, sel) == m) continue;  // inherited; hook the definer
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, twab_rnResolve resolve, twab_rnReject reject) {
      twab_rnResolve wrapped = resolve;
      if (resolve && [tweakDefaults boolForKey:TWABKeyAdBlockEnabled] &&
          [tweakDefaults boolForKey:TWABKeyDisableWatchLimit]) {
        wrapped = ^(id result) {
          NSUInteger before = twab_preloadLimitsNulled;
          id out = twab_nullWatchLimits(result, 0);
          os_log(OS_LOG_DEFAULT, "[TWAB-Watch] feed preload resolved (%{public}@), limits nulled: %lu",
                 NSStringFromClass([result class]), (unsigned long)(twab_preloadLimitsNulled - before));
          resolve(out);
        };
      }
      ((void (*)(id, SEL, twab_rnResolve, twab_rnReject))orig)(self, sel, wrapped, reject);
    }));
    os_log(OS_LOG_DEFAULT, "[TWAB-Watch] hooked feed preload bridge on %{public}s", names[i]);
    found = YES;
  }
  free(names);
  if (!found)
    os_log(OS_LOG_DEFAULT, "[TWAB-Watch] no class implements awaitFeedPreload:rejecter: (pre-31 Twitch?)");
}

// Diagnostic: tells whether the Watch/Follow overlay on screen is the native
// one (this view) or React Native's (no log line).
%hook _TtC6Twitch33EvolveFeedMaxWatchtimeOverlayView
- (void)didMoveToWindow {
  %orig;
  if (((UIView *)self).window)
    os_log(OS_LOG_DEFAULT, "[TWAB-Watch] NATIVE max-watch overlay shown (EvolveFeedMaxWatchtimeOverlayView)");
}
%end

// Completion-handler requests (including Swift's async data(for:)) never
// reach the delegate hooks below, so the watch-limit byte rewrite also wraps
// their handlers. Only touches responses that contain a watch-limit field.
typedef void (^twab_dataCompletion)(NSData *, NSURLResponse *, NSError *);

static twab_dataCompletion twab_wrapWatchCompletion(NSURLRequest *request, twab_dataCompletion handler) {
  if (!handler) return handler;
  return ^(NSData *data, NSURLResponse *response, NSError *error) {
    handler(data ? twab_rewriteWatchLimitBytes(data, request, @"completionHandler") : data, response, error);
  };
}

%hook __NSURLSessionLocal
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
  return %orig(request, twab_wrapWatchCompletion(request, completionHandler));
}
%end

%hook _TtC9TwitchKit18TKURLSessionClient
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  %orig(session, dataTask, twab_filteredFeedData(self, data, dataTask));
}
%end

// Apollo.URLSessionClient — used in Twitch 29.x+
%hook _TtC6Apollo16URLSessionClient
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  %orig(session, dataTask, twab_filteredFeedData(self, data, dataTask));
}
%end

// React Native's networking (Twitch 31.x ships React Native screens that make
// their own GraphQL calls via fetch). Same filter; it only rewrites
// gql.twitch.tv/gql responses that actually carry ad nodes or a watch limit.
%hook RCTHTTPRequestHandler
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  %orig(session, dataTask, twab_filteredFeedData(self, data, dataTask));
}
%end

// Block ads in following tab.
// All init variants are listed; Logos silently skips selectors that don't exist.

%hook _TtC6Twitch23FollowingViewController

static void twab_clearFollowingAds(id self) {
  Ivar headlinerManagerIvar = class_getInstanceVariable(object_getClass(self), "headlinerManager");
  if (!headlinerManagerIvar) return;
  Ivar displayAdStateManagerIvar =
      class_getInstanceVariable(object_getClass(self), "displayAdStateManager");
  if (displayAdStateManagerIvar) object_setIvar(self, displayAdStateManagerIvar, nil);
}

// Pre-29.x (2-arg)
- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(id)themeManager {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if ((self = %orig)) twab_clearFollowingAds(self);
  return self;
}
// 23.x – 28.x (3-arg)
- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(id)themeManager
                  urlController:(_TtC6Twitch13URLController *)urlController {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if ((self = %orig)) twab_clearFollowingAds(self);
  return self;
}
// 29.x – 30.x (4-arg)
- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(id)themeManager
                  urlController:(_TtC6Twitch13URLController *)urlController
                   isInitialTab:(BOOL)isInitialTab {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if ((self = %orig)) twab_clearFollowingAds(self);
  return self;
}
// 31.x+ — the GraphQL argument was dropped.
- (instancetype)initWithThemeManager:(id)themeManager
                       urlController:(_TtC6Twitch13URLController *)urlController
                        isInitialTab:(BOOL)isInitialTab {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if ((self = %orig)) twab_clearFollowingAds(self);
  return self;
}
- (instancetype)initWithThemeManager:(id)themeManager
                       urlController:(_TtC6Twitch13URLController *)urlController {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if ((self = %orig)) twab_clearFollowingAds(self);
  return self;
}
%end

%hook _TtC6Twitch27HeadlinerFollowingAdManager
+ (instancetype)shared {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  _TtC6Twitch27HeadlinerFollowingAdManager *shared = %orig;
  if (shared) {
    Ivar displayAdStateManagerIvar =
        class_getInstanceVariable(object_getClass(shared), "displayAdStateManager");
    if (displayAdStateManagerIvar) object_setIvar(shared, displayAdStateManagerIvar, nil);
  }
  return shared;
}
%end

// Block update prompt

%hook TWAppUpdatePrompt
+ (void)startMonitoringSavantSettingsToShowPromptIfNeeded {
}
%end

// Default-launch tab + sub-tab. dispatch_once on each hook so manual user
// navigation after launch is never overridden.
//
// Tab bar: TWLaunchTab >= 0 → set selectedIndex.
// Home sub (DiscoveryFeedTabViewController): TWLaunchSubTab >= 0 AND
//   parent tab == 0 → call selectViewControllerAtIndex:.
// Browse sub (BrowseViewController): TWLaunchSubTab >= 0 AND parent tab
//   == 1 → call selectViewControllerAtIndex:.
// 31.x picks its own starting tab (InitialHomeTabSetting / an initial-tab
// experiment) during a splash phase, which can land *after* the tab bar first
// appears and silently undo ours. So: apply on first appearance, then re-check
// at 0.5s / 1.5s / 3s and re-apply if something else moved it — but stop for
// good the moment the user taps a tab, so we never fight them.
static BOOL twab_userPickedTab = NO;

static void twab_applyLaunchTab(UITabBarController *tbc, NSString *when) {
    if (twab_userPickedTab || ![tweakDefaults objectForKey:TWABKeyLaunchTab]) return;
    NSInteger idx = [tweakDefaults integerForKey:TWABKeyLaunchTab];
    NSUInteger count = tbc.viewControllers.count;
    if (idx < 0 || idx >= (NSInteger)count) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Launch] tab %ld out of range (%lu tabs) at %{public}@",
               (long)idx, (unsigned long)count, when);
        return;
    }
    if (tbc.selectedIndex == (NSUInteger)idx) return;
    os_log(OS_LOG_DEFAULT, "[TWAB-Launch] %{public}@: selected tab %lu (%{public}@) -> %ld (%{public}@)",
           when, (unsigned long)tbc.selectedIndex,
           NSStringFromClass([tbc.selectedViewController class]), (long)idx,
           NSStringFromClass([tbc.viewControllers[idx] class]));
    tbc.selectedIndex = (NSUInteger)idx;
}

%hook _TtC6Twitch16TabBarController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UITabBarController *tbc = (UITabBarController *)self;
        NSMutableArray *names = [NSMutableArray array];
        for (UIViewController *vc in tbc.viewControllers) [names addObject:NSStringFromClass(vc.class)];
        os_log(OS_LOG_DEFAULT, "[TWAB-Launch] tab bar appeared: %lu tabs [%{public}@], selected %lu",
               (unsigned long)names.count, [names componentsJoinedByString:@", "],
               (unsigned long)tbc.selectedIndex);
        twab_applyLaunchTab(tbc, @"appear");
        __weak UITabBarController *weakTbc = tbc;
        for (NSNumber *ms in @[@500, @1500, @3000]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms.longLongValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                UITabBarController *strong = weakTbc;
                if (strong) twab_applyLaunchTab(strong, [NSString stringWithFormat:@"+%@ms", ms]);
            });
        }
    });
}
// A real tab tap — from here on the user is in charge.
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    twab_userPickedTab = YES;
    %orig;
}
%end

static void twab_applySubTab(id self, NSInteger expectedParent, BOOL animated) {
    if (![tweakDefaults objectForKey:TWABKeyLaunchSubTab]) return;
    NSInteger parent = [tweakDefaults integerForKey:TWABKeyLaunchTab];
    if (parent != expectedParent) return;
    NSInteger sub = [tweakDefaults integerForKey:TWABKeyLaunchSubTab];
    SEL sel = @selector(selectViewControllerAtIndex:animated:);
    if (![self respondsToSelector:sel]) {
        os_log_error(OS_LOG_DEFAULT,
            "[TWAB-Launch] subTab: %{public}@ does not respond to selectViewControllerAtIndex:",
            NSStringFromClass([self class]));
        return;
    }
    os_log(OS_LOG_DEFAULT,
        "[TWAB-Launch] subTab: selectViewControllerAtIndex:%ld animated:%d on %{public}@",
        (long)sub, animated, NSStringFromClass([self class]));
    ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(self, sel, sub, animated);
}

// Find the paged scroll view (the one whose contentSize is wider than its
// bounds — that's the horizontal page strip).
static UIScrollView *twab_findPagedScrollView(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)root;
        if (sv.contentSize.width > sv.bounds.size.width + 1) return sv;
    }
    for (UIView *sub in root.subviews) {
        UIScrollView *found = twab_findPagedScrollView(sub);
        if (found) return found;
    }
    return nil;
}

// Walk superclass chain to find an ivar by name.
static Ivar twab_findIvar(id obj, const char *name) {
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        Ivar iv = class_getInstanceVariable(cls, name);
        if (iv) return iv;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

// Home sub-tab override. selectViewControllerAtIndex: was a no-op, KVC
// throws on Swift-private ivars, and init runs before our hooks install.
// So in viewDidLayoutSubviews (which fires multiple times — dispatch_once
// catches the first useful one), find the paged scroll view directly and
// set its contentOffset to the target page, and also write the internal
// selectedContentViewControllerIndex ivar so the top-tab indicator
// follows the new selection.
// Defined later in this file — scans all windows for the "Go Ad-Free" upsell.
static void twab_handleAdFree(void);

// Returns YES when the desired page is showing (or the user took over).
static BOOL twab_applyHomeSubTab(id self, NSString *when) {
    static BOOL userSwiped = NO;
    if (userSwiped) return YES;
    if (![tweakDefaults objectForKey:TWABKeyLaunchSubTab]) return YES;
    if ([tweakDefaults integerForKey:TWABKeyLaunchTab] != 0) return YES;
    NSInteger sub = [tweakDefaults integerForKey:TWABKeyLaunchSubTab];
    if (sub < 0) return YES;

    UIView *view = ((UIViewController *)self).view;
    UIScrollView *sv = twab_findPagedScrollView(view);
    if (!sv) return NO;
    // The user is swiping between Home's pages — hands off from now on.
    if (sv.isTracking || sv.isDragging || sv.isDecelerating) {
        userSwiped = YES;
        return YES;
    }
    CGFloat pageWidth = sv.bounds.size.width;
    if (pageWidth <= 0) return NO;
    CGFloat desired = pageWidth * (CGFloat)sub;
    CGFloat currentX = sv.contentOffset.x;
    if (fabs(currentX - desired) < 1.0) return YES;

    os_log(OS_LOG_DEFAULT,
        "[TWAB-Launch] sub-tab %{public}@: sub=%ld pageWidth=%.0f currentX=%.0f desired=%.0f contentSize=%{public}@",
        when, (long)sub, pageWidth, currentX, desired, NSStringFromCGSize(sv.contentSize));
    [sv setContentOffset:CGPointMake(desired, 0) animated:NO];

    // Also write the internal index ivar so the top-tab indicator agrees
    // with where we just scrolled.
    Ivar iv = twab_findIvar((id)self, "selectedContentViewControllerIndex");
    if (iv) {
        NSInteger *p = (NSInteger *)((char *)(__bridge void *)self + ivar_getOffset(iv));
        *p = sub;
    }
    return NO;
}

%hook _TtC6Twitch30DiscoveryFeedTabViewController
- (void)viewDidLayoutSubviews {
    %orig;
    twab_handleAdFree();
    // Up to 5 layout passes (the first may be too early: zero bounds / one
    // page), then timed re-checks over the first 3s in case Twitch's own
    // initial-tab logic (31.x) switches the page after ours.
    static int attempts = 0;
    if (attempts >= 5) return;
    attempts++;
    twab_applyHomeSubTab(self, [NSString stringWithFormat:@"layout %d", attempts]);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __weak id weakSelf = self;
        for (NSNumber *ms in @[@500, @1500, @3000]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms.longLongValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                id strong = weakSelf;
                if (strong) twab_applyHomeSubTab(strong, [NSString stringWithFormat:@"+%@ms", ms]);
            });
        }
    });
}
%end

%hook _TtC6Twitch20BrowseViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ twab_applySubTab(self, 1, NO); });
}
%end

// Hide Stories: the Home tab carries a horizontal "Stories" strip wrapped
// in a ShelfView, hosting a UIHostingController whose Swift generic
// parameter is Twitch.StoryViewerListCollapsibleView. The host is nested
// 2+ levels deep so we recurse the child-VC tree (and as a fallback the
// subview tree, in case the wrapper is a plain UIView).
//
// Dispatch_once so toggling off requires an app restart — re-attaching a
// removed VC is more involved than the cost saves.
static UIViewController *twab_findChildVCMatching(UIViewController *parent, NSString *needle) {
    for (UIViewController *child in parent.childViewControllers) {
        if ([NSStringFromClass([child class]) containsString:needle]) return child;
        UIViewController *deep = twab_findChildVCMatching(child, needle);
        if (deep) return deep;
    }
    return nil;
}

static UIView *twab_findSubviewMatching(UIView *root, NSString *needle) {
    if (!root) return nil;
    if ([NSStringFromClass([root class]) containsString:needle]) return root;
    for (UIView *sub in root.subviews) {
        UIView *deep = twab_findSubviewMatching(sub, needle);
        if (deep) return deep;
    }
    return nil;
}

static void twab_dumpVCTree(UIViewController *vc, int depth) {
    NSMutableString *indent = [NSMutableString string];
    for (int i = 0; i < depth; i++) [indent appendString:@"  "];
    os_log(OS_LOG_DEFAULT, "[TWAB-Stories] %{public}@%{public}@",
           indent, NSStringFromClass([vc class]));
    for (UIViewController *child in vc.childViewControllers) {
        twab_dumpVCTree(child, depth + 1);
    }
}

// Collapse a view's height to 0 by removing it from its superview AND
// pinning the immediate parent's height to 0. The parent doesn't auto-
// collapse on its own (it isn't a UIStackView), so the second step is
// what actually closes the gap.
static void twab_removeAndCollapseSlot(UIView *view) {
    UIView *parent = view.superview;
    [view removeFromSuperview];
    if (!parent) return;
    parent.hidden = YES;
    NSLayoutConstraint *zero = [parent.heightAnchor constraintEqualToConstant:0];
    zero.priority = UILayoutPriorityRequired;
    zero.active = YES;
}

static BOOL twab_tryHideStories(UIViewController *vc) {
    UIView *targetView = twab_findSubviewMatching(vc.view, @"StoryViewerListCollapsibleView");
    if (targetView) {
        os_log(OS_LOG_DEFAULT,
            "[TWAB-Stories] removing view %{public}@ (parent=%{public}@)",
            NSStringFromClass([targetView class]),
            NSStringFromClass([targetView.superview class]));
        twab_removeAndCollapseSlot(targetView);
        return YES;
    }
    UIViewController *targetVC = twab_findChildVCMatching(vc, @"StoryViewerListCollapsibleView");
    if (targetVC) {
        os_log(OS_LOG_DEFAULT,
            "[TWAB-Stories] removing VC %{public}@ (parent view=%{public}@)",
            NSStringFromClass([targetVC class]),
            NSStringFromClass([targetVC.view.superview class]));
        UIView *parent = targetVC.view.superview;
        [targetVC willMoveToParentViewController:nil];
        [targetVC.view removeFromSuperview];
        [targetVC removeFromParentViewController];
        if (parent) {
            parent.hidden = YES;
            NSLayoutConstraint *zero = [parent.heightAnchor constraintEqualToConstant:0];
            zero.priority = UILayoutPriorityRequired;
            zero.active = YES;
        }
        return YES;
    }
    return NO;
}

%hook _TtC6Twitch41DiscoveryFeedShelfContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (![tweakDefaults boolForKey:TWABKeyHideStories]) return;
    static BOOL done = NO;
    if (done) return;

    // Each layout pass is an attempt. Cheap — if not found, scan returns
    // nil; if found, we remove and never run again.
    if (twab_tryHideStories((UIViewController *)self)) {
        done = YES;
        return;
    }

    // Plus delayed retries — the SwiftUI host is added lazily a moment
    // after viewDidLayoutSubviews first fires, so we sweep across the
    // first few seconds.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIViewController *vc = (UIViewController *)self;
        __weak UIViewController *weakVC = vc;
        NSArray<NSNumber *> *delays = @[@500, @1500, @3000, @5000];
        for (NSNumber *ms in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms.intValue * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                if (done) return;
                UIViewController *strong = weakVC;
                if (!strong) return;
                if (twab_tryHideStories(strong)) done = YES;
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (!done) {
                os_log_error(OS_LOG_DEFAULT,
                    "[TWAB-Stories] gave up after 6s — host never appeared");
                UIViewController *strong = weakVC;
                if (strong) twab_dumpVCTree(strong, 0);
            }
        });
    });
}
%end

// Hide the "Go Ad-Free" Turbo upsell button on the Following tab.
//
// It's a TwitchCoreUI.StandardButton with the title "Go Ad-Free", living in the
// "Live Now" section header (NOT in FollowingViewController.view directly). We
// hook the button class so it's hidden the instant it lays out — matched by its
// title / accessibility label (it's drawn by a Swift control, so we can't key
// off the class name). A window scan runs as a backup. We never touch the
// dedicated Turbo purchase screen. NOTE: the leftover header height is fixed by
// Twitch's feed collection layout (it ignores view-level size overrides), so we
// hide the button but don't fight the layout to reclaim that ~24pt of padding.
static BOOL twab_viewInPurchaseScreen(UIView *v) {
  Class purchase = objc_getClass("_TtC6Twitch25TurboUpsellViewController");
  if (!purchase) return NO;
  for (UIResponder *r = v.nextResponder; r; r = r.nextResponder)
    if ([r isKindOfClass:purchase]) return YES;
  return NO;
}

static BOOL twab_strContains(NSString *s, NSString *needle) {
  return s && [s rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Best-effort visible text of a view across UIKit/SwiftUI: label text, button
// title, or accessibility label (custom/Swift controls expose their visible
// text via accessibilityLabel even though they draw it rather than using a
// UILabel — this is how we match the "Go Ad-Free" pill).
static NSString *twab_viewText(UIView *v) {
  if ([v isKindOfClass:[UILabel class]] && [(UILabel *)v text].length)
    return [(UILabel *)v text];
  if ([v isKindOfClass:[UIButton class]]) {
    UIButton *b = (UIButton *)v;
    if (b.currentTitle.length) return b.currentTitle;
    if (b.currentAttributedTitle.string.length) return b.currentAttributedTitle.string;
  }
  if (v.accessibilityLabel.length) return v.accessibilityLabel;
  return nil;
}

static BOOL twab_isAdFreeText(NSString *txt) {
  return twab_strContains(txt, @"Ad-Free") || twab_strContains(txt, @"Ad Free");
}

// Hide + zero-size the matched control, once per instance (associated-object
// guard so we don't re-add constraints every layout, which would loop).
static void twab_killAdFreeButton(UIView *v) {
  if (!v) return;
  static char doneKey;
  if (objc_getAssociatedObject(v, &doneKey)) return;
  if (twab_viewInPurchaseScreen(v)) return;
  objc_setAssociatedObject(v, &doneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  v.hidden = YES;
  v.translatesAutoresizingMaskIntoConstraints = NO;  // hidden, so frame loss is fine
  NSLayoutConstraint *w = [v.widthAnchor constraintEqualToConstant:0];
  NSLayoutConstraint *h = [v.heightAnchor constraintEqualToConstant:0];
  w.priority = h.priority = (UILayoutPriority)999;
  w.active = h.active = YES;
}

// Backup window scan: hide any Upsell/AdFree-classed or "Ad-Free"-titled view.
static void twab_scanForAdFree(UIView *root) {
  if (!root) return;
  NSString *cls = NSStringFromClass([root class]);
  if ((twab_strContains(cls, @"Upsell") || twab_strContains(cls, @"AdFree") ||
       twab_isAdFreeText(twab_viewText(root))) && !root.hidden) {
    twab_killAdFreeButton(root);
    return;  // handled; don't descend
  }
  for (UIView *sub in [root.subviews copy]) twab_scanForAdFree(sub);
}

static void twab_handleAdFree(void) {
  if (![tweakDefaults boolForKey:TWABKeyHideAdFreeButton]) return;
  for (UIWindow *w in [UIApplication.sharedApplication.windows copy])
    twab_scanForAdFree(w);
}

// Catch the "Go Ad-Free" pill the instant it lays out — no touch/scroll needed.
%hook _TtC12TwitchCoreUI14StandardButton
- (void)didMoveToWindow {
  %orig;
  if (![tweakDefaults boolForKey:TWABKeyHideAdFreeButton]) return;
  UIView *btn = (UIView *)self;
  if (twab_isAdFreeText(twab_viewText(btn))) twab_killAdFreeButton(btn);
}
- (void)layoutSubviews {
  %orig;
  if (![tweakDefaults boolForKey:TWABKeyHideAdFreeButton]) return;
  UIView *btn = (UIView *)self;
  if (twab_isAdFreeText(twab_viewText(btn))) twab_killAdFreeButton(btn);
}
%end

%hook _TtC6Twitch23FollowingViewController
- (void)viewDidLayoutSubviews {
  %orig;
  twab_handleAdFree();
  // Backstop for the init hooks above: Twitch renames FollowingViewController's
  // initializer every few versions (31.x dropped the GraphQL argument), and a
  // missed rename would silently re-enable the display ads. Clear once per
  // instance on first layout too.
  static char clearedKey;
  if ([tweakDefaults boolForKey:TWABKeyAdBlockEnabled] &&
      !objc_getAssociatedObject(self, &clearedKey)) {
    objc_setAssociatedObject(self, &clearedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    twab_clearFollowingAds(self);
  }
}
%end


// Diagnostics registry. Records whether each hooked Twitch/TwitchKit/Apollo
// class resolved in the running binary so the settings "Diagnostics" screen
// can show what's wired vs. what Twitch renamed. Twitch renames Swift classes
// between versions and Logos silently skips %hook blocks whose target class is
// absent; without this, a broken feature gives no signal. Apple-private
// classes (__NSURLSession*) are not tracked — they legitimately vary across
// iOS versions. Populated once in %ctor; read by twab_classDiagnostics().
static NSMutableArray<NSDictionary *> *twab_diagStore(void) {
  static NSMutableArray *a;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ a = [NSMutableArray array]; });
  return a;
}

// Public accessor for the settings UI. Returns a copy of
// [{ @"name": NSString, @"present": @(BOOL) }, ...] in registration order.
NSArray<NSDictionary *> *twab_classDiagnostics(void) {
  return [twab_diagStore() copy];
}

// Record a class's presence (and warn to the log if missing). Replaces the
// old twab_warnIfClassMissing — same logging, plus it feeds the registry.
static void twab_checkClass(const char *name) {
  BOOL present = objc_getClass(name) != nil;
  [twab_diagStore() addObject:@{ @"name": @(name), @"present": @(present) }];
  if (!present) {
    os_log_error(OS_LOG_DEFAULT,
        "[TWAB] missing hook target: %{public}s (Twitch likely renamed it)",
        name);
  }
}


%ctor {
  rebind_symbols(
      (struct rebinding[]){
          {"swift_unknownObjectWeakAssign", (void *)hook_swift_unknownObjectWeakAssign,
           (void **)&orig_swift_unknownObjectWeakAssign},
          {"swift_unknownObjectWeakLoadStrong", (void *)hook_swift_unknownObjectWeakLoadStrong,
           (void **)&orig_swift_unknownObjectWeakLoadStrong},
      },
      2);
  tweakBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"TwitchAdBlock"
                                                                       ofType:@"bundle"]];
  if (!tweakBundle)
    tweakBundle = [NSBundle
        bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/TwitchAdBlock.bundle")];
  tweakDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.level3tjg.twitchadblock"];
  if (![tweakDefaults objectForKey:TWABKeyAdBlockEnabled])
    [tweakDefaults setBool:YES forKey:TWABKeyAdBlockEnabled];
  if (![tweakDefaults objectForKey:TWABKeyAdBlockProxyEnabled])
    [tweakDefaults setBool:YES forKey:TWABKeyAdBlockProxyEnabled];
  if (![tweakDefaults objectForKey:TWABKeyAdBlockCustomProxyEnabled])
    [tweakDefaults setBool:NO forKey:TWABKeyAdBlockCustomProxyEnabled];
  if (![tweakDefaults objectForKey:TWABKeyDisableWatchLimit])
    [tweakDefaults setBool:YES forKey:TWABKeyDisableWatchLimit];
  if (![tweakDefaults objectForKey:TWABKeyHideAdFreeButton])
    [tweakDefaults setBool:YES forKey:TWABKeyHideAdFreeButton];
  // Emote default lives here (not in Emotes.x's %ctor) because Logos
  // doesn't guarantee inter-file %ctor ordering — Emotes.x's %ctor
  // could run before Tweak.x's, when `tweakDefaults` is still nil, and
  // `[nil setBool:forKey:]` is a silent no-op. Setting it here, AFTER
  // tweakDefaults is allocated, is the only safe place.
  if (![tweakDefaults objectForKey:TWABKeyEmotesEnabled])
    [tweakDefaults setBool:YES forKey:TWABKeyEmotesEnabled];
  // One-shot migration: force emotes on for users on installs from
  // earlier builds where the ctor-ordering bug left the key absent and
  // boolForKey: returned NO, looking like an explicit user disable.
  // Runs once per device; user can toggle off afterwards and it sticks.
  static NSString *const kEmotesMigrationKey = @"TWABMigrated_emotesDefault_v1";
  if (![tweakDefaults boolForKey:kEmotesMigrationKey]) {
    [tweakDefaults setBool:YES forKey:TWABKeyEmotesEnabled];
    [tweakDefaults setBool:YES forKey:kEmotesMigrationKey];
  }
  assetResourceLoaderDelegate = [[TWAdBlockAssetResourceLoaderDelegate alloc] init];

  // Surface silently-skipped %hook blocks into the diagnostics registry.
  twab_checkClass("_TtC6Twitch25AccountMenuViewController");
  twab_checkClass("_TtC6Twitch23FollowingViewController");
  twab_checkClass("_TtC6Twitch27HeadlinerFollowingAdManager");
  twab_checkClass("TWAppUpdatePrompt");
  twab_checkClass("_TtC6Twitch16TabBarController");
  twab_checkClass("_TtC6Twitch20BrowseViewController");
  twab_checkClass("_TtC6Twitch30DiscoveryFeedTabViewController");
  twab_checkClass("_TtC6Twitch41DiscoveryFeedShelfContainerViewController");
  // Evolve "Live" feed VC — not hooked today, but its presence confirms the
  // feed whose max-watchtime limit we neutralize and where feed display ads
  // live (candidate ivar for a future block: adStateManager).
  twab_checkClass("_TtC6Twitch24EvolveFeedViewController");
  // Chat input bar + Twitch's emote button — the 3rd-party emote picker
  // button (EmotePicker.x) is inserted beside the latter.
  twab_checkClass("_TtC6Twitch13ChatInputView");
  twab_checkClass("_TtC6Twitch27ChatInputViewEmoticonButton");
  // Either of the two URLSession client classes is enough — Twitch ships one
  // or the other per version. Record as a single combined entry.
  // React Native feed prefetch bridge (31.x) — see twab_hookFeedPreload.
  twab_hookFeedPreload();
  BOOL urlClientPresent = objc_getClass("_TtC9TwitchKit18TKURLSessionClient") ||
                          objc_getClass("_TtC6Apollo16URLSessionClient");
  [twab_diagStore() addObject:@{ @"name": @"URLSessionClient (TK or Apollo)",
                                 @"present": @(urlClientPresent) }];
  if (!urlClientPresent) {
    os_log_error(OS_LOG_DEFAULT,
        "[TWAB] missing hook target: neither TKURLSessionClient nor Apollo.URLSessionClient");
  }
}
