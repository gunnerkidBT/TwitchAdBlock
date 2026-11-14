#import <dlfcn.h>
#import <os/log.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import "Tweak.h"
#import "SettingsKeys.h"
#import "ChannelPoints.h"

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

// ─── Ad detection logging ───────────────────────────────────────────────────
// Scans m3u8 variant playlist response data for Twitch SSAI ad markers and
// logs when ads are detected. Lightweight — only runs on playlist-host
// responses whose URL ends in .m3u8. Non-static so the proxy delegate can
// call it too.
static _Atomic uint64_t twab_adDetectCount;
static _Atomic double twab_lastAdLogTime;

void twab_checkPlaylistForAds(NSData *data, NSURLRequest *request) {
  if (!data.length || !request) return;
  NSString *host = request.URL.host;
  if (!host || !twab_isPlaylistHost(host)) return;
  NSString *path = request.URL.path;
  if (!path || ![path hasSuffix:@".m3u8"]) return;
  NSRange range = NSMakeRange(0, MIN(data.length, 8192));
  NSString *text = [[NSString alloc] initWithData:[data subdataWithRange:range]
                                         encoding:NSUTF8StringEncoding];
  if (!text) return;
  BOOL hasAd = [text containsString:@"stitched-ad"] ||
               [text containsString:@"SCTE35-OUT"] ||
               [text containsString:@"X-TV-TWITCH-AD"] ||
               [text containsString:@"CLASS=\"twitch-ad"] ||
               [text containsString:@"video-weaver"];
  if (!hasAd) return;
  uint64_t count = atomic_fetch_add(&twab_adDetectCount, 1) + 1;
  double now = CFAbsoluteTimeGetCurrent();
  double last = atomic_exchange(&twab_lastAdLogTime, now);
  if (now - last < 5.0 && count > 1) return;
  os_log(OS_LOG_DEFAULT,
    "[TWAB-AD-DETECT] ad content in playlist #%llu host=%{public}@ path=%{public}@",
    count, host, path);
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

// ─── Wide 3rd-party emotes ──────────────────────────────────────────────────
// Twitch draws every chat emote into a fixed square box (React Native's
// EMOTE_SIZE; the native Swift chat does the same), stretching wide 7TV/BTTV/
// FFZ emotes into squished squares. We can't widen the box, but we control the
// image: wide (or tall) emotes are redrawn centred on a transparent square, so
// the square box shows them at their true proportions — smaller, not
// distorted. Animated GIFs are padded frame-by-frame, keeping their timing.
static BOOL twab_isEmoteImageRequest(NSURLRequest *req) {
  NSString *host = req.URL.host;
  return [host isEqualToString:@"cdn.7tv.app"] || [host isEqualToString:@"cdn.betterttv.net"] ||
         [host isEqualToString:@"cdn.frankerfacez.com"];
}

// Returns the padded image, or nil to keep the original (already ~square,
// not an image, or anything failed).
static NSData *twab_padEmoteToSquare(NSData *data) {
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (!src) return nil;
  size_t count = CGImageSourceGetCount(src);
  CGImageRef first = count ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
  if (!first) { CFRelease(src); return nil; }
  size_t w = CGImageGetWidth(first), h = CGImageGetHeight(first);
  CGImageRelease(first);
  // Within ~10% of square already looks fine stretched.
  if (!w || !h || (w * 10 <= h * 11 && h * 10 <= w * 11)) { CFRelease(src); return nil; }
  size_t side = MAX(w, h);
  BOOL animated = count > 1;
  NSMutableData *out = [NSMutableData data];
  CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
      animated ? CFSTR("com.compuserve.gif") : CFSTR("public.png"), count, NULL);
  if (!dst) { CFRelease(src); return nil; }
  if (animated) {
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyProperties(src, NULL));
    NSNumber *loops = props[(id)kCGImagePropertyGIFDictionary][(id)kCGImagePropertyGIFLoopCount] ?: @0;
    CGImageDestinationSetProperties(dst, (__bridge CFDictionaryRef)@{
      (id)kCGImagePropertyGIFDictionary: @{ (id)kCGImagePropertyGIFLoopCount: loops } });
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  for (size_t i = 0; i < count; i++) {
    CGImageRef frame = CGImageSourceCreateImageAtIndex(src, i, NULL);
    if (!frame) continue;
    CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, 0, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (ctx) {
      size_t fw = CGImageGetWidth(frame), fh = CGImageGetHeight(frame);
      CGContextDrawImage(ctx, CGRectMake((side - fw) / 2.0, (side - fh) / 2.0, fw, fh), frame);
      CGImageRef padded = CGBitmapContextCreateImage(ctx);
      NSDictionary *frameProps = nil;
      if (animated) {
        NSDictionary *fp = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
        NSDictionary *gif = fp[(id)kCGImagePropertyGIFDictionary];
        NSNumber *delay = gif[(id)kCGImagePropertyGIFUnclampedDelayTime] ?:
                          gif[(id)kCGImagePropertyGIFDelayTime] ?: @0.1;
        frameProps = @{ (id)kCGImagePropertyGIFDictionary: @{ (id)kCGImagePropertyGIFDelayTime: delay } };
      }
      if (padded) {
        CGImageDestinationAddImage(dst, padded, (__bridge CFDictionaryRef)frameProps);
        CGImageRelease(padded);
      }
      CGContextRelease(ctx);
    }
    CGImageRelease(frame);
  }
  CGColorSpaceRelease(cs);
  BOOL ok = CGImageDestinationFinalize(dst);
  CFRelease(dst);
  CFRelease(src);
  if (!ok || !out.length) return nil;
  os_log(OS_LOG_DEFAULT, "[TWAB-Emote] padded %zux%zu%{public}s emote to %zux%zu", w, h,
         animated ? " animated" : "", side, side);
  return out;
}

