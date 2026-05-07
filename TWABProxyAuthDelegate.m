#import "TWABProxyAuthDelegate.h"

@implementation TWABProxyAuthDelegate

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))ch {
    if (challenge.protectionSpace.isProxy && self.proxyUser.length) {
        ch(NSURLSessionAuthChallengeUseCredential,
           [NSURLCredential credentialWithUser:self.proxyUser
                                      password:self.proxyPass ?: @""
                                   persistence:NSURLCredentialPersistenceForSession]);
        return;
    }
    if ([self.inner respondsToSelector:@selector(URLSession:didReceiveChallenge:completionHandler:)]) {
        [self.inner URLSession:session didReceiveChallenge:challenge completionHandler:ch];
    } else {
        ch(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))ch {
    [self URLSession:session didReceiveChallenge:challenge completionHandler:ch];
}

// Forward all other NSURLSessionDelegate/DataDelegate/DownloadDelegate calls to inner.
- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.inner respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    if ([self.inner respondsToSelector:sel]) return self.inner;
    return nil;
}

@end
