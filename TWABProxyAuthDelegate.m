#import "TWABProxyAuthDelegate.h"
#import <objc/runtime.h>
#import <stdatomic.h>

extern void twab_checkPlaylistForAds(NSData *data, NSURLRequest *request);

// IVSPlayerURLSessionDelegate tracks requests by taskIdentifier and answers a response
// it can't find with "cancel" (-[IVSPlayerURLSessionDelegate
// URLSession:dataTask:didReceiveResponse:completionHandler:]). A proxy session numbers
// its tasks from 1, the same as the player's own session, so the first stream of a
// launch could be rejected. The player gets this stand-in instead: same task, but a
// number its own session won't reach. CFNetwork keeps using the real task.
@interface TWABPlayerTask : NSProxy {
    NSURLSessionDataTask *_task;
    NSUInteger _identifier;
}
- (instancetype)initWithTask:(NSURLSessionDataTask *)task;
@end

@implementation TWABPlayerTask
- (instancetype)initWithTask:(NSURLSessionDataTask *)task {
    static atomic_ulong next = 1UL << 40;
    _task = task;
    _identifier = atomic_fetch_add(&next, 1);
    return self;
}
- (NSUInteger)taskIdentifier { return _identifier; }
- (id)forwardingTargetForSelector:(SEL)sel { return _task; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [_task methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:_task]; }
- (BOOL)isKindOfClass:(Class)cls { return [_task isKindOfClass:cls]; }
- (BOOL)respondsToSelector:(SEL)sel { return [_task respondsToSelector:sel]; }
- (BOOL)isEqual:(id)object { return object == self || [_task isEqual:object]; }
- (NSUInteger)hash { return _task.hash; }
@end

static char twab_playerTaskKey;

NSURLSessionDataTask *twab_playerTaskForProxiedTask(NSURLSessionDataTask *task) {
    TWABPlayerTask *stand_in = [[TWABPlayerTask alloc] initWithTask:task];
    // Released when the task completes.
    objc_setAssociatedObject(task, &twab_playerTaskKey, stand_in, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return (NSURLSessionDataTask *)stand_in;
}

static id twab_taskForInner(NSURLSessionTask *task) {
    return objc_getAssociatedObject(task, &twab_playerTaskKey) ?: task;
}

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

// The callbacks the player's delegate implements, passing it the task it was given.
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))ch {
    if ([self.inner respondsToSelector:_cmd]) {
        [(id<NSURLSessionDataDelegate>)self.inner URLSession:session dataTask:twab_taskForInner(dataTask)
                                          didReceiveResponse:response completionHandler:ch];
    } else {
        ch(NSURLSessionResponseAllow);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    twab_checkPlaylistForAds(data, dataTask.currentRequest);
    if ([self.inner respondsToSelector:_cmd])
        [(id<NSURLSessionDataDelegate>)self.inner URLSession:session dataTask:twab_taskForInner(dataTask) didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
              newRequest:(NSURLRequest *)request
       completionHandler:(void (^)(NSURLRequest *))ch {
    if ([self.inner respondsToSelector:_cmd]) {
        [(id<NSURLSessionTaskDelegate>)self.inner URLSession:session task:twab_taskForInner(task)
                                  willPerformHTTPRedirection:response newRequest:request completionHandler:ch];
    } else {
        ch(request);
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if ([self.inner respondsToSelector:_cmd])
        [(id<NSURLSessionTaskDelegate>)self.inner URLSession:session task:twab_taskForInner(task) didCompleteWithError:error];
    objc_setAssociatedObject(task, &twab_playerTaskKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