// Twitch's chat fetches the same emote image several times in a row; cache
// the result per URL (padded bytes, or NSNull = "leave as is"). NSCache is
// thread-safe, so lookups happen on the network queue and fills off it.
static NSCache *twab_emoteFitCache(void) {
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 400; });
  return cache;
}

// Cached result for `url`, or nil if not computed yet.
static NSData *twab_cachedFitEmote(NSURL *url, NSData *data) {
  id hit = url ? [twab_emoteFitCache() objectForKey:url] : nil;
  if (!hit) return nil;
  return hit == (id)kCFNull ? data : hit;
}

static NSData *twab_fitEmoteImage(NSURL *url, NSData *data) {
  NSData *cached = twab_cachedFitEmote(url, data);
  if (cached) return cached;
  NSData *padded = twab_padEmoteToSquare(data);
  if (url) [twab_emoteFitCache() setObject:padded ?: (id)kCFNull forKey:url];
  return padded ?: data;
}

// Delegate path: emote images arrive in chunks; hold them until the task
// completes, then deliver the (padded) whole image in one go.
static char twab_emoteBufferKey, twab_emoteFlushingKey, twab_emoteStartKey, twab_wholeResponseHeldKey;

// Hide Leaderboard: this response can arrive in several chunks, which can't be
// edited one at a time, so it's held like an emote image and edited whole at completion.
static BOOL twab_requestNamesOperation(NSURLRequest *request, NSString *operation) {
  if (![request.URL.host isEqualToString:@"gql.twitch.tv"] || !request.HTTPBody) return NO;
  NSString *quoted = [NSString stringWithFormat:@"\"%@\"", operation];
  NSData *needle = [quoted dataUsingEncoding:NSUTF8StringEncoding];
  return [request.HTTPBody rangeOfData:needle options:0 range:NSMakeRange(0, request.HTTPBody.length)].location != NSNotFound;
}

