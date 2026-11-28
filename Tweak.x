#import <dlfcn.h>
#import <os/log.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import "Tweak.h"
#import "SettingsKeys.h"
#import "ChannelPoints.h"
#import "TWABProxyPool.h"
#import "TWABRemoteProxies.h"

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

// Block Tracking: Twitch's usage analytics, crash/usage reporting SDKs, audience
// measurement and ad-verification (Open Measurement) hosts. Found in the 32.2
// app. Not blocked on purpose: branch.io (share links open the app through it),
// firebaseinstallations (push notifications), d3aqoihi2n8ty8.cloudfront.net
// (app images and animations).
BOOL twab_isTrackingHost(NSString *host) {
  if (!host.length) return NO;
  static NSSet *exact;
  static NSArray *suffixes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    exact = [NSSet setWithObjects:
      @"spade.twitch.tv",
      @"ddacn6pr5v0tl.cloudfront.net",           // Open Measurement scripts
      @"firebaselogging.googleapis.com",
      @"crashlyticsreports-pa.googleapis.com",
      @"firebase-settings.crashlytics.com",
      nil];
    suffixes = @[ @"scorecardresearch.com", @"imrworldwide.com", @"ingest.sentry.io",
                  @"ingest.us.sentry.io", @"moatads.com", @"adsafeprotected.com",
                  @"doubleverify.com" ];
  });
  if ([exact containsObject:host]) return YES;
  for (NSString *s in suffixes)
    if ([host isEqualToString:s] || [host hasSuffix:[@"." stringByAppendingString:s]]) return YES;
  return NO;
}

// The request rewritten so it fails at once (unsupported scheme), or nil when
// it isn't a tracking request or Block Tracking is off. Callers expect a task
// back, so tracking requests are failed rather than refused with nil.
NSURL *twab_trackingBlockedURL(NSURL *url) {
  if (!url.host || ![tweakDefaults boolForKey:TWABKeyBlockTracking] || !twab_isTrackingHost(url.host))
    return nil;
  // One summary line a minute (per host counts), so a retry loop would show.
  static NSCountedSet *counts;
  static CFAbsoluteTime windowStart;
  @synchronized (NSCountedSet.class) {
    if (!counts) counts = [NSCountedSet set];
    [counts addObject:url.host];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!windowStart) windowStart = now;
    if (now - windowStart >= 60) {
      NSMutableArray *parts = [NSMutableArray array];
      NSUInteger total = 0;
      for (NSString *h in counts) {
        [parts addObject:[NSString stringWithFormat:@"%@ %lu", h, (unsigned long)[counts countForObject:h]]];
        total += [counts countForObject:h];
      }
      os_log(OS_LOG_DEFAULT, "[TWAB-Track] blocked %lu requests in the last %.0fs: %{public}@",
             (unsigned long)total, now - windowStart, [parts componentsJoinedByString:@", "]);
      [counts removeAllObjects];
      windowStart = now;
    }
  }
  return [NSURL URLWithString:[@"twab-blocked://" stringByAppendingString:url.host]];
}

NSURLRequest *twab_trackingBlockedRequest(NSURLRequest *request) {
  NSURL *blocked = twab_trackingBlockedURL(request.URL);
  if (!blocked) return nil;
  NSMutableURLRequest *m = request.mutableCopy;
  m.URL = blocked;
  return m;
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

// Stream Rewind plays the stream's VOD: its master playlist comes from
// usher (/vod/), its quality playlists from the VOD CDN (CloudFront etc.),
// which the live check above never looked at. Every VOD playlist is scanned
// whole for ad markers; each one logs a line the first time and whenever its
// ad markers change, so it's clear whether rewinding brings ads.
static void twab_checkVodPlaylistForAds(NSData *data, NSURLRequest *request) {
  NSString *host = request.URL.host, *path = request.URL.path;
  if (!host || ![path hasSuffix:@".m3u8"]) return;
  // Quality playlists are recognised from the VOD master's own list of them.
  static NSMutableSet<NSString *> *vodPlaylistURLs;
  static dispatch_once_t setOnce;
  dispatch_once(&setOnce, ^{ vodPlaylistURLs = [NSMutableSet set]; });
  BOOL vodMaster = [host isEqualToString:@"usher.ttvnw.net"] && [path hasPrefix:@"/vod/"];
  NSString *bare = [host stringByAppendingString:path];
  BOOL vodMedia;
  @synchronized (vodPlaylistURLs) { vodMedia = [vodPlaylistURLs containsObject:bare]; }
  if (!vodMedia) vodMedia = [path containsString:@"index-dvr"] || [path containsString:@"index-muted"];
  if (!vodMaster && !vodMedia) return;
  if (data.length < 7) return;
  NSData *head = [data subdataWithRange:NSMakeRange(0, 7)];
  if (![head isEqualToData:[@"#EXTM3U" dataUsingEncoding:NSUTF8StringEncoding]]) return;
  if (vodMaster) {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSMutableArray *hosts = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
      if (![line hasPrefix:@"http"]) continue;
      NSURL *u = [NSURL URLWithString:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
      if (!u.host || !u.path) continue;
      @synchronized (vodPlaylistURLs) { [vodPlaylistURLs addObject:[u.host stringByAppendingString:u.path]]; }
      if (![hosts containsObject:u.host]) [hosts addObject:u.host];
    }
    os_log(OS_LOG_DEFAULT, "[TWAB-Rewind-Ads] VOD qualities served from %{public}@",
           hosts.count ? [hosts componentsJoinedByString:@", "] : @"(none listed)");
  }

  static NSArray<NSString *> *markers;
  static NSMutableDictionary<NSString *, NSString *> *seen;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    markers = @[@"stitched-ad", @"twitch-stitched", @"twitch-ad", @"X-TV-TWITCH-AD", @"SCTE35",
                @"EXT-X-CUE-OUT", @"EXT-X-CUE-IN", @"amazon", @"Amazon", @"preroll", @"midroll",
                @"video-weaver", @"\"ad\"", @"CLASS=\"ad"];
    seen = [NSMutableDictionary dictionary];
  });
  NSMutableArray *found = [NSMutableArray array];
  NSRange firstHit = NSMakeRange(NSNotFound, 0);
  for (NSString *m in markers) {
    NSData *needle = [m dataUsingEncoding:NSUTF8StringEncoding];
    NSRange r = [data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)];
    if (r.location == NSNotFound) continue;
    [found addObject:m];
    if (firstHit.location == NSNotFound || r.location < firstHit.location) firstHit = r;
  }
  // Discontinuities usually mark where something was spliced in.
  NSUInteger disc = 0;
  NSData *discNeedle = [@"#EXT-X-DISCONTINUITY" dataUsingEncoding:NSUTF8StringEncoding];
  NSRange search = NSMakeRange(0, data.length);
  while (disc < 1000) {
    NSRange r = [data rangeOfData:discNeedle options:0 range:search];
    if (r.location == NSNotFound) break;
    disc++;
    search = NSMakeRange(NSMaxRange(r), data.length - NSMaxRange(r));
  }
  NSString *summary = found.count ? [found componentsJoinedByString:@","] : @"none";
  NSString *key = [host stringByAppendingString:path];
  @synchronized (seen) {
    if ([seen[key] isEqualToString:summary]) return;
    seen[key] = summary;
  }
  NSString *snippet = @"";
  if (firstHit.location != NSNotFound) {
    NSUInteger start = firstHit.location > 80 ? firstHit.location - 80 : 0;
    NSUInteger len = MIN((NSUInteger)240, data.length - start);
    snippet = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(start, len)]
                                    encoding:NSUTF8StringEncoding] ?: @"";
    snippet = [snippet stringByReplacingOccurrencesOfString:@"\n" withString:@" | "];
  }
  os_log(OS_LOG_DEFAULT,
         "[TWAB-Rewind-Ads] %{public}s %{public}@%{public}@ (%lu KB, %lu discontinuities): ad markers %{public}@%{public}@%{public}@",
         vodMaster ? "VOD master" : "VOD playlist", host, path, (unsigned long)(data.length / 1024),
         (unsigned long)disc, summary, snippet.length ? @" — " : @"", snippet);
}

