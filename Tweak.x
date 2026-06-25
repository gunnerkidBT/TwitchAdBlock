#import <dlfcn.h>
#import <os/log.h>
#import <objc/message.h>
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

static NSData *twab_filteredFeedData(NSData *data, NSURLSessionDataTask *dataTask) {
  if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled]) return data;
  return [data twab_responseDataForRequest:dataTask.currentRequest];
}

%hook _TtC9TwitchKit18TKURLSessionClient
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  %orig(session, dataTask, twab_filteredFeedData(data, dataTask));
}
%end

// Apollo.URLSessionClient — used in Twitch 29.x+
%hook _TtC6Apollo16URLSessionClient
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  %orig(session, dataTask, twab_filteredFeedData(data, dataTask));
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
// 29.x+ (4-arg)
- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(id)themeManager
                  urlController:(_TtC6Twitch13URLController *)urlController
                   isInitialTab:(BOOL)isInitialTab {
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
%hook _TtC6Twitch16TabBarController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![tweakDefaults objectForKey:TWABKeyLaunchTab]) return;
        NSInteger idx = [tweakDefaults integerForKey:TWABKeyLaunchTab];
        UITabBarController *tbc = (UITabBarController *)self;
        if (idx >= 0 && idx < (NSInteger)tbc.viewControllers.count) {
            tbc.selectedIndex = (NSUInteger)idx;
        }
    });
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
%hook _TtC6Twitch30DiscoveryFeedTabViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (![tweakDefaults objectForKey:TWABKeyLaunchSubTab]) return;
    if ([tweakDefaults integerForKey:TWABKeyLaunchTab] != 0) return;
    NSInteger sub = [tweakDefaults integerForKey:TWABKeyLaunchSubTab];
    if (sub < 0) return;

    // Retry up to 5 layout passes — first pass may be too early (zero
    // bounds / single page), later passes may include Twitch's own scroll
    // reset that we need to override.
    static int attempts = 0;
    if (attempts >= 5) return;

    UIView *view = ((UIViewController *)self).view;
    UIScrollView *sv = twab_findPagedScrollView(view);
    if (!sv) return;
    CGFloat pageWidth = sv.bounds.size.width;
    if (pageWidth <= 0) return;
    CGFloat desired = pageWidth * (CGFloat)sub;
    CGFloat currentX = sv.contentOffset.x;
    if (fabs(currentX - desired) < 1.0) {
        attempts = INT_MAX;  // we're there, stop trying
        os_log(OS_LOG_DEFAULT,
            "[TWAB-Launch] reached desired page sub=%ld offsetX=%.0f", (long)sub, currentX);
        return;
    }

    attempts++;
    os_log(OS_LOG_DEFAULT,
        "[TWAB-Launch] attempt %d: sub=%ld pageWidth=%.0f currentX=%.0f desired=%.0f contentSize=%{public}@",
        attempts, (long)sub, pageWidth, currentX, desired,
        NSStringFromCGSize(sv.contentSize));
    [sv setContentOffset:CGPointMake(desired, 0) animated:NO];

    // Also write the internal index ivar so the top-tab indicator agrees
    // with where we just scrolled.
    Ivar iv = twab_findIvar((id)self, "selectedContentViewControllerIndex");
    if (iv) {
        NSInteger *p = (NSInteger *)((char *)(__bridge void *)self + ivar_getOffset(iv));
        *p = sub;
    }
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

// Hide the "Go Ad-Free" Turbo upsell banner on the Following tab.
// FollowingViewController owns it via the `turboUpsellView` /
// `turboUpsellViewController` ivars (confirmed in the 29.9 binary, alongside
// the "Following upsell button tapped" event). presentTurboUpsell is a
// non-@objc Swift method so it can't be hooked directly; instead we hide the
// view on each layout pass — idempotent (once hidden it short-circuits) and
// resilient to Twitch re-adding it. Mirrors the Stories-removal approach.
static void twab_collapseUpsellView(UIView *v) {
  if (!v || v.hidden) return;
  v.hidden = YES;
  static char collapsedKey;
  if (!objc_getAssociatedObject(v, &collapsedKey)) {
    NSLayoutConstraint *zero = [v.heightAnchor constraintEqualToConstant:0];
    zero.priority = UILayoutPriorityRequired;
    zero.active = YES;
    objc_setAssociatedObject(v, &collapsedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

static void twab_hideFollowingUpsell(id vc) {
  // Known banner ivar first.
  Ivar viewIv = twab_findIvar(vc, "turboUpsellView");
  if (viewIv) {
    id v = object_getIvar(vc, viewIv);
    if ([v isKindOfClass:[UIView class]]) { twab_collapseUpsellView(v); return; }
  }
  // Child-VC variant — collapse its view if it's loaded.
  Ivar vcIv = twab_findIvar(vc, "turboUpsellViewController");
  if (vcIv) {
    id child = object_getIvar(vc, vcIv);
    if ([child isKindOfClass:[UIViewController class]]) {
      UIView *cv = ((UIViewController *)child).viewIfLoaded;
      if (cv) { twab_collapseUpsellView(cv); return; }
    }
  }
  // Fallback — scan the view tree for any TurboUpsell* view.
  UIView *found = twab_findSubviewMatching(((UIViewController *)vc).view, @"TurboUpsell");
  if (found) twab_collapseUpsellView(found);
}

%hook _TtC6Twitch23FollowingViewController
- (void)viewDidLayoutSubviews {
  %orig;
  if (![tweakDefaults boolForKey:TWABKeyHideAdFreeButton]) return;
  twab_hideFollowingUpsell(self);
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
  // Either of the two URLSession client classes is enough — Twitch ships one
  // or the other per version. Record as a single combined entry.
  BOOL urlClientPresent = objc_getClass("_TtC9TwitchKit18TKURLSessionClient") ||
                          objc_getClass("_TtC6Apollo16URLSessionClient");
  [twab_diagStore() addObject:@{ @"name": @"URLSessionClient (TK or Apollo)",
                                 @"present": @(urlClientPresent) }];
  if (!urlClientPresent) {
    os_log_error(OS_LOG_DEFAULT,
        "[TWAB] missing hook target: neither TKURLSessionClient nor Apollo.URLSessionClient");
  }
}