static NSData *twab_bufferEmoteChunk(NSData *data, NSURLSessionDataTask *task) {
  NSMutableData *buf = objc_getAssociatedObject(task, &twab_emoteBufferKey);
  if (!buf) {
    buf = [NSMutableData data];
    objc_setAssociatedObject(task, &twab_emoteBufferKey, buf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(task, &twab_emoteStartKey, @(CFAbsoluteTimeGetCurrent()),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  [buf appendData:data];
  return [NSData data];
}

static void twab_deliverEmote(id delegate, NSURLSession *session, NSURLSessionTask *task, NSData *out) {
  if (!out.length) return;
  objc_setAssociatedObject(task, &twab_emoteFlushingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  ((void (*)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *))objc_msgSend)(
      delegate, @selector(URLSession:dataTask:didReceiveData:), session, (NSURLSessionDataTask *)task, out);
  objc_setAssociatedObject(task, &twab_emoteFlushingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Called from didCompleteWithError:. Returns NO if nothing was held (caller
// completes normally). Otherwise the held image is delivered and then
// `complete` (the original didCompleteWithError:) runs:
//  - cached / nothing to do → right now, on this queue;
//  - needs padding → padded on a background queue, then delivered + completed
//    on the session's delegate queue. Padding an animated GIF takes a moment;
//    doing it inline used to stall the delegate queue — and with it every
//    other image in a fast chat.
static BOOL twab_completeHeldEmote(id delegate, NSURLSession *session, NSURLSessionTask *task,
                                   void (^complete)(void)) {
  NSMutableData *buf = objc_getAssociatedObject(task, &twab_emoteBufferKey);
  if (!buf || ![task isKindOfClass:NSURLSessionDataTask.class]) return NO;
  objc_setAssociatedObject(task, &twab_emoteBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (objc_getAssociatedObject(task, &twab_wholeResponseHeldKey)) {
    NSData *edited = [buf twab_dataHidingLeaderboardsForRequest:task.originalRequest];
    edited = twab_rewriteWatchLimitBytes(edited, task.currentRequest, NSStringFromClass([delegate class]));
    edited = [edited twab_responseDataForRequest:task.currentRequest hideTurboOffers:YES];
    twab_deliverEmote(delegate, session, task, edited);
    complete();
    return YES;
  }
  NSURL *url = task.originalRequest.URL;
  CFAbsoluteTime start = [objc_getAssociatedObject(task, &twab_emoteStartKey) doubleValue];
  NSData *cached = buf.length ? twab_cachedFitEmote(url, buf) : buf;
  if (cached) {
    twab_deliverEmote(delegate, session, task, cached);
    complete();
    return YES;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    CFAbsoluteTime padStart = CFAbsoluteTimeGetCurrent();
    NSData *out = twab_fitEmoteImage(url, buf);
    CFAbsoluteTime padMs = (CFAbsoluteTimeGetCurrent() - padStart) * 1000;
    void (^finish)(void) = ^{
      twab_deliverEmote(delegate, session, task, out);
      complete();
      CFAbsoluteTime totalMs = start ? (CFAbsoluteTimeGetCurrent() - start) * 1000 : 0;
      if (totalMs > 250)
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] slow emote: %.0f ms from first byte to delivery (padding %.0f ms) %{public}@",
               totalMs, padMs, url.lastPathComponent ?: @"");
    };
    NSOperationQueue *q = session.delegateQueue;
    if (q) [q addOperationWithBlock:finish];
    else finish();
  });
  return YES;
}

static NSData *twab_filteredFeedData(id delegate, NSData *data, NSURLSessionDataTask *dataTask) {
  twab_checkPlaylistForAds(data, dataTask.currentRequest);
  twab_pointsCheckResponse(data, dataTask.currentRequest);
  // Wide emotes: hold 7TV/BTTV/FFZ image chunks for padding at completion
  // (only for delegates that tell us about completion, or nothing would flush).
  if (!objc_getAssociatedObject(dataTask, &twab_emoteFlushingKey) &&
      [tweakDefaults boolForKey:TWABKeyEmotesEnabled] &&
      [tweakDefaults boolForKey:TWABKeyFitWideEmotes] &&
      twab_isEmoteImageRequest(dataTask.originalRequest) &&
      [delegate respondsToSelector:@selector(URLSession:task:didCompleteWithError:)])
    return twab_bufferEmoteChunk(data, dataTask);
  if (objc_getAssociatedObject(dataTask, &twab_emoteFlushingKey)) return data;
  if ([delegate isKindOfClass:objc_getClass("RCTHTTPRequestHandler")] &&
      [tweakDefaults boolForKey:TWABKeyHideLeaderboard] &&
      twab_requestNamesOperation(dataTask.originalRequest, @"ChannelLeaderboards")) {
    objc_setAssociatedObject(dataTask, &twab_wholeResponseHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return twab_bufferEmoteChunk(data, dataTask);
  }
  data = twab_rewriteWatchLimitBytes(data, dataTask.currentRequest, NSStringFromClass([delegate class]));
  // Ad-block (ad strip, watch limit) and Hide Stories (empties the Stories
  // shelf response) both filter here; each is gated inside on its own toggle.
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled] &&
      ![tweakDefaults boolForKey:TWABKeyHideStories] &&
      ![tweakDefaults boolForKey:TWABKeyHideAdFreeButton]) return data;
  return [data twab_responseDataForRequest:dataTask.currentRequest
                           hideTurboOffers:[delegate isKindOfClass:objc_getClass("RCTHTTPRequestHandler")]];
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
      if (resolve && [tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) {
        wrapped = ^(id result) {
          // This page skips the network hooks, so feed ads are removed here too. Left
          // in, one stayed as a tall empty slot under the first channel.
          id clean = twab_stripPreloadFeedAds(result, 0);
          if (![tweakDefaults boolForKey:TWABKeyDisableWatchLimit]) {
            resolve(clean);
            return;
          }
          NSUInteger before = twab_preloadLimitsNulled;
          id out = twab_nullWatchLimits(clean, 0);
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
    if (data && [tweakDefaults boolForKey:TWABKeyEmotesEnabled] &&
        [tweakDefaults boolForKey:TWABKeyFitWideEmotes] && twab_isEmoteImageRequest(request)) {
      // Wide 3rd-party emotes. Cached → now; otherwise pad off this queue
      // and call back on it, so padding never stalls other responses.
      NSData *cached = twab_cachedFitEmote(request.URL, data);
      if (cached) { handler(cached, response, error); return; }
      NSOperationQueue *back = NSOperationQueue.currentQueue;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *out = twab_fitEmoteImage(request.URL, data);
        if (back) [back addOperationWithBlock:^{ handler(out, response, error); }];
        else handler(out, response, error);
      });
      return;
    }
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
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  // Held wide-emote image: delivered (padded) first, then completion.
  if (twab_completeHeldEmote(self, session, task, ^{ %orig; })) return;
  %orig;
}
%end

// Apollo.URLSessionClient — used in Twitch 29.x+
%hook _TtC6Apollo16URLSessionClient
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  %orig(session, dataTask, twab_filteredFeedData(self, data, dataTask));
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  // Held wide-emote image: delivered (padded) first, then completion.
  if (twab_completeHeldEmote(self, session, task, ^{ %orig; })) return;
  %orig;
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
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  // Held wide-emote image: delivered (padded) first, then completion.
  if (twab_completeHeldEmote(self, session, task, ^{ %orig; })) return;
  %orig;
}
%end

// Declutter: stream-screen buttons, matched by their React Native testID. Twitch
// reuses these views for other elements, so one we hid is restored on reuse.
static char twab_declutterHiddenKey;

static BOOL twab_shouldHideTestID(NSString *testID) {
  if ([testID isEqualToString:@"subscribe-button"] || [testID isEqualToString:@"gift-button"])
    return [tweakDefaults boolForKey:TWABKeyHideSubscribe];
  if ([testID isEqualToString:@"chat-tray-button-bits"])
    return [tweakDefaults boolForKey:TWABKeyHideBits];
  if ([testID isEqualToString:@"channel-leaderboard-strip-pressable"])
    return [tweakDefaults boolForKey:TWABKeyHideLeaderboard];
  if ([testID isEqualToString:@"feed-recaps-shelf-absorb"])
    return [tweakDefaults boolForKey:TWABKeyHideRecapsBar];
  if ([testID isEqualToString:@"extensions-icon"])
    return [tweakDefaults boolForKey:TWABKeyHideExtensions];
  if ([testID isEqualToString:@"stage-inflow-metadata"])
    return [tweakDefaults boolForKey:TWABKeyHideChannelBar];
  return NO;
}

// Hide Channel Bar: React Native keeps the bar's space. Resizing chat fights its
// layout and leaves touches outside the parent, so the message list stays where
// it is and is allowed to draw upward into that space: rows above its top edge
// are already mounted. A mask stops them at the video, and any banner above chat
// moves up with it. The bar's height animates, so the banner tracks what was
// applied and only adds the difference.
static char twab_barShiftKey, twab_barCenterKey, twab_touchExtensionKey, twab_touchCutoffKey;

static BOOL twab_isPanelOnlyTestID(NSString *testID) {
  return [testID isEqualToString:@"channel-metadata"] ||
         [testID isEqualToString:@"follow-button"] ||
         [testID isEqualToString:@"gift-button"] ||
         [testID isEqualToString:@"subscribe-button"] ||
         [testID isEqualToString:@"extensions-icon"] ||
         [testID hasPrefix:@"support-action-row-"] ||
         [testID isEqualToString:@"channel-metadata-persistent-row"] ||
         [testID isEqualToString:@"channel-metadata-actions"] ||
         [testID hasPrefix:@"support-action-cell-"];
}

static UIView *twab_findTestID(UIView *root, NSString *testID, NSUInteger depth) {
  if ([root.accessibilityIdentifier isEqualToString:testID]) return root;
  if (depth == 0) return nil;
  for (UIView *sub in root.subviews) {
    UIView *found = twab_findTestID(sub, testID, depth - 1);
    if (found) return found;
  }
  return nil;
}

static void twab_collectTestID(UIView *root, NSString *testID, NSUInteger depth, NSMutableArray *found) {
  if ([root.accessibilityIdentifier isEqualToString:testID]) [found addObject:root];
  if (depth == 0) return;
  for (UIView *sub in root.subviews) twab_collectTestID(sub, testID, depth - 1, found);
}

// Moves a view that sits above chat (banner, pinned card) up by `shift`, adding
// only the difference from what's already applied.
static void twab_moveAboveChat(UIView *view, CGFloat shift) {
  if (!view) return;
  NSValue *last = objc_getAssociatedObject(view, &twab_barCenterKey);
  BOOL untouched = last && CGPointEqualToPoint(last.CGPointValue, view.center);
  CGFloat applied = untouched ? [objc_getAssociatedObject(view, &twab_barShiftKey) doubleValue] : 0;
  CGFloat delta = shift - applied;
  if (delta == 0) return;
  CGPoint center = view.center;
  center.y -= delta;
  view.center = center;
  objc_setAssociatedObject(view, &twab_barShiftKey, @(shift), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(view, &twab_barCenterKey, [NSValue valueWithCGPoint:view.center],
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void twab_collapseChannelBar(UIView *changed) {
  UIView *layout = changed.superview;
  while (layout && ![layout.accessibilityIdentifier isEqualToString:@"theatre-portrait-layout"])
    layout = layout.superview;
  if (!layout) return;  // landscape has no bar to make room for
  UIView *bar = twab_findTestID(layout, @"stage-inflow-metadata", 8);
  UIView *region = twab_findTestID(layout, @"chat-message-region", 20);
  UIView *list = twab_findTestID(region, @"chat-message-list", 14);
  if (!bar || !region || !list) return;
  CGFloat height = bar.frame.size.height;

  // Tapping the video opens the channel info panel, the way to reach Follow and
  // the stream title with the bar gone. The panel's background and buttons are
  // siblings of it rather than children (confirmed on-device), so each one is
  // shown only while the panel is open. Closed, they'd cover chat.
  UIView *panel = twab_findTestID(layout, @"channel-metadata-collapsible", 20);
  BOOL panelOpen = panel.frame.size.height >= 1;
  for (UIView *sub in panel.superview.subviews) {
    NSString *subID = sub.accessibilityIdentifier;
    if (twab_isPanelOnlyTestID(subID)) sub.hidden = !panelOpen || twab_shouldHideTestID(subID);
  }
  // Buttons can sit in unnamed parents (Follow moves into one when the panel closes),
  // so they're also set directly. Each one's own switch still applies while open.
  for (NSString *button in @[@"follow-button", @"gift-button", @"subscribe-button", @"extensions-icon"]) {
    twab_findTestID(layout, button, 20).hidden = !panelOpen || twab_shouldHideTestID(button);
  }

  for (UIView *v = list; v && v != layout; v = v.superview) v.clipsToBounds = NO;
  for (UIView *sub in list.subviews) {
    if (![sub isKindOfClass:UIScrollView.class]) continue;
    sub.clipsToBounds = NO;
    objc_setAssociatedObject(sub, &twab_touchExtensionKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  CALayer *mask = region.layer.mask;
  if (!mask) {
    mask = [CALayer layer];
    mask.backgroundColor = UIColor.whiteColor.CGColor;
    region.layer.mask = mask;
    os_log(OS_LOG_DEFAULT, "[TWAB-Hide] chat drawing into channel bar space, bar height %.0f", height);
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  mask.frame = CGRectMake(0, -height, region.bounds.size.width, region.bounds.size.height + height);
  [CATransaction commit];

  // Pinned messages and offers live in chat-top-of-chat. With the panel open they
  // stay in Twitch's own spot, below it, instead of sliding behind it.
  CGFloat shift = panelOpen ? 0 : height;
  NSMutableArray *banners = [NSMutableArray array];
  twab_collectTestID(layout, @"chat-top-banner-carousel", 20, banners);
  UIView *pinned = twab_findTestID(layout, @"chat-top-of-chat", 20);
  // The visible strip is in a scroller beside the view named chat-top-banner-carousel,
  // so it's their shared, same-sized parent that has to move (confirmed on-device).
  NSMutableArray *moved = [NSMutableArray arrayWithObject:list];
  for (UIView *banner in banners) {
    UIView *parent = banner.superview;
    BOOL sameSize = fabs(parent.bounds.size.height - banner.bounds.size.height) < 1;
    UIView *box = sameSize && parent != layout ? parent : banner;
    twab_moveAboveChat(box, shift);
    [moved addObject:box];
  }
  twab_moveAboveChat(pinned, shift);

  // The unnamed view holding the video and bar still spans the bar's space and
  // swallowed taps there (confirmed on-device), so while the panel is closed it
  // only takes touches on the video.
  UIView *stage = bar;
  while (stage.superview && stage.superview != layout) stage = stage.superview;
  UIView *video = twab_findTestID(layout, @"theatre-video-zoom", 8);
  NSNumber *cutoff = nil;
  if (!panelOpen && video && [video isDescendantOfView:stage])
    cutoff = @(CGRectGetMaxY([video convertRect:video.bounds toView:stage]));
  objc_setAssociatedObject(stage, &twab_touchCutoffKey, cutoff, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  // React Native drops touches outside a parent unless its own layout says a child
  // overflows, so every parent of what moved takes touches that far up too.
  objc_setAssociatedObject(list, &twab_touchExtensionKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (pinned) [moved addObject:pinned];
  for (UIView *m in moved) {
    for (UIView *v = m.superview; v && v != layout; v = v.superview)
      objc_setAssociatedObject(v, &twab_touchExtensionKey, @(height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

static BOOL twab_pointInExtendedTop(UIView *view, CGPoint point) {
  CGFloat extra = [objc_getAssociatedObject(view, &twab_touchExtensionKey) doubleValue];
  if (extra <= 0) return NO;
  CGRect bounds = view.bounds;
  bounds.origin.y -= extra;
  bounds.size.height += extra;
  return CGRectContainsPoint(bounds, point);
}

static void twab_restoreDecluttered(UIView *view) {
  if (!objc_getAssociatedObject(view, &twab_declutterHiddenKey)) return;
  objc_setAssociatedObject(view, &twab_declutterHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  view.hidden = NO;
}

// Hide "From Channels You Follow": emptying the bar's data left the Live feed on
// one channel until it was scrolled, so the data stays and the bar is hidden. Its
// space is scrolled past and made unreachable with a negative top inset. Rows stay
// where React Native put them, so Twitch's scroll position matches the screen and
// autoplay starts in the right place.
static char twab_feedTopKey;

static void twab_shiftFeedRows(UIView *shelf, CGFloat height) {
  UIView *list = shelf.superview;
  while (list && ![list.accessibilityIdentifier isEqualToString:@"feed-list"]) list = list.superview;
  for (UIView *sub in list.subviews) {
    if (![sub isKindOfClass:UIScrollView.class]) continue;
    UIScrollView *scroll = (UIScrollView *)sub;
    objc_setAssociatedObject(scroll, &twab_feedTopKey, height > 0 ? @(height) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIEdgeInsets inset = scroll.contentInset;
    if (inset.top == -height) return;
    inset.top = -height;
    scroll.contentInset = inset;
    if (scroll.contentOffset.y < height) scroll.contentOffset = CGPointMake(scroll.contentOffset.x, height);
    os_log(OS_LOG_DEFAULT, "[TWAB-Shelf] scrolled Live feed past bar space, %.0f", height);
    return;
  }
}

%hook RCTViewComponentView
- (void)setAccessibilityIdentifier:(NSString *)identifier {
  %orig;
  UIView *view = (UIView *)self;
  // New buttons and banners aren't attached yet, so they're checked once they are.
  if ((twab_isPanelOnlyTestID(identifier) || [identifier isEqualToString:@"chat-top-banner-carousel"] ||
       [identifier isEqualToString:@"chat-top-of-chat"]) &&
      [tweakDefaults boolForKey:TWABKeyHideChannelBar]) {
    __weak UIView *weakNew = view;
    dispatch_async(dispatch_get_main_queue(), ^{ twab_collapseChannelBar(weakNew); });
  }
  if (twab_shouldHideTestID(identifier)) {
    objc_setAssociatedObject(view, &twab_declutterHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.hidden = YES;
    os_log(OS_LOG_DEFAULT, "[TWAB-Hide] hid %{public}@", identifier);
  } else {
    twab_restoreDecluttered(view);
  }
}
- (void)updateLayoutMetrics:(const void *)layoutMetrics oldLayoutMetrics:(const void *)oldLayoutMetrics {
  %orig;
  UIView *view = (UIView *)self;
  // Layout can reset `hidden` from React Native's own display value.
  if (objc_getAssociatedObject(view, &twab_declutterHiddenKey)) view.hidden = YES;
  NSString *testID = view.accessibilityIdentifier;
  if ([testID isEqualToString:@"feed-recaps-shelf-absorb"] && [tweakDefaults boolForKey:TWABKeyHideRecapsBar]) {
    __weak UIView *weakShelf = view;
    dispatch_async(dispatch_get_main_queue(), ^{
      UIView *shelf = weakShelf;
      if (shelf) twab_shiftFeedRows(shelf, shelf.bounds.size.height);
    });
  }
  if (([testID isEqualToString:@"stage-inflow-metadata"] ||
       [testID isEqualToString:@"chat-message-region"] ||
       [testID isEqualToString:@"channel-metadata-collapsible"] ||
       twab_isPanelOnlyTestID(testID) ||
       [testID isEqualToString:@"chat-top-of-chat"] ||
       [testID isEqualToString:@"chat-top-banner-carousel"]) &&
      [tweakDefaults boolForKey:TWABKeyHideChannelBar]) {
    twab_collapseChannelBar(view);
    __weak UIView *weakView = view;
    dispatch_async(dispatch_get_main_queue(), ^{ twab_collapseChannelBar(weakView); });
  }
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  NSNumber *cutoff = objc_getAssociatedObject(self, &twab_touchCutoffKey);
  if (cutoff && point.y >= cutoff.doubleValue) return NO;
  return %orig || twab_pointInExtendedTop((UIView *)self, point);
}
- (void)prepareForRecycle {
  twab_restoreDecluttered((UIView *)self);
  objc_setAssociatedObject(self, &twab_touchCutoffKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self, &twab_touchExtensionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self, &twab_barShiftKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self, &twab_barCenterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  NSString *recycledID = ((UIView *)self).accessibilityIdentifier;
  if ([recycledID isEqualToString:@"feed-recaps-shelf-absorb"]) twab_shiftFeedRows((UIView *)self, 0);
  if ([recycledID isEqualToString:@"chat-message-region"]) ((UIView *)self).layer.mask = nil;
  if (twab_isPanelOnlyTestID(recycledID)) ((UIView *)self).hidden = NO;
  %orig;
}
%end

%hook RCTEnhancedScrollView
// Hide "From Channels You Follow": Twitch scrolling the feed to its top (e.g. on a new
// category) stops below the bar's space. Finger drags and bounces are left alone.
- (void)setContentOffset:(CGPoint)offset {
  UIScrollView *scroll = (UIScrollView *)self;
  CGFloat top = [objc_getAssociatedObject(self, &twab_feedTopKey) doubleValue];
  if (top > 0 && offset.y < top && !scroll.tracking && !scroll.dragging && !scroll.decelerating) offset.y = top;
  %orig(offset);
}
// Hide Channel Bar: drags in the space above the message list still scroll it.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  return %orig || twab_pointInExtendedTop((UIView *)self, point);
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
// Declutter → Hide "+" (Create): position the Create tab had before we removed
// it (-1 = not removed). Saved launch-tab positions are the original ones.
static NSInteger twab_removedTabIndex = -1;

static void twab_applyLaunchTab(UITabBarController *tbc, NSString *when) {
    if (twab_userPickedTab || ![tweakDefaults objectForKey:TWABKeyLaunchTab]) return;
    NSInteger idx = [tweakDefaults integerForKey:TWABKeyLaunchTab];
    if (twab_removedTabIndex >= 0) {
        if (idx == twab_removedTabIndex) return;  // the removed Create tab
        if (idx > twab_removedTabIndex) idx--;    // tabs after it shifted left
    }
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
// Declutter: drop the "+" (Create) tab — the view controller whose tab item is
// Twitch's CreateTabBarItem — whenever Twitch sets the tabs.
- (void)setViewControllers:(NSArray<UIViewController *> *)vcs animated:(BOOL)animated {
    if ([tweakDefaults boolForKey:TWABKeyHideCreateTab] && vcs.count) {
        Class createCls = objc_getClass("_TtC6Twitch16CreateTabBarItem");
        NSUInteger i = createCls ? [vcs indexOfObjectPassingTest:^BOOL(UIViewController *vc, NSUInteger n, BOOL *stop) {
            return [vc.tabBarItem isKindOfClass:createCls];
        }] : NSNotFound;
        if (i != NSNotFound) {
            twab_removedTabIndex = (NSInteger)i;
            NSMutableArray *kept = [vcs mutableCopy];
            [kept removeObjectAtIndex:i];
            os_log(OS_LOG_DEFAULT, "[TWAB-Declutter] removed Create tab (position %lu of %lu)",
                   (unsigned long)i, (unsigned long)vcs.count);
            vcs = kept;
        } else {
            NSMutableArray *items = [NSMutableArray array];
            for (UIViewController *vc in vcs) [items addObject:NSStringFromClass(vc.tabBarItem.class)];
            os_log(OS_LOG_DEFAULT, "[TWAB-Declutter] Create tab not found; tab items: %{public}@",
                   [items componentsJoinedByString:@", "]);
        }
    }
    %orig(vcs, animated);
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

// Home sub-tab override. selectViewControllerAtIndex: was a no-op, KVC
// throws on Swift-private ivars, and init runs before our hooks install.
// Use animated:YES so UIKit calls scrollViewDidEndScrollingAnimation: on
// the delegate, which properly transitions child VCs (theme + touch).
// Defined later in this file — scans all windows for the "Go Ad-Free" upsell.
static void twab_handleAdFree(void);

// Returns YES when the desired page is showing (or the user took over).
static BOOL twab_applyHomeSubTab(id self, NSString *when) {
    static BOOL userSwiped = NO;
    static BOOL scrollStarted = NO;
    if (userSwiped) return YES;
    if (![tweakDefaults objectForKey:TWABKeyLaunchSubTab]) return YES;
    if ([tweakDefaults integerForKey:TWABKeyLaunchTab] != 0) return YES;
    NSInteger sub = [tweakDefaults integerForKey:TWABKeyLaunchSubTab];
    if (sub < 0) return YES;
    if (scrollStarted) return YES;

    UIView *view = ((UIViewController *)self).view;
    UIScrollView *sv = twab_findPagedScrollView(view);
    if (!sv) return NO;
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

    scrollStarted = YES;
    [sv setContentOffset:CGPointMake(desired, 0) animated:YES];
    return YES;
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

// Button-like text only: a short label such as "Go Ad-Free". React Native
// containers often expose all of their children's text as one combined
// accessibilityLabel, so a long label that merely *contains* "Ad-Free" is a
// whole card (e.g. the profile page's Stream Manager / Analytics block) and
// must not match.
static BOOL twab_isAdFreeText(NSString *txt) {
  if (txt.length == 0 || txt.length > 32) return NO;
  return twab_strContains(txt, @"Ad-Free") || twab_strContains(txt, @"Ad Free");
}

// Only button-sized views are candidates — never cards or sections.
static BOOL twab_isButtonSized(UIView *v) {
  CGSize s = v.bounds.size;
  return s.height <= 80 && s.width <= 400;
}

// Hide + zero-size the matched control, once per instance (associated-object
// guard so we don't re-add constraints every layout, which would loop).
static void twab_killAdFreeButton(UIView *v) {
  if (!v || !v.superview) return;
  static char doneKey;
  // Inside a stack view (profile page, ProfileInfoView): marking it hidden made
  // the whole stack collapse and pinning its height clipped Stream Manager /
  // Analytics, so it's taken out of the stack's arrangement. It stays a subview: Twitch
  // re-activates constraints on it when the theme refreshes, and fully removing it
  // crashed on tab switches ("no common ancestor", confirmed by a crash log).
  // Checked before doneKey so that if Twitch re-adds it, it goes again. Deferred:
  // this runs during layout, where changing the hierarchy isn't safe.
  if ([v.superview isKindOfClass:UIStackView.class] && !twab_viewInPurchaseScreen(v)) {
    v.alpha = 0;
    if (![((UIStackView *)v.superview).arrangedSubviews containsObject:v]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      UIStackView *stack = (UIStackView *)v.superview;
      if (![stack isKindOfClass:UIStackView.class]) return;
      os_log(OS_LOG_DEFAULT, "[TWAB-AdFree] removed button from %{public}@ %{public}@ in %{public}@",
             NSStringFromClass(stack.class), NSStringFromCGRect(stack.frame),
             NSStringFromClass(stack.superview.class));
      [stack removeArrangedSubview:v];
      v.hidden = YES;
      // Without this the header above keeps its old height and clips the
      // Stream Manager / Analytics row (confirmed on-device).
      NSUInteger depth = 0;
      for (UIView *a = stack; a && depth < 8; a = a.superview, depth++) {
        [a invalidateIntrinsicContentSize];
        [a setNeedsLayout];
      }
    });
    return;
  }
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

// Backup window scan: hide button-sized Upsell/AdFree-classed or
// "Ad-Free"-titled views. (Unrestricted, this used to hide whole containers —
// e.g. the profile page's Stream Manager / Analytics card.)
static void twab_scanForAdFree(UIView *root) {
  if (!root) return;
  NSString *cls = NSStringFromClass([root class]);
  if ((twab_strContains(cls, @"Upsell") || twab_strContains(cls, @"AdFree") ||
       twab_isAdFreeText(twab_viewText(root))) && !root.hidden && twab_isButtonSized(root)) {
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
  // Ping proxies early so the first stream usually has a verdict to use.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled] || ![tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled]) return;
    for (NSString *address in twab_effectiveProxyAddresses()) {
      NSURL *proxyURL = twab_normalizedProxyURL(address);
      if (proxyURL) twab_proxyPingVerdict(proxyURL);
    }
  });
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
  if (![tweakDefaults objectForKey:TWABKeyFitWideEmotes])
    [tweakDefaults setBool:YES forKey:TWABKeyFitWideEmotes];
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