void twab_checkPlaylistForAds(NSData *data, NSURLRequest *request) {
  if (!data.length || !request) return;
  twab_checkVodPlaylistForAds(data, request);
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
  NSURLRequest *untracked = twab_trackingBlockedRequest(request);
  if (untracked) return %orig(untracked);
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if (twab_isAdHost(request.URL.host)) {
    os_log(OS_LOG_DEFAULT, "[TWAB-Rewind-Ads] blocked ad host %{public}@", request.URL.host);
    return nil;
  }
  if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
  ((NSMutableURLRequest *)request).HTTPBody = [request.HTTPBody twab_requestDataForRequest:request];
  if (![tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled]) return %orig;
  if (!twab_isMasterPlaylistHost(request.URL.host)) return %orig;
  if (twab_isExternalPlayback()) return %orig;  // Cast/AirPlay — send a clean URL
  if (twab_channelIsWhitelisted(request.URL)) return %orig;
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
  NSURLRequest *untracked = twab_trackingBlockedRequest(request);
  if (untracked) return %orig(untracked, bodyData);
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return %orig;
  if (twab_isAdHost(request.URL.host))
    return nil;
  if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
  bodyData = [bodyData twab_requestDataForRequest:request];
  if (![tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled]) return %orig;
  if (!twab_isMasterPlaylistHost(request.URL.host)) return %orig;
  if (twab_isExternalPlayback()) return %orig;  // Cast/AirPlay — send a clean URL
  if (twab_channelIsWhitelisted(request.URL)) return %orig;
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
  if (twab_isMasterPlaylistHost(URL.host) && !twab_channelIsWhitelisted(URL)) {
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
  NSString *proxy = twab_proxyPoolPick(twab_effectiveProxyAddresses());
  NSURLSession *session = [[NSURLSession alloc] twab_proxySessionWithAddress:proxy];
  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                twab_proxyPoolReportResult(proxy, error);
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
// Also turns animated WebP into GIF: emotes are downloaded as WebP (several
// times smaller than the CDNs' GIFs) but Twitch's image view only animates
// GIF. `pad` = Keep Wide Emote Shape is on.
static NSData *twab_padEmoteToSquare(NSData *data, BOOL pad) {
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (!src) return nil;
  size_t count = CGImageSourceGetCount(src);
  CGImageRef first = count ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
  if (!first) { CFRelease(src); return nil; }
  size_t w = CGImageGetWidth(first), h = CGImageGetHeight(first);
  CGImageRelease(first);
  BOOL animated = count > 1;
  NSString *type = (__bridge NSString *)CGImageSourceGetType(src);
  BOOL isWebP = [type isEqualToString:@"org.webmproject.webp"];
  // Within ~10% of square already looks fine stretched.
  BOOL needPad = pad && w && h && !(w * 10 <= h * 11 && h * 10 <= w * 11);
  BOOL needGif = animated && isWebP;
  if (!w || !h || (!needPad && !needGif)) { CFRelease(src); return nil; }
  size_t cw = needPad ? MAX(w, h) : w, ch = needPad ? MAX(w, h) : h;
  NSMutableData *out = [NSMutableData data];
  CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
      animated ? CFSTR("com.compuserve.gif") : CFSTR("public.png"), count, NULL);
  if (!dst) { CFRelease(src); return nil; }
  if (animated) {
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyProperties(src, NULL));
    NSNumber *loops = props[(id)kCGImagePropertyGIFDictionary][(id)kCGImagePropertyGIFLoopCount] ?:
                      props[@"{WebP}"][@"LoopCount"] ?: @0;
    CGImageDestinationSetProperties(dst, (__bridge CFDictionaryRef)@{
      (id)kCGImagePropertyGIFDictionary: @{ (id)kCGImagePropertyGIFLoopCount: loops } });
  }
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  for (size_t i = 0; i < count; i++) {
    CGImageRef frame = CGImageSourceCreateImageAtIndex(src, i, NULL);
    if (!frame) continue;
    CGContextRef ctx = CGBitmapContextCreate(NULL, cw, ch, 8, 0, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (ctx) {
      size_t fw = CGImageGetWidth(frame), fh = CGImageGetHeight(frame);
      CGContextDrawImage(ctx, CGRectMake((cw - fw) / 2.0, (ch - fh) / 2.0, fw, fh), frame);
      CGImageRef padded = CGBitmapContextCreateImage(ctx);
      NSDictionary *frameProps = nil;
      if (animated) {
        NSDictionary *fp = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, NULL));
        NSDictionary *gif = fp[(id)kCGImagePropertyGIFDictionary];
        NSDictionary *webp = fp[@"{WebP}"];
        NSNumber *delay = gif[(id)kCGImagePropertyGIFUnclampedDelayTime] ?:
                          gif[(id)kCGImagePropertyGIFDelayTime] ?:
                          webp[@"UnclampedDelayTime"] ?:
                          webp[@"DelayTime"] ?: @0.1;
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
  os_log(OS_LOG_DEFAULT, "[TWAB-Emote] %{public}s %zux%zu%{public}s emote to %zux%zu (%lu -> %lu bytes)",
         needPad ? "padded" : "converted", w, h, animated ? " animated" : "", cw, ch,
         (unsigned long)data.length, (unsigned long)out.length);
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

// The padded result is also kept on disk (empty file = "leave as is") so
// each emote is only processed once, not on every launch. The CDN images
// behind these URLs never change.
// Cache key for the padded (wide-shape) version of an emote.
static NSString *twab_fitKey(NSURL *url) {
  return [url.absoluteString stringByAppendingString:@"#pad"];
}

static NSString *twab_fitDiskPath(NSURL *url) {
  static NSString *dir;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    dir = [caches stringByAppendingPathComponent:@"TwitchAdBlock/emote_fit"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
  });
  uint64_t h = 1469598103934665603ULL;
  for (const char *c = twab_fitKey(url).UTF8String; c && *c; c++) { h ^= (uint8_t)*c; h *= 1099511628211ULL; }
  return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx", h]];
}

// Cached result for `url`, or nil if not computed yet.
static NSData *twab_cachedFitEmote(NSURL *url, NSData *data) {
  if (!url) return nil;
  id hit = [twab_emoteFitCache() objectForKey:twab_fitKey(url)];
  if (!hit) {
    NSData *disk = [NSData dataWithContentsOfFile:twab_fitDiskPath(url)];
    if (!disk) return nil;
    hit = disk.length ? disk : (id)kCFNull;
    [twab_emoteFitCache() setObject:hit forKey:twab_fitKey(url)];
  }
  return hit == (id)kCFNull ? data : hit;
}

// Original width/height of emote images we've padded, by URL — padding
// hides the real shape from anything that sees the image afterwards.
static NSCache<NSString *, NSNumber *> *twab_emoteAspectCache(void) {
  static NSCache *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 2000; });
  return cache;
}

CGFloat twab_emoteAspectForURL(NSURL *url) {
  NSString *key = url.absoluteString;
  return key ? [[twab_emoteAspectCache() objectForKey:key] doubleValue] : 0;
}

static void twab_recordEmoteAspect(NSURL *url, NSData *data) {
  NSString *key = url.absoluteString;
  if (!key) return;
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (!src) return;
  NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
  CFRelease(src);
  double w = [props[(id)kCGImagePropertyPixelWidth] doubleValue];
  double h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
  if (w > 0 && h > 0) [twab_emoteAspectCache() setObject:@(w / h) forKey:key];
}

static NSData *twab_fitEmoteImage(NSURL *url, NSData *data) {
  NSData *cached = twab_cachedFitEmote(url, data);
  if (cached) return cached;
  twab_recordEmoteAspect(url, data);
  NSData *padded = twab_padEmoteToSquare(data, YES);
  if (url) {
    [twab_emoteFitCache() setObject:padded ?: (id)kCFNull forKey:twab_fitKey(url)];
    NSString *path = twab_fitDiskPath(url);
    NSData *toWrite = padded ?: [NSData data];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      [toWrite writeToFile:path atomically:YES];
    });
  }
  return padded ?: data;
}

// Delegate path: emote images arrive in chunks; hold them until the task
// completes, then deliver the (padded) whole image in one go.
extern NSData *twab_injectChatEmoteSets(NSData *data, NSURLRequest *request);
static char twab_emoteBufferKey, twab_emoteFlushingKey, twab_emoteStartKey, twab_wholeResponseHeldKey;

// Hide Leaderboard: this response can arrive in several chunks, which can't be
// edited one at a time, so it's held like an emote image and edited whole at completion.
static BOOL twab_requestNamesOperation(NSURLRequest *request, NSString *operation) {
  if (![request.URL.host isEqualToString:@"gql.twitch.tv"] || !request.HTTPBody) return NO;
  NSString *quoted = [NSString stringWithFormat:@"\"%@\"", operation];
  NSData *needle = [quoted dataUsingEncoding:NSUTF8StringEncoding];
  return [request.HTTPBody rangeOfData:needle options:0 range:NSMakeRange(0, request.HTTPBody.length)].location != NSNotFound;
}

// Emote downloads taking over a second are logged with where the time went.
static NSMutableDictionary<NSString *, NSNumber *> *twab_emoteNetStarts;

void twab_emoteNetStart(NSURL *url) {
  NSString *k = url.absoluteString;
  if (!k) return;
  @synchronized (NSNull.null) {
    if (!twab_emoteNetStarts) twab_emoteNetStarts = [NSMutableDictionary dictionary];
    if (!twab_emoteNetStarts[k]) twab_emoteNetStarts[k] = @(CFAbsoluteTimeGetCurrent());
  }
}

