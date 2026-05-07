#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <AmazonIVSPlayer/IVSPlayer.h>
#import <AmazonIVSPlayer/IVSTextMetadataCue.h>
#import <CoreServices/LSApplicationProxy.h>
#import <Twitch/FollowingViewController.h>
#import <Twitch/HeadlinerFollowingAdManager.h>
#import <Twitch/LiveHLSURLProvider.h>
#import <Twitch/TheaterViewController.h>
#import <Twitch/URLController.h>
#import <TwitchCoreUI/TWDefaultThemeManager.h>
#import <TwitchKit/TKGraphQL.h>
#import <rootless.h>

#import "Config.h"
#import "NSData+TwitchAdBlock.h"
#import "NSURL+TwitchAdBlock.h"
#import "NSURLSession+TwitchAdBlock.h"
#import "TWAdBlockAssetResourceLoaderDelegate.h"
#import "fishhook/fishhook.h"

@interface _TtC6Twitch27AssetResourceLoaderDelegate : NSObject <AVAssetResourceLoaderDelegate>
- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest;
@end

// Returns the theme manager class, trying new name first then old name.
static inline Class TWABThemeManagerClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("_TtC12TwitchCoreUI24ConfigurableThemeManager")
           ?: objc_getClass("_TtC12TwitchCoreUI21TWDefaultThemeManager");
    });
    return cls;
}

// Returns the first available class from a nil-terminated list of ObjC class names.
static inline Class TWABFirstClass(const char *names[]) {
    for (int i = 0; names[i]; i++) {
        Class cls = objc_getClass(names[i]);
        if (cls) return cls;
    }
    return nil;
}