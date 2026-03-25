#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <StoreKit/StoreKit.h>

// ── Logger ───────────────────────────────────────────────────────────────────

static NSString *logPath() {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:@"unlockr_dump.txt"];
}

static void dumpToFile(NSString *entry) {
    NSString *line = [NSString stringWithFormat:@"%@\n---\n", entry];
    NSString *path = logPath();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ── DCAppAttestService — bypass App Attest entirely ───────────────────────────
// The patched IPA fails Apple's attestation check, blocking all API calls.
// We fake the entire flow so the app thinks attestation succeeded.

@interface DCAppAttestService : NSObject
+ (instancetype)sharedService;
- (BOOL)isSupported;
- (void)generateKeyWithCompletionHandler:(void (^)(NSString *keyID, NSError *error))completionHandler;
- (void)attestKey:(NSString *)keyID clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *attestationObject, NSError *error))completionHandler;
- (void)generateAssertion:(NSString *)keyID clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *assertionObject, NSError *error))completionHandler;
@end

%hook DCAppAttestService

- (BOOL)isSupported {
    dumpToFile(@"[ATTEST] isSupported -> spoofed YES");
    return YES;
}

- (void)generateKeyWithCompletionHandler:(void (^)(NSString *, NSError *))completionHandler {
    dumpToFile(@"[ATTEST] generateKey -> spoofing fake keyID");
    // Return a fake key ID — the app stores this in UserDefaults as attestationKey
    if (completionHandler) completionHandler(@"fakekeyid-unlockr-bypass-0000", nil);
}

- (void)attestKey:(NSString *)keyID clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *, NSError *))completionHandler {
    dumpToFile([NSString stringWithFormat:@"[ATTEST] attestKey: %@  -> spoofing fake attestation object", keyID]);
    // Return fake non-nil attestation data so the app proceeds
    NSData *fakeAttestation = [@"fakeAttestation" dataUsingEncoding:NSUTF8StringEncoding];
    if (completionHandler) completionHandler(fakeAttestation, nil);
}

- (void)generateAssertion:(NSString *)keyID clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *, NSError *))completionHandler {
    dumpToFile([NSString stringWithFormat:@"[ATTEST] generateAssertion: %@ -> spoofing fake assertion", keyID]);
    NSData *fakeAssertion = [@"fakeAssertion" dataUsingEncoding:NSUTF8StringEncoding];
    if (completionHandler) completionHandler(fakeAssertion, nil);
}

%end


// ── NSURLSession — log ALL requests and responses ────────────────────────────

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                           completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *url = request.URL.absoluteString;
    NSString *method = request.HTTPMethod ?: @"GET";
    NSString *reqBody = @"(none)";
    if (request.HTTPBody) {
        reqBody = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] ?: @"(binary)";
    }
    dumpToFile([NSString stringWithFormat:@"[REQUEST] %@ %@\nHeaders: %@\nBody: %@",
        method, url, request.allHTTPHeaderFields, reqBody]);

    if (!completionHandler) return %orig;

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *responseData, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSString *body = responseData
                ? ([[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] ?: @"(binary)")
                : @"(none)";
            dumpToFile([NSString stringWithFormat:@"[RESPONSE] %@ -> HTTP %ld\nBody: %@",
                url, (long)http.statusCode, body]);
            if (error) dumpToFile([NSString stringWithFormat:@"[ERROR] %@: %@", url, error]);
            completionHandler(responseData, response, error);
        };
    return %orig(request, wrappedHandler);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    dumpToFile([NSString stringWithFormat:@"[REQUEST GET] %@", url.absoluteString]);
    if (!completionHandler) return %orig;
    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *responseData, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSString *body = responseData
                ? ([[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] ?: @"(binary)")
                : @"(none)";
            dumpToFile([NSString stringWithFormat:@"[RESPONSE] %@ -> HTTP %ld\nBody: %@",
                url.absoluteString, (long)http.statusCode, body]);
            if (error) dumpToFile([NSString stringWithFormat:@"[ERROR] %@: %@", url, error]);
            completionHandler(responseData, response, error);
        };
    return %orig(url, wrappedHandler);
}

%end


// ── WKWebView JS bridge ───────────────────────────────────────────────────────

%hook WKWebView
- (void)evaluateJavaScript:(NSString *)js completionHandler:(void (^)(id, NSError *))completion {
    if ([js length] < 500) {
        dumpToFile([NSString stringWithFormat:@"[JS->WEB] %@", js]);
    }
    %orig;
}
%end

%hook NSObject
- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    dumpToFile([NSString stringWithFormat:@"[WEB->SWIFT] name=%@ body=%@", message.name, message.body]);
    %orig;
}
%end