// firstByte 0 = unknown.
static void twab_emoteNetEnd(NSURL *url, CFAbsoluteTime firstByte, double padMs, NSError *error, NSUInteger bytes) {
  NSString *k = url.absoluteString;
  if (!k) return;
  NSNumber *st;
  @synchronized (NSNull.null) {
    st = twab_emoteNetStarts[k];
    [twab_emoteNetStarts removeObjectForKey:k];
  }
  if (!st || error) return;
  double total = (CFAbsoluteTimeGetCurrent() - st.doubleValue) * 1000;
  if (total > 1000)
    os_log(OS_LOG_DEFAULT, "[TWAB-EmoteNet] slow: %.0fms total, first byte after %.0fms, processing %.0fms, %lu bytes %{public}@%{public}@",
           total, firstByte ? (firstByte - st.doubleValue) * 1000 : -1, padMs,
           (unsigned long)bytes, url.host, url.path);
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

// ─── Stream Rewind ───────────────────────────────────────────────────────────
// Twitch 32.2 has its own live rewind (scrub bar, double-tap skip, Jump to
// Live) that plays the stream's in-progress VOD. It needs two things the app
// only gets for viewers in Twitch's rollout: the savvy flags (added to the
// React Native start-up flag overrides below) and channel.self.dvr.vodID in
// NativeChannelLiveQuery, which the server leaves null. That VOD is the
// channel's archive that is recording right now, so it's looked up (started as
// soon as the live query is sent, and remembered for a few minutes) and filled
// in before the response reaches the app. Any failure leaves it unchanged.
@interface TWABDvrLookup : NSObject
@property (nonatomic) BOOL finished;
@property (nonatomic, copy) NSString *vodID;
@property (nonatomic) CFAbsoluteTime started;
@property (nonatomic, strong) NSMutableArray *waiters;
@end
@implementation TWABDvrLookup
@end

static NSString *twab_dvrLoginFromRequest(NSURLRequest *request) {
  if (!request.HTTPBody.length) return nil;
  id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
  NSArray *ops = [body isKindOfClass:NSArray.class] ? body : (body ? @[body] : @[]);
  for (NSDictionary *op in ops) {
    if (![op isKindOfClass:NSDictionary.class]) continue;
    if (![op[@"operationName"] isEqual:@"NativeChannelLiveQuery"]) continue;
    NSDictionary *vars = op[@"variables"];
    if ([vars isKindOfClass:NSDictionary.class] && [vars[@"login"] isKindOfClass:NSString.class])
      return [vars[@"login"] lowercaseString];
  }
  return nil;
}

static void twab_dvrFetchLiveVod(NSURLRequest *original, NSString *login, void (^done)(NSString *vodID)) {
  NSString *safe = [[login componentsSeparatedByCharactersInSet:
      [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyz0123456789_"] invertedSet]] componentsJoinedByString:@""];
  if (!safe.length) { done(nil); return; }
  NSString *q = [NSString stringWithFormat:
      @"query{user(login:\"%@\"){videos(first:1,type:ARCHIVE,sort:TIME){edges{node{id status}}}}}", safe];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
  req.HTTPMethod = @"POST";
  req.timeoutInterval = 4;
  for (NSString *h in @[@"Client-Id", @"Authorization", @"X-Device-Id", @"Accept-Language", @"User-Agent"]) {
    NSString *v = [original valueForHTTPHeaderField:h];
    if (v) [req setValue:v forHTTPHeaderField:h];
  }
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"query": q } options:0 error:nil];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
    NSString *vodID = nil, *status = nil;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    @try {
      NSDictionary *node = json[@"data"][@"user"][@"videos"][@"edges"][0][@"node"];
      if ([node isKindOfClass:NSDictionary.class]) {
        status = node[@"status"];
        if ([status isEqual:@"RECORDING"] && [node[@"id"] isKindOfClass:NSString.class]) vodID = node[@"id"];
      }
    } @catch (__unused id e) {}
    BOOL gqlError = [json isKindOfClass:NSDictionary.class] && json[@"errors"];
    os_log(OS_LOG_DEFAULT, "[TWAB-Rewind] %{public}@: %{public}@%{public}@", safe,
           vodID ? [@"VOD " stringByAppendingString:vodID]
                 : [NSString stringWithFormat:@"no live VOD (latest is %@)", status ?: @"none"],
           err ? @", request failed" : (gqlError ? @", query error" : @""));
    [session finishTasksAndInvalidate];
    done(vodID);
  }] resume];
}

// One lock for the lookups and their waiters.
static NSObject *twab_dvrLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  return lock;
}

// The lookup for `login`: a recent one, or a new one started now.
static TWABDvrLookup *twab_dvrLookup(NSURLRequest *request, NSString *login) {
  static NSMutableDictionary<NSString *, TWABDvrLookup *> *lookups;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lookups = [NSMutableDictionary dictionary]; });
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  TWABDvrLookup *l;
  @synchronized (twab_dvrLock()) {
    l = lookups[login];
    // Found: good for 5 minutes (a new broadcast gets a new VOD). Not found: 1.
    CFTimeInterval keep = l.vodID ? 300 : 60;
    if (l && (!l.finished || now - l.started < keep)) return l;
    l = [TWABDvrLookup new];
    l.started = now;
    l.waiters = [NSMutableArray array];
    lookups[login] = l;
  }
  twab_dvrFetchLiveVod(request, login, ^(NSString *vodID) {
    NSArray *waiters;
    @synchronized (twab_dvrLock()) {
      l.vodID = vodID;
      l.finished = YES;
      waiters = [l.waiters copy];
      [l.waiters removeAllObjects];
    }
    for (void (^w)(NSString *) in waiters) w(vodID);
  });
  return l;
}

static void twab_dvrWhenFound(TWABDvrLookup *l, void (^block)(NSString *vodID)) {
  BOOL ready = NO;
  NSString *vod = nil;
  @synchronized (twab_dvrLock()) {
    if (l.finished) { ready = YES; vod = l.vodID; }
    else [l.waiters addObject:[block copy]];
  }
  if (ready) block(vod);
}

// Exported for the __NSURLSessionLocal task hook (Emotes.x): starts the lookup
// as the live query goes out, so it's usually done when the response lands.
void twab_streamRewindPrefetch(NSURLRequest *request) {
  if (![tweakDefaults boolForKey:TWABKeyStreamRewind]) return;
  if (!twab_requestNamesOperation(request, @"NativeChannelLiveQuery")) return;
  NSString *login = twab_dvrLoginFromRequest(request);
  if (login) twab_dvrLookup(request, login);
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
  if (task.error && twab_isEmoteImageRequest(task.originalRequest))
    twab_emoteNetEnd(task.originalRequest.URL, 0, 0, task.error, 0);
  if (!buf || ![task isKindOfClass:NSURLSessionDataTask.class]) return NO;
  objc_setAssociatedObject(task, &twab_emoteBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (objc_getAssociatedObject(task, &twab_wholeResponseHeldKey) &&
      twab_requestNamesOperation(task.originalRequest, @"NativeChannelLiveQuery")) {
    NSData *nullID = [@"\"vodID\":null" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *login = twab_dvrLoginFromRequest(task.originalRequest);
    if (!login || task.error ||
        [buf rangeOfData:nullID options:0 range:NSMakeRange(0, buf.length)].location == NSNotFound) {
      // Twitch sending the VOD itself means rewind has reached this account.
      NSData *dvrField = [@"\"dvr\":{\"vodID\":\"" dataUsingEncoding:NSUTF8StringEncoding];
      if (login && !task.error && [buf rangeOfData:dvrField options:0 range:NSMakeRange(0, buf.length)].location != NSNotFound)
        os_log(OS_LOG_DEFAULT, "[TWAB-Rewind] Twitch sent the rewind VOD itself for %{public}@ — Stream Rewind is live for this account", login);
      twab_deliverEmote(delegate, session, task, buf);
      complete();
      return YES;
    }
    NSData *held = [buf copy];
    twab_dvrWhenFound(twab_dvrLookup(task.originalRequest, login), ^(NSString *vodID) {
      NSData *out = held;
      if (vodID) {
        NSString *str = [[NSString alloc] initWithData:held encoding:NSUTF8StringEncoding];
        NSString *filled = [str stringByReplacingOccurrencesOfString:@"\"vodID\":null"
            withString:[NSString stringWithFormat:@"\"vodID\":\"%@\"", vodID]];
        NSData *d = [filled dataUsingEncoding:NSUTF8StringEncoding];
        if (d) out = d;
      }
      void (^finish)(void) = ^{
        twab_deliverEmote(delegate, session, task, out);
        complete();
      };
      NSOperationQueue *q = session.delegateQueue;
      if (q) [q addOperationWithBlock:finish];
      else dispatch_async(dispatch_get_main_queue(), finish);
    });
    return YES;
  }
  if (objc_getAssociatedObject(task, &twab_wholeResponseHeldKey)) {
    NSData *edited = [buf twab_dataHidingLeaderboardsForRequest:task.originalRequest];
    if (twab_requestNamesOperation(task.originalRequest, @"ChatEmoteSets"))
      edited = twab_injectChatEmoteSets(edited, task.originalRequest);
    edited = twab_rewriteWatchLimitBytes(edited, task.currentRequest, NSStringFromClass([delegate class]));
    edited = [edited twab_responseDataForRequest:task.currentRequest];
    twab_deliverEmote(delegate, session, task, edited);
    complete();
    return YES;
  }
  NSURL *url = task.originalRequest.URL;
  CFAbsoluteTime start = [objc_getAssociatedObject(task, &twab_emoteStartKey) doubleValue];
  NSData *cached = buf.length ? twab_cachedFitEmote(url, buf) : buf;
  if (cached) {
    if (!task.error) twab_emoteNetEnd(url, start, 0, nil, buf.length);
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
      if (!task.error) twab_emoteNetEnd(url, start, padMs, nil, buf.length);
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
      twab_isEmoteImageRequest(dataTask.originalRequest) &&
      [delegate respondsToSelector:@selector(URLSession:task:didCompleteWithError:)])
    return twab_bufferEmoteChunk(data, dataTask);
  if (objc_getAssociatedObject(dataTask, &twab_emoteFlushingKey)) return data;
  if ([delegate isKindOfClass:objc_getClass("RCTHTTPRequestHandler")]) {
    BOOL needHold = NO;
    if ([tweakDefaults boolForKey:TWABKeyHideLeaderboard] &&
        twab_requestNamesOperation(dataTask.originalRequest, @"ChannelLeaderboards"))
      needHold = YES;
    if (!needHold && [tweakDefaults boolForKey:TWABKeyHideCommunityHighlights] &&
        (twab_requestNamesOperation(dataTask.originalRequest, @"GetPinnedChat") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"GetOngoingHypeTrain") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"GetActivePrediction") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"GetViewablePoll") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"GetActiveGoals") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"CommunityChallengeGoals") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"ChannelDropsCampaigns") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"DropChannelCampaignsProgress")))
      needHold = YES;
    if (!needHold && [tweakDefaults boolForKey:TWABKeyEmotesEnabled] &&
        twab_requestNamesOperation(dataTask.originalRequest, @"ChatEmoteSets"))
      needHold = YES;
    // Profile page's "Try Ad-Free" (React Native since Twitch 32.2): every
    // request that loads the viewer's turboStatus.
    if (!needHold && [tweakDefaults boolForKey:TWABKeyHideAdFreeButton] &&
        (twab_requestNamesOperation(dataTask.originalRequest, @"ChannelProfileShell") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"CurrentUser") ||
         twab_requestNamesOperation(dataTask.originalRequest, @"MwebDiscoveryFeedPreloadQuery")))
      needHold = YES;
    if (!needHold && [tweakDefaults boolForKey:TWABKeyStreamRewind] &&
        twab_requestNamesOperation(dataTask.originalRequest, @"NativeChannelLiveQuery"))
      needHold = YES;  // Stream Rewind: fill in the live VOD
    if (needHold) {
      objc_setAssociatedObject(dataTask, &twab_wholeResponseHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      return twab_bufferEmoteChunk(data, dataTask);
    }
  }
  data = twab_rewriteWatchLimitBytes(data, dataTask.currentRequest, NSStringFromClass([delegate class]));
  // Ad-block (ad strip, watch limit) and Hide Stories (empties the Stories
  // shelf response) both filter here; each is gated inside on its own toggle.
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled] &&
      ![tweakDefaults boolForKey:TWABKeyHideStories] &&
      ![tweakDefaults boolForKey:TWABKeyHideAdFreeButton] &&
      ![tweakDefaults boolForKey:TWABKeyHideCommunityHighlights]) return data;
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

