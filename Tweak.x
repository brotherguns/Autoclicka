#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// ── Logger ───────────────────────────────────────────────────────────────────

static void dumpToFile(NSString *entry) {
    NSString *path = @"/var/mobile/Documents/unlockr_dump.txt";
    NSString *line = [NSString stringWithFormat:@"%@\n---\n", entry];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

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

    dumpToFile([NSString stringWithFormat:
        @"[REQUEST] %@ %@\nHeaders: %@\nBody: %@",
        method, url, request.allHTTPHeaderFields, reqBody]);

    if (!completionHandler) return %orig;

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *responseData, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSString *body = @"(none)";
            if (responseData) {
                body = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] ?: @"(binary)";
            }
            dumpToFile([NSString stringWithFormat:
                @"[RESPONSE] %@ -> HTTP %ld\nBody: %@",
                url, (long)http.statusCode, body]);

            if (error) {
                dumpToFile([NSString stringWithFormat:@"[ERROR] %@: %@", url, error.localizedDescription]);
            }

            completionHandler(responseData, response, error);
        };

    return %orig(request, wrappedHandler);
}

%end


// ── WKWebView — log all JS evaluated and all messages posted to Swift ─────────

%hook WKWebView

- (void)evaluateJavaScript:(NSString *)js completionHandler:(void (^)(id, NSError *))completion {
    dumpToFile([NSString stringWithFormat:@"[JS->WEB] %@", js]);
    %orig;
}

%end


// ── WKScriptMessageHandler — log messages coming FROM the WebView TO Swift ────

@interface WKScriptMessage : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) id body;
@end

%hook NSObject

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    dumpToFile([NSString stringWithFormat:
        @"[WEB->SWIFT] name=%@ body=%@", message.name, message.body]);
    %orig;
}

%end


// ── NSUserDefaults — log all reads/writes ────────────────────────────────────

%hook NSUserDefaults

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    dumpToFile([NSString stringWithFormat:@"[DEFAULTS SET BOOL] %@ = %@", key, value ? @"YES" : @"NO"]);
    %orig;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    dumpToFile([NSString stringWithFormat:@"[DEFAULTS SET] %@ = %@", key, value]);
    %orig;
}

- (BOOL)boolForKey:(NSString *)key {
    BOOL val = %orig;
    dumpToFile([NSString stringWithFormat:@"[DEFAULTS GET BOOL] %@ = %@", key, val ? @"YES" : @"NO"]);
    return val;
}

- (id)objectForKey:(NSString *)key {
    id val = %orig;
    dumpToFile([NSString stringWithFormat:@"[DEFAULTS GET] %@ = %@", key, val]);
    return val;
}

%end