// Hide "Go Ad-Free" (Twitch 32.2): the feed preload also carries the viewer's
// turboStatus (MwebDiscoveryFeedPreloadQuery). Mark it active, as for the
// network responses, in objects or JSON text.
static id twab_markTurboActiveAny(id obj, NSUInteger depth) {
  if (!obj || depth > 40) return obj;
  if ([obj isKindOfClass:NSDictionary.class]) {
    NSMutableDictionary *d = [(NSDictionary *)obj mutableCopy];
    for (id key in [d allKeys]) {
      if ([key isEqual:@"turboStatus"] && [d[key] isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *status = [d[key] mutableCopy];
        status[@"hasActiveTurbo"] = @YES;
        d[key] = status;
      } else {
        d[key] = twab_markTurboActiveAny(d[key], depth + 1);
      }
    }
    return d;
  }
  if ([obj isKindOfClass:NSArray.class]) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
    for (id v in (NSArray *)obj) [a addObject:twab_markTurboActiveAny(v, depth + 1) ?: (id)kCFNull];
    return a;
  }
  if ([obj isKindOfClass:NSString.class] && [(NSString *)obj containsString:@"hasActiveTurbo"]) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      re = [NSRegularExpression regularExpressionWithPattern:
              @"(\\\\?\"hasActiveTurbo\\\\?\"\\s*:\\s*)false" options:0 error:nil];
    });
    NSString *s = obj;
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length)
                                   withTemplate:@"$1true"];
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
      BOOL adBlock = [tweakDefaults boolForKey:TWABKeyAdBlockEnabled];
      BOOL hideAdFree = [tweakDefaults boolForKey:TWABKeyHideAdFreeButton];
      if (resolve && (adBlock || hideAdFree)) {
        wrapped = ^(id result) {
          id out = result;
          if (adBlock) {
            // This page skips the network hooks, so feed ads are removed here too. Left
            // in, one stayed as a tall empty slot under the first channel.
            out = twab_stripPreloadFeedAds(out, 0);
            if ([tweakDefaults boolForKey:TWABKeyDisableWatchLimit]) {
              NSUInteger before = twab_preloadLimitsNulled;
              out = twab_nullWatchLimits(out, 0);
              os_log(OS_LOG_DEFAULT, "[TWAB-Watch] feed preload resolved (%{public}@), limits nulled: %lu",
                     NSStringFromClass([result class]), (unsigned long)(twab_preloadLimitsNulled - before));
            }
          }
          if (hideAdFree) out = twab_markTurboActiveAny(out, 0);
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
    if (data && [tweakDefaults boolForKey:TWABKeyEmotesEnabled] && twab_isEmoteImageRequest(request)) {
      // Wide 3rd-party emotes. Cached → now; otherwise pad off this queue
      // and call back on it, so padding never stalls other responses.
      NSData *cached = twab_cachedFitEmote(request.URL, data);
      if (cached) {
        twab_emoteNetEnd(request.URL, 0, 0, error, data.length);
        handler(cached, response, error);
        return;
      }
      NSOperationQueue *back = NSOperationQueue.currentQueue;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime padStart = CFAbsoluteTimeGetCurrent();
        NSData *out = twab_fitEmoteImage(request.URL, data);
        twab_emoteNetEnd(request.URL, 0, (CFAbsoluteTimeGetCurrent() - padStart) * 1000, error, data.length);
        if (back) [back addOperationWithBlock:^{ handler(out, response, error); }];
        else handler(out, response, error);
      });
      return;
    }
    handler(data ? twab_rewriteWatchLimitBytes(data, request, @"completionHandler") : data, response, error);
  };
}

extern NSURL *twab_realEmoteURL(NSURL *url);

%hook __NSURLSessionLocal
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
  NSURLRequest *untracked = twab_trackingBlockedRequest(request);
  if (untracked) return %orig(untracked, completionHandler);
  // Our 3rd-party emote IDs only exist on their real CDNs.
  NSURL *real = request.URL ? twab_realEmoteURL(request.URL) : nil;
  if (real) {
    NSMutableURLRequest *m = request.mutableCopy;
    m.URL = real;
    request = m;
  }
  return %orig(request, twab_wrapWatchCompletion(request, completionHandler));
}
// The chat box's emote previews use sharedSession dataTaskWithURL:.
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
  NSURL *untracked = twab_trackingBlockedURL(url);
  if (untracked) return %orig(untracked, completionHandler);
  NSURL *real = url ? twab_realEmoteURL(url) : nil;
  if (real && completionHandler)
    return [(NSURLSession *)self dataTaskWithRequest:[NSURLRequest requestWithURL:real]
                                   completionHandler:completionHandler];
  return %orig(real ?: url, completionHandler);
}
// Block Tracking: crash/usage SDKs (Firebase, Sentry) upload their reports.
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
  NSURLRequest *untracked = twab_trackingBlockedRequest(request);
  return %orig(untracked ?: request, bodyData, completionHandler);
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromFile:(NSURL *)fileURL
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
  NSURLRequest *untracked = twab_trackingBlockedRequest(request);
  return %orig(untracked ?: request, fileURL, completionHandler);
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL {
  NSURLRequest *untracked = twab_trackingBlockedRequest(request);
  return %orig(untracked ?: request, fileURL);
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
  NSURLRequest *untracked = twab_trackingBlockedRequest(request);
  return %orig(untracked ?: request, bodyData);
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
  if ([testID isEqualToString:@"player-controls-clips"] ||
      [testID isEqualToString:@"clip-reaction-button"] ||
      [testID isEqualToString:@"theatre-clip-button-overlay-region"])
    return [tweakDefaults boolForKey:TWABKeyHideClipButton];
  if ([testID isEqualToString:@"following-turbo-upsell"])
    return [tweakDefaults boolForKey:TWABKeyHideAdFreeButton];
  return NO;
}

// Sub goal views are standalone banners above chat — hidden + removeFromSuperview
// so they don't leave a white box.
// The chat box's buttons (Bits) are hidden in place. If the named view turns
// out to hold the text field or be much bigger than a button (Twitch 32.2's
// chat input layout), hiding it would blank the chat box, so it's left shown.
static BOOL twab_containsChatInput(UIView *view, int depth) {
  static Class inputCls;
  if (!inputCls) inputCls = objc_getClass("_TtC21twitch_rn_emote_input20TwitchEmoteInputView");
  if (inputCls && [view isKindOfClass:inputCls]) return YES;
  if (depth <= 0) return NO;
  for (UIView *sub in view.subviews)
    if (twab_containsChatInput(sub, depth - 1)) return YES;
  return NO;
}

static BOOL twab_isSafeChatButton(UIView *view, NSString *testID) {
  if (![testID hasPrefix:@"chat-tray-button-"]) return YES;
  CGSize s = view.bounds.size;
  BOOL big = s.width > 80 || s.height > 80;
  BOOL hasInput = twab_containsChatInput(view, 8);
  static int logs;
  if (logs < 12 && (s.width > 0 || hasInput)) {
    logs++;
    os_log(OS_LOG_DEFAULT,
        "[TWAB-Hide] %{public}@ size=%.0fx%.0f subviews=%lu parent=%{public}@ input=%d",
        testID, s.width, s.height, (unsigned long)view.subviews.count,
        view.superview.accessibilityIdentifier ?: NSStringFromClass(view.superview.class), hasInput);
  }
  return !big && !hasInput;
}

static BOOL twab_shouldRemoveTestID(NSString *testID) {
  if ([testID hasPrefix:@"highlight-creator-goal"] ||
      [testID hasPrefix:@"chat-sub-goal"] ||
      [testID hasPrefix:@"creator-goal"] ||
      [testID isEqualToString:@"community-goal-progress"])
    return [tweakDefaults boolForKey:TWABKeyHideCommunityHighlights] &&
           [tweakDefaults boolForKey:TWABKeyHideSubGoal];
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

// Hide Channel Bar: the message scroller's mask lets rows draw up into the
// bar's space but not below the scroller. A scroller's layer coordinates
// move with its content offset, so the mask is re-placed on every layout pass
// (which runs on every scroll).
static char twab_scrollMaskKey;
static void twab_updateScrollMask(UIScrollView *scroll) {
  CALayer *m = objc_getAssociatedObject(scroll, &twab_scrollMaskKey);
  CGFloat extra = [objc_getAssociatedObject(scroll, &twab_touchExtensionKey) doubleValue];
  if (!m) return;
  CGRect b = scroll.bounds;
  CGRect f = CGRectMake(b.origin.x, b.origin.y - extra, b.size.width, b.size.height + extra);
  if (CGRectEqualToRect(m.frame, f)) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  m.frame = f;
  [CATransaction commit];
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
  // The message scroller is unclipped so its rows can draw up into the bar's
  // space, but they must never draw below its bottom edge: that's the chat
  // box, and while the box grows to two lines the rows covered it ("chat box
  // goes blank", Twitch 32.2). The mask goes on the scroller, not the list,
  // because the channel points button lives in the list and would be cut off.
  BOOL masked = NO;
  for (UIView *sub in list.subviews) {
    if (![sub isKindOfClass:UIScrollView.class]) continue;
    if (!objc_getAssociatedObject(sub, &twab_scrollMaskKey)) {
      CALayer *m = [CALayer layer];
      m.backgroundColor = UIColor.whiteColor.CGColor;
      sub.layer.mask = m;
      objc_setAssociatedObject(sub, &twab_scrollMaskKey, m, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    twab_updateScrollMask((UIScrollView *)sub);
    masked = YES;
  }
  static BOOL warned;
  if (!masked && !warned) {
    warned = YES;
    os_log(OS_LOG_DEFAULT, "[TWAB-Box] no message scroller under chat-message-list; rows not masked");
  }
  CGRect lb = list.bounds;
  static int boxLogs;
  static CGFloat lastListH;
  if (boxLogs < 20 && fabs(lb.size.height - lastListH) >= 1) {
    boxLogs++;
    lastListH = lb.size.height;
    CGRect lw = [list convertRect:lb toView:nil], rw = [region convertRect:region.bounds toView:nil];
    os_log(OS_LOG_DEFAULT, "[TWAB-Box] list y=%.0f-%.0f region y=%.0f-%.0f bar=%.0f",
           CGRectGetMinY(lw), CGRectGetMaxY(lw), CGRectGetMinY(rw), CGRectGetMaxY(rw), height);
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

// Live page category chips (All, League of Legends…, Twitch 32.2) hide when
// the feed scrolls down by more than ~1.5x their height and show again after
// a move up. Holding the feed at the bar's height counts as a scroll down, so
// they stayed hidden until the user scrolled. When they fade out while the
// feed sits at its top, scroll the feed a little further down and back:
// Twitch sees a move up and shows the chips. While it's moved, the feed's
// drawing is shifted back by the same amount (sublayerTransform), so nothing
// moves on screen. Triggered by the fade itself, since the chips can start
// listening to scrolls after the feed was already moved.
static char twab_chipsNudgeKey;

static void twab_setScrollQuietly(UIScrollView *s, CGFloat y, CGFloat drawShift) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  s.contentOffset = CGPointMake(s.contentOffset.x, y);
  s.layer.sublayerTransform = drawShift ? CATransform3DMakeTranslation(0, drawShift, 0)
                                        : CATransform3DIdentity;
  [CATransaction commit];
}

static void twab_nudgeChipsVisible(UIScrollView *scroll, CGFloat top) {
  if (!scroll || objc_getAssociatedObject(scroll, &twab_chipsNudgeKey)) return;
  objc_setAssociatedObject(scroll, &twab_chipsNudgeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // The move back up must exceed 0.75x Twitch's base height for the chips,
  // which is taller than the 48pt row (48 didn't work, 80 did).
  static const CGFloat overshoot = 100;
  __weak UIScrollView *weakScroll = scroll;
  // Steps 80 ms apart so React Native sends each one as its own scroll event
  // (it throttles and merges events closer together).
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
    UIScrollView *s = weakScroll;
    if (!s) return;
    if (s.tracking || s.dragging || s.decelerating || fabs(s.contentOffset.y - top) >= 1) {
      objc_setAssociatedObject(s, &twab_chipsNudgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      return;
    }
    twab_setScrollQuietly(s, top + overshoot, overshoot);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
      UIScrollView *s2 = weakScroll;
      if (!s2) return;
      // Always drop the draw shift; only move back if nothing else moved it.
      BOOL untouched = !s2.tracking && !s2.dragging && !s2.decelerating &&
                       fabs(s2.contentOffset.y - (top + overshoot)) < 1;
      twab_setScrollQuietly(s2, untouched ? top : s2.contentOffset.y, 0);
      os_log(OS_LOG_DEFAULT, "[TWAB-Chips] nudged feed so the category chips show (top %.0f)", top);
      objc_setAssociatedObject(s2, &twab_chipsNudgeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
  });
}

// The Live feed scroller next to the chips row (testID subfeed-chips-visibility)
// when it's at its top (or mid-nudge), where the chips should always show;
// otherwise nil. *outTop gets the top.
static UIScrollView *twab_chipsFeedAtTop(UIView *chips, CGFloat *outTop) {
  for (UIView *a = chips.superview; a; a = a.superview) {
    UIView *list = twab_findTestID(a, @"feed-list", 4);
    if (!list) continue;
    for (UIView *sub in list.subviews) {
      if (![sub isKindOfClass:UIScrollView.class]) continue;
      UIScrollView *scroll = (UIScrollView *)sub;
      CGFloat top = [objc_getAssociatedObject(scroll, &twab_feedTopKey) doubleValue];
      if (top <= 0 || scroll.tracking || scroll.dragging || scroll.decelerating) return nil;
      BOOL nudging = objc_getAssociatedObject(scroll, &twab_chipsNudgeKey) != nil;
      if (!nudging && fabs(scroll.contentOffset.y - top) >= 1) return nil;
      if (outTop) *outTop = top;
      return scroll;
    }
    return nil;
  }
  return nil;
}

// Called as Twitch updates the chips row's props: once Twitch has faded them
// out while the feed sits at its top, a nudge brings them back (Twitch fades
// them in again).
static void twab_chipsPropsUpdated(UIView *chips) {
  if (!chips || chips.layer.opacity >= 0.05) return;
  CGFloat top = 0;
  UIScrollView *scroll = twab_chipsFeedAtTop(chips, &top);
  if (!scroll) return;
  static CFAbsoluteTime last, windowStart;
  static int inWindow;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  // Twitch can fade them out again after a nudge brought them back, and it
  // sends no further updates once they're hidden: so a fade during the
  // cooldown (or mid-nudge) is retried when it ends, never dropped.
  CFTimeInterval wait = MAX(1.0 - (now - last), 0);
  if (objc_getAssociatedObject(scroll, &twab_chipsNudgeKey)) wait = MAX(wait, 0.3);
  static BOOL retryPending;
  if (wait > 0) {
    if (retryPending) return;
    retryPending = YES;
    __weak UIView *weakChips = chips;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((wait + 0.05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      retryPending = NO;
      twab_chipsPropsUpdated(weakChips);
    });
    return;
  }
  // Never loop: at most 6 nudges in any 10 s.
  if (now - windowStart > 10) { windowStart = now; inWindow = 0; }
  if (++inWindow > 6) return;
  last = now;
  twab_nudgeChipsVisible(scroll, top);
}

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

// ─── Chat text + emote scaling ──────────────────────────────────────────────
static BOOL twab_isInsideChatMessageList(UIView *view);
static CGFloat twab_chatTextScale(void);
static CGFloat twab_chatTextScale(void) {
  NSInteger idx = [tweakDefaults integerForKey:TWABKeyChatTextScale];
  if (idx == 1) return 1.25;
  if (idx == 2) return 1.5;
  return 1.0;
}

static CGFloat twab_emoteScale(void) {
  NSInteger idx = [tweakDefaults integerForKey:TWABKeyChatEmoteScale];
  if (idx == 1) return 1.25;
  if (idx == 2) return 1.5;
  return 1.0;
}

// Hook RCTFont to scale font size directly for chat text. We modify the `size`
// parameter rather than `scaleMultiplier` because Twitch sets allowFontScaling=false
// (scaleMultiplier=0) on chat text, bypassing the multiplier path entirely.
// Font scaling in the layout manager, for chat message lines only — both
// measurement and drawing use the scaled fonts, so text reflows correctly.
// Wide emotes: Twitch gives every emote a square slot. Emotes.x puts a
// marker (U+2063 + one U+2064 per quarter of width/height) before wide ones;
// widening that attachment makes the line leave room for the whole emote.
static void twab_widenMarkedAttachments(NSAttributedString *s) {
  NSString *str = s.string;
  if ([str rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0x2063]].location == NSNotFound) return;
  NSUInteger len = str.length;
  for (NSUInteger i = 0; i < len; i++) {
    if ([str characterAtIndex:i] != 0x2063) continue;
    NSUInteger j = i + 1, n = 0;
    while (j < len && [str characterAtIndex:j] == 0x2064) { n++; j++; }
    if (j >= len || n < 5) continue;
    NSTextAttachment *att = [s attribute:NSAttachmentAttributeName atIndex:j effectiveRange:NULL];
    if (![att isKindOfClass:[NSTextAttachment class]]) continue;
    CGRect b = att.bounds;
    if (b.size.height <= 0) continue;
    b.size.width = round(b.size.height * (CGFloat)n / 4.0);
    att.bounds = b;
    i = j;
  }
}

extern NSArray<NSValue *> *twab_sentEmoteSlots(NSString *str);

// Your own sent message: see twab_sentEmoteSlots in Emotes.x.
static void twab_widenSentAttachments(NSAttributedString *s) {
  for (NSValue *v in twab_sentEmoteSlots(s.string)) {
    NSRange r = v.rangeValue;
    if (r.location >= s.length) continue;
    NSTextAttachment *att = [s attribute:NSAttachmentAttributeName atIndex:r.location effectiveRange:NULL];
    if (![att isKindOfClass:[NSTextAttachment class]]) continue;
    CGRect b = att.bounds;
    if (b.size.height <= 0) continue;
    b.size.width = round(b.size.height * (CGFloat)r.length / 4.0);
    att.bounds = b;
  }
}

// Chat message lines are "<name>: <message>" with the name and the message
// each wrapped in invisible U+2068...U+2069 marks; other text in the app isn't.
static BOOL twab_isChatMessageLine(NSString *str) {
  static NSString *needle;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ needle = [NSString stringWithFormat:@"%C: %C", (unichar)0x2069, (unichar)0x2068]; });
  return [str rangeOfString:needle].location != NSNotFound;
}

%hook RCTTextLayoutManager
- (NSAttributedString *)_nsAttributedStringFromAttributedString:(const void *)attributedString {
  NSAttributedString *result = %orig;
  if (result.length) {
    twab_widenMarkedAttachments(result);
    twab_widenSentAttachments(result);
  }
  CGFloat scale = twab_chatTextScale();
  if (fabs(scale - 1.0) < 0.01 || result.length == 0 || !twab_isChatMessageLine(result.string)) return result;

  NSMutableAttributedString *scaled = [result mutableCopy];
  [scaled enumerateAttribute:NSFontAttributeName
                     inRange:NSMakeRange(0, scaled.length)
                     options:0
                  usingBlock:^(UIFont *font, NSRange range, BOOL *stop) {
    if (!font) return;
    // Skip attachment characters (emote/image placeholders) — scaling their
    // font disrupts inline image sizing and makes emotes disappear.
    if ([scaled attribute:NSAttachmentAttributeName atIndex:range.location effectiveRange:nil]) return;
    [scaled addAttribute:NSFontAttributeName
                   value:[font fontWithSize:font.pointSize * scale]
                   range:range];
  }];
  return scaled;
}
%end


static BOOL twab_isInsideChatMessageList(UIView *view) {
  for (UIView *v = view.superview; v; v = v.superview) {
    NSString *aid = v.accessibilityIdentifier;
    if ([aid isEqualToString:@"chat-message-list"]) return YES;
    if ([aid isEqualToString:@"theatre-portrait-layout"]) return NO;
  }
  return NO;
}

// Lets a grown emote draw past its row by unclipping the views between it
// and the chat list. Never touches the list or anything above it: unclipped,
// its rows draw over the chat box while the box resizes ("chat box goes
// blank"). An emote that isn't inside the list is left alone entirely, so a
// changed view layout in a Twitch update can't unclip the whole screen.
static void twab_unclipToChatList(UIView *view) {
  static int dumps;
  if (!twab_isInsideChatMessageList(view)) {
    if (dumps < 3) {
      dumps++;
      NSMutableString *chain = [NSMutableString string];
      for (UIView *p = view.superview; p && p != view.window; p = p.superview)
        [chain appendFormat:@" > %@[%@]", NSStringFromClass(p.class), p.accessibilityIdentifier ?: @""];
      os_log(OS_LOG_DEFAULT, "[TWAB-Box] emote outside chat list, left clipped:%{public}@", chain);
    }
    return;
  }
  for (UIView *p = view.superview; p && p != view.window; p = p.superview) {
    if ([p.accessibilityIdentifier isEqualToString:@"chat-message-list"]) break;
    if (p.clipsToBounds) p.clipsToBounds = NO;
  }
}

static void twab_scaleEmoteIfNeeded(UIView *view);

// ─── Live declutter ─────────────────────────────────────────────────────────
// Settings switches for stream-screen buttons apply to what's on screen right
// away, instead of waiting for the next stream. Hiding the channel bar applies
// live too; showing it again (undoing the masks and moved banners) waits for
// the next stream, as does showing the leaderboard again (its data was
// already emptied).
static void twab_applyDeclutterIn(UIView *view, NSMutableArray *regions, int depth) {
  static Class rnView;
  if (!rnView) rnView = objc_getClass("RCTViewComponentView");
  NSString *testID = view.accessibilityIdentifier;
  if (testID.length && rnView && [view isKindOfClass:rnView]) {
    BOOL barHidden = [tweakDefaults boolForKey:TWABKeyHideChannelBar];
    BOOL wasHidden = objc_getAssociatedObject(view, &twab_declutterHiddenKey) != nil;
    if ([testID isEqualToString:@"chat-message-region"]) {
      [regions addObject:view];
    } else if ([testID isEqualToString:@"feed-recaps-shelf-absorb"] ||
               (barHidden && twab_isPanelOnlyTestID(testID))) {
      // Feed shelf needs its row shift; panel buttons follow the channel bar.
    } else if ([testID isEqualToString:@"stage-inflow-metadata"]) {
      if (barHidden && !wasHidden) {
        objc_setAssociatedObject(view, &twab_declutterHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = YES;
      }
    } else if (twab_shouldHideTestID(testID) && twab_isSafeChatButton(view, testID)) {
      if (!wasHidden) {
        objc_setAssociatedObject(view, &twab_declutterHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.hidden = YES;
      }
    } else if (wasHidden && ![testID isEqualToString:@"channel-leaderboard-strip-pressable"]) {
      twab_restoreDecluttered(view);
    }
  }
  if (depth <= 0) return;
  for (UIView *sub in view.subviews) twab_applyDeclutterIn(sub, regions, depth - 1);
}

static void twab_applyDeclutterNow(void) {
  NSMutableArray *regions = [NSMutableArray array];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  for (UIWindow *window in UIApplication.sharedApplication.windows)
    twab_applyDeclutterIn(window, regions, 120);
#pragma clang diagnostic pop
  if ([tweakDefaults boolForKey:TWABKeyHideChannelBar]) {
    for (UIView *region in regions) {
      twab_collapseChannelBar(region);
      __weak UIView *weakRegion = region;
      dispatch_async(dispatch_get_main_queue(), ^{ twab_collapseChannelBar(weakRegion); });
    }
  }
  os_log(OS_LOG_DEFAULT, "[TWAB-Hide] applied settings live (%lu stream screens)",
         (unsigned long)regions.count);
}

// TWABSettingsVC.m: a stream opened, so waiting setting changes are in effect.
extern void twab_settingsStreamOpened(void);

%hook RCTViewComponentView
- (void)setAccessibilityIdentifier:(NSString *)identifier {
  %orig;
  UIView *view = (UIView *)self;
  if ([identifier isEqualToString:@"chat-message-region"]) twab_settingsStreamOpened();
  // New buttons and banners aren't attached yet, so they're checked once they are.
  if ((twab_isPanelOnlyTestID(identifier) || [identifier isEqualToString:@"chat-top-banner-carousel"] ||
       [identifier isEqualToString:@"chat-top-of-chat"]) &&
      [tweakDefaults boolForKey:TWABKeyHideChannelBar]) {
    __weak UIView *weakNew = view;
    dispatch_async(dispatch_get_main_queue(), ^{ twab_collapseChannelBar(weakNew); });
  }
  if (twab_shouldRemoveTestID(identifier)) {
    objc_setAssociatedObject(view, &twab_declutterHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.hidden = YES;
    __weak UIView *weakView = view;
    dispatch_async(dispatch_get_main_queue(), ^{
      UIView *v = weakView;
      if (v) [v removeFromSuperview];
    });
    os_log(OS_LOG_DEFAULT, "[TWAB-Hide] removed %{public}@", identifier);
  } else if (twab_shouldHideTestID(identifier) && twab_isSafeChatButton(view, identifier)) {
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
  // A wide emote's slot can widen after its image was laid out.
  if ([view.accessibilityIdentifier hasPrefix:@"chat-emote-wrapper-"]) {
    static Class imgCls;
    if (!imgCls) imgCls = objc_getClass("RCTImageComponentView");
    for (UIView *sub in view.subviews)
      if ([sub isKindOfClass:imgCls]) twab_scaleEmoteIfNeeded(sub);
  }
  NSString *testID = view.accessibilityIdentifier;
  // Layout can reset `hidden` from React Native's own display value. A chat
  // button that has grown into more than a button (or now holds the text
  // field) is shown again instead.
  if (objc_getAssociatedObject(view, &twab_declutterHiddenKey)) {
    if (twab_isSafeChatButton(view, testID)) {
      view.hidden = YES;
    } else {
      twab_restoreDecluttered(view);
      os_log(OS_LOG_DEFAULT, "[TWAB-Hide] %{public}@ is not just a button here, left visible", testID);
    }
  }
  if ([testID isEqualToString:@"feed-recaps-shelf-absorb"] && [tweakDefaults boolForKey:TWABKeyHideRecapsBar]) {
    __weak UIView *weakShelf = view;
    dispatch_async(dispatch_get_main_queue(), ^{
      UIView *shelf = weakShelf;
      if (shelf) twab_shiftFeedRows(shelf, shelf.bounds.size.height);
    });
  }
  if (([testID isEqualToString:@"stage-inflow-metadata"] ||
       [testID isEqualToString:@"chat-message-region"] ||
       [testID isEqualToString:@"chat-message-list"] ||
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
// Live page category chips fade by opacity props (see twab_chipsPropsUpdated).
- (void)updateProps:(const void *)props oldProps:(const void *)oldProps {
  %orig;
  UIView *view = (UIView *)self;
  if ([view.accessibilityIdentifier isEqualToString:@"subfeed-chips-visibility"] &&
      [tweakDefaults boolForKey:TWABKeyHideRecapsBar] && view.layer.opacity < 0.05) {
    __weak UIView *weakChips = view;
    dispatch_async(dispatch_get_main_queue(), ^{
      UIView *chips = weakChips;
      if (chips) twab_chipsPropsUpdated(chips);
    });
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
  if ([recycledID isEqualToString:@"chat-message-list"]) {
    for (UIView *sub in ((UIView *)self).subviews) {
      if (!objc_getAssociatedObject(sub, &twab_scrollMaskKey)) continue;
      sub.layer.mask = nil;
      objc_setAssociatedObject(sub, &twab_scrollMaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
  if (twab_isPanelOnlyTestID(recycledID)) ((UIView *)self).hidden = NO;
  %orig;
}
%end

// Stream Rewind: the Eppo flags, added to the flag overrides the native app
// hands React Native at start-up (eppoFlagOverrides, a JSON object as a
// string, read by parseHostFlagOverrides in AppCore). Whatever is already
// there is kept.
static NSDictionary *twab_dvrInjectProps(NSDictionary *props, NSString *module, const char *site) {
  if (![props isKindOfClass:NSDictionary.class] || ![tweakDefaults boolForKey:TWABKeyStreamRewind]) return props;
  id cur = props[@"eppoFlagOverrides"];
  if (!cur && !props[@"clientId"] && !props[@"appVersion"]) return props;
  NSMutableDictionary *flags = [NSMutableDictionary dictionary];
  if ([cur isKindOfClass:NSString.class] && [(NSString *)cur length]) {
    id parsed = [NSJSONSerialization JSONObjectWithData:[(NSString *)cur dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0 error:nil];
    if ([parsed isKindOfClass:NSDictionary.class]) [flags addEntriesFromDictionary:parsed];
  } else if ([cur isKindOfClass:NSDictionary.class]) {
    [flags addEntriesFromDictionary:cur];
  }
  if ([flags[@"savvy-v2-ultralight"] isEqual:@YES] && [flags[@"savvy-double-tap-ultralight"] isEqual:@YES]) {
    if (cur && ![cur isKindOfClass:NSDictionary.class] && ![props[@"twabRewind"] boolValue])
      os_log(OS_LOG_DEFAULT, "[TWAB-Rewind] Twitch already turns the rewind flags on itself (%{public}@)", module ?: @"?");
    return props;  // already on
  }
  flags[@"savvy-v2-ultralight"] = @YES;
  flags[@"savvy-double-tap-ultralight"] = @YES;
  NSData *json = [NSJSONSerialization dataWithJSONObject:flags options:0 error:nil];
  NSMutableDictionary *out = [props mutableCopy];
  out[@"twabRewind"] = @YES;  // marks the overrides as ours
  out[@"eppoFlagOverrides"] = [cur isKindOfClass:NSDictionary.class]
      ? flags : ([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"{}");
  os_log(OS_LOG_DEFAULT, "[TWAB-Rewind] flags on for %{public}@ (%{public}s)", module ?: @"?", site);
  return out;
}

%hook RCTHost
- (id)createSurfaceWithModuleName:(NSString *)moduleName mode:(int)mode initialProperties:(NSDictionary *)properties {
  return %orig(moduleName, mode, twab_dvrInjectProps(properties, moduleName, "host"));
}
- (id)createSurfaceWithModuleName:(NSString *)moduleName initialProperties:(NSDictionary *)properties {
  return %orig(moduleName, twab_dvrInjectProps(properties, moduleName, "host2"));
}
%end

%hook RCTFabricSurface
- (id)initWithSurfacePresenter:(id)presenter moduleName:(NSString *)moduleName initialProperties:(NSDictionary *)properties {
  return %orig(presenter, moduleName, twab_dvrInjectProps(properties, moduleName, "surface"));
}
- (void)setProperties:(NSDictionary *)properties {
  %orig(twab_dvrInjectProps(properties, nil, "setProperties"));
}
%end

%hook RCTSurfaceHostingProxyRootView
- (void)setAppProperties:(NSDictionary *)properties {
  %orig(twab_dvrInjectProps(properties, nil, "appProperties"));
}
%end

%hook RCTEnhancedScrollView
// Hide "From Channels You Follow": Twitch scrolling the feed to its top (e.g. on a new
// category) stops below the bar's space. Finger drags and bounces are left alone.
- (void)setContentOffset:(CGPoint)offset {
  UIScrollView *scroll = (UIScrollView *)self;
  CGFloat top = [objc_getAssociatedObject(self, &twab_feedTopKey) doubleValue];
  BOOL held = top > 0 && offset.y < top && !scroll.tracking && !scroll.dragging && !scroll.decelerating;
  if (held) offset.y = top;
  %orig(offset);
}
// Hide Channel Bar: drags in the space above the message list still scroll it.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  return %orig || twab_pointInExtendedTop((UIView *)self, point);
}
// Hide Channel Bar: keep the message mask in place as the chat scrolls.
- (void)layoutSubviews {
  %orig;
  twab_updateScrollMask((UIScrollView *)self);
}
%end

// ─── Emote scaling ──────────────────────────────────────────────────────────
// RCTImageComponentView emote scaling. Only scale images larger than badge
// size (~18pt) so subscriber/VIP/mod badges stay at their normal size.

extern CGFloat twab_wideRatioForEmoteId(NSString *fakeId);
static char twab_wideOrigKey;

// Chat emote images carry testID "chat-emote-<id>" inside a wrapper with
// "chat-emote-wrapper-<id>".
static NSString *twab_chatEmoteId(UIView *view) {
  UIView *v = view;
  for (int k = 0; k < 3 && v; k++, v = v.superview) {
    NSString *aid = v.accessibilityIdentifier;
    if ([aid hasPrefix:@"chat-emote-wrapper-"]) return [aid substringFromIndex:19];
    if ([aid hasPrefix:@"chat-emote-"] && ![aid hasPrefix:@"chat-emote-press-"])
      return [aid substringFromIndex:11];
  }
  return nil;
}

// The text layout leaves a slot h*ratio wide for a wide emote (see
// twab_widenMarkedAttachments) but the view stays h×h at the slot's left
// edge. Grow it to a (h*ratio)-sided square centred on the line: the image
// is padded to square, so its visible part exactly fills the slot.
static void twab_restoreWideEmote(UIView *view) {
  NSArray *orig = objc_getAssociatedObject(view, &twab_wideOrigKey);
  if (!orig) return;
  objc_setAssociatedObject(view, &twab_wideOrigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  view.bounds = [orig[0] CGRectValue];
  view.center = [orig[1] CGPointValue];
  for (UIView *sub in view.subviews)
    if ([sub isKindOfClass:[UIImageView class]]) sub.frame = view.bounds;
}

static void twab_layoutWideEmote(UIView *view) {
  CGFloat q = twab_wideRatioForEmoteId(twab_chatEmoteId(view));
  NSArray *orig = objc_getAssociatedObject(view, &twab_wideOrigKey);
  CGFloat h = orig ? [orig[0] CGRectValue].size.height : view.bounds.size.height;
  // Only grow into a slot the text layout actually widened; otherwise the
  // emote would cover its neighbours.
  CGFloat slotW = view.superview.bounds.size.width;
  if (q <= 0 || h < 10 || h > 80 || slotW < h * 1.15) {
    twab_restoreWideEmote(view);
    return;
  }
  if (!orig) {
    orig = @[[NSValue valueWithCGRect:view.bounds], [NSValue valueWithCGPoint:view.center]];
    objc_setAssociatedObject(view, &twab_wideOrigKey, orig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  CGPoint oc = [orig[1] CGPointValue];
  CGFloat w = round(slotW);
  CGRect b = CGRectMake(0, 0, w, w);
  CGPoint c = CGPointMake(oc.x - h / 2.0 + w / 2.0, oc.y);
  if (!CGRectEqualToRect(view.bounds, b)) view.bounds = b;
  if (!CGPointEqualToPoint(view.center, c)) view.center = c;
  for (UIView *sub in view.subviews) {
    if (![sub isKindOfClass:[UIImageView class]]) continue;
    if (!CGRectEqualToRect(sub.frame, b)) sub.frame = b;
    sub.contentMode = UIViewContentModeScaleAspectFit;
    // The image view carries a mask sized to the original square, which
    // would crop the grown image to its top-left corner.
    CALayer *mask = sub.layer.mask;
    if ([mask isKindOfClass:[CAShapeLayer class]]) {
      sub.layer.mask = nil;
    } else if (mask && !CGRectEqualToRect(mask.frame, sub.layer.bounds)) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      mask.frame = sub.layer.bounds;
      [CATransaction commit];
    }
  }
  twab_unclipToChatList(view);
}

static void twab_scaleEmoteIfNeeded(UIView *view) {
  twab_layoutWideEmote(view);
  if (!view.window) return;
  CGFloat totalScale = twab_emoteScale();
  if (fabs(totalScale - 1.0) < 0.01) {
    view.transform = CGAffineTransformIdentity;
    return;
  }
  CGSize sz = view.bounds.size;
  if (sz.width < 20 || sz.height < 20) return;
  if (!twab_isInsideChatMessageList(view)) return;
  view.transform = CGAffineTransformMakeScale(totalScale, totalScale);
  twab_unclipToChatList(view);
}

%hook RCTImageComponentView
- (void)didMoveToWindow {
  %orig;
  twab_scaleEmoteIfNeeded((UIView *)self);
}
- (void)updateLayoutMetrics:(const void *)layoutMetrics oldLayoutMetrics:(const void *)oldLayoutMetrics {
  twab_restoreWideEmote((UIView *)self);
  %orig;
  twab_scaleEmoteIfNeeded((UIView *)self);
}
- (void)updateProps:(const void *)props oldProps:(const void *)oldProps {
  %orig;
  twab_scaleEmoteIfNeeded((UIView *)self);
}
- (void)updateState:(const void *)state oldState:(const void *)oldState {
  %orig;
  twab_scaleEmoteIfNeeded((UIView *)self);
}
- (void)layoutSubviews {
  %orig;
  twab_scaleEmoteIfNeeded((UIView *)self);
}
- (void)prepareForRecycle {
  UIView *v = (UIView *)self;
  v.transform = CGAffineTransformIdentity;
  twab_restoreWideEmote(v);
  %orig;
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

// Block update prompt (TWAppUpdatePrompt on ≤31.x, Swift VC on 32.x+)

%hook TWAppUpdatePrompt
+ (void)startMonitoringSavantSettingsToShowPromptIfNeeded {
}
%end

%hook _TtC6Twitch29AppUpdatePromptViewController
- (void)viewDidLoad {
  %orig;
  [(UIViewController *)self dismissViewControllerAnimated:NO completion:nil];
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

static __weak UITabBarController *twab_tabBarController;
static UIViewController *twab_removedCreateVC;  // kept so the tab can come back live

// "+" tab, applied live from settings: removed by setting the tabs again
// (the hook below drops it), or put back where it was.
static void twab_applyCreateTabNow(void) {
  UITabBarController *tbc = twab_tabBarController;
  if (!tbc) return;
  NSArray<UIViewController *> *vcs = tbc.viewControllers;
  if ([tweakDefaults boolForKey:TWABKeyHideCreateTab]) {
    Class createCls = objc_getClass("_TtC6Twitch16CreateTabBarItem");
    BOOL present = NO;
    for (UIViewController *vc in vcs) if (createCls && [vc.tabBarItem isKindOfClass:createCls]) present = YES;
    if (present) [tbc setViewControllers:vcs animated:NO];
  } else if (twab_removedCreateVC && ![vcs containsObject:twab_removedCreateVC]) {
    NSMutableArray *restored = [vcs mutableCopy];
    NSUInteger at = twab_removedTabIndex >= 0 ? MIN((NSUInteger)twab_removedTabIndex, restored.count)
                                              : restored.count;
    [restored insertObject:twab_removedCreateVC atIndex:at];
    twab_removedTabIndex = -1;
    twab_removedCreateVC = nil;
    [tbc setViewControllers:restored animated:NO];
    os_log(OS_LOG_DEFAULT, "[TWAB-Declutter] put the Create tab back (position %lu)", (unsigned long)at);
  }
}

// Called by the settings screen after a declutter switch changes.
void twab_applySettingsLive(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    twab_applyDeclutterNow();
    twab_applyCreateTabNow();
  });
}

%hook _TtC6Twitch16TabBarController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    twab_tabBarController = (UITabBarController *)self;
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
            twab_removedCreateVC = vcs[i];
            twab_tabBarController = (UITabBarController *)self;
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

static BOOL twab_applyHomeSubTab(id self, NSString *when) {
    static BOOL userSwiped = NO;
    static BOOL applied = NO;
    if (userSwiped || applied) return YES;
    if (![tweakDefaults objectForKey:TWABKeyLaunchSubTab]) return YES;
    if ([tweakDefaults integerForKey:TWABKeyLaunchTab] != 0) return YES;
    NSInteger sub = [tweakDefaults integerForKey:TWABKeyLaunchSubTab];
    if (sub < 0) return YES;

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

    applied = YES;
    SEL sel = @selector(selectViewControllerAtIndex:animated:);
    if ([self respondsToSelector:sel]) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Launch] homeSubTab via selectVC:%ld at %{public}@", (long)sub, when);
        ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(self, sel, sub, YES);
    } else {
        // RN Fabric (32.x+): wire delegate and simulate a full swipe sequence
        // so RN updates its internal page state and touch responders.
        UIView *wrapper = sv.superview;
        if (!sv.delegate && [wrapper conformsToProtocol:@protocol(UIScrollViewDelegate)])
            sv.delegate = (id<UIScrollViewDelegate>)wrapper;
        id<UIScrollViewDelegate> d = sv.delegate;
        os_log(OS_LOG_DEFAULT, "[TWAB-Launch] homeSubTab via simulated swipe at %{public}@", when);
        CGPoint dest = CGPointMake(desired, 0);
        if (d && [d respondsToSelector:@selector(scrollViewWillBeginDragging:)])
            [d scrollViewWillBeginDragging:sv];
        [sv setContentOffset:dest animated:NO];
        if (d) {
            if ([d respondsToSelector:@selector(scrollViewDidScroll:)])
                [d scrollViewDidScroll:sv];
            if ([d respondsToSelector:@selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)]) {
                CGPoint t = dest;
                [d scrollViewWillEndDragging:sv withVelocity:CGPointZero targetContentOffset:&t];
            }
            if ([d respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)])
                [d scrollViewDidEndDragging:sv willDecelerate:YES];
            if ([d respondsToSelector:@selector(scrollViewDidEndDecelerating:)])
                [d scrollViewDidEndDecelerating:sv];
        }
    }
    return YES;
}

// Home sub-tab: hook both old and new class names for version compat.
// 31.7-: DiscoveryFeedTabViewController; 31.9+: DiscoveryFeedRNContainerViewController.
static void twab_homeSubTabLayout(id self) {
    twab_handleAdFree();
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

%hook _TtC6Twitch30DiscoveryFeedTabViewController
- (void)viewDidLayoutSubviews {
    %orig;
    twab_homeSubTabLayout(self);
}
%end

%hook _TtC6Twitch38DiscoveryFeedRNContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    twab_homeSubTabLayout(self);
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
  // React Native views lay out by frame: pinning one to zero size with
  // constraints breaks the page around it (the 32.2 profile page's "Try
  // Ad-Free" exposes that title). Those buttons are removed through Twitch's
  // data instead (ChannelProfileShell, TurboUpsellButton).
  if ([cls hasPrefix:@"RCT"]) {
    for (UIView *sub in [root.subviews copy]) twab_scanForAdFree(sub);
    return;
  }
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


// Logs a hooked Twitch class that's missing from this Twitch version. Twitch
// renames Swift classes between versions and Logos silently skips a %hook
// whose class is gone, so this is the signal that a feature needs updating.
static void twab_checkClass(const char *name) {
  if (!objc_getClass(name)) {
    os_log_error(OS_LOG_DEFAULT,
        "[TWAB] missing hook target: %{public}s (Twitch likely renamed it)",
        name);
  }
}


%ctor {
  // Ping proxies early so the first stream usually has a verdict to use, and
  // start the background health checks that pick between them.
  dispatch_async(dispatch_get_main_queue(), ^{
    twab_remoteProxiesStart();
    twab_proxyPoolStart();
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
  if (![tweakDefaults objectForKey:TWABKeyBlockTracking])
    [tweakDefaults setBool:YES forKey:TWABKeyBlockTracking];
  // Saved values of settings that were removed.
  for (NSString *gone in @[@"TWDismissPinnedSeconds", @"TWHighlightDeletedNotes", @"TWFitWideEmotes"])
    if ([tweakDefaults objectForKey:gone]) [tweakDefaults removeObjectForKey:gone];
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
  twab_checkClass("_TtC6Twitch29AppUpdatePromptViewController");
  twab_checkClass("_TtC6Twitch16TabBarController");
  twab_checkClass("_TtC6Twitch20BrowseViewController");
  twab_checkClass("_TtC6Twitch30DiscoveryFeedTabViewController");
  twab_checkClass("_TtC6Twitch38DiscoveryFeedRNContainerViewController");
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
  if (!urlClientPresent) {
    os_log_error(OS_LOG_DEFAULT,
        "[TWAB] missing hook target: neither TKURLSessionClient nor Apollo.URLSessionClient");
  }
}
