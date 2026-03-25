#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <StoreKit/StoreKit.h>

// ── Logger — saves to app's own Documents (visible in Files app) ──────────────

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


// ── WKWebView — log JS evaluated and intercept restore button ─────────────────

%hook WKWebView

- (void)evaluateJavaScript:(NSString *)js completionHandler:(void (^)(id, NSError *))completion {
    dumpToFile([NSString stringWithFormat:@"[JS->WEB] %@", js]);
    %orig;
}

%end


// ── JS->Swift bridge — log all messages from the WebView ─────────────────────

%hook NSObject

- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    dumpToFile([NSString stringWithFormat:
        @"[WEB->SWIFT] name=%@ body=%@", message.name, message.body]);
    %orig;
}

%end


// ── SKPaymentQueue — log restore calls and fake success ───────────────────────

%hook SKPaymentQueue

- (void)restoreCompletedTransactions {
    dumpToFile(@"[STOREKIT] restoreCompletedTransactions called");
    %orig;
}

- (void)restoreCompletedTransactionsWithApplicationUsername:(NSString *)username {
    dumpToFile([NSString stringWithFormat:@"[STOREKIT] restoreCompletedTransactionsWithApplicationUsername: %@", username]);
    %orig;
}

%end


// ── SKPaymentTransactionObserver — log all transaction updates ────────────────

%hook NSObject

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {
    for (SKPaymentTransaction *tx in transactions) {
        dumpToFile([NSString stringWithFormat:
            @"[STOREKIT TX] productID=%@ state=%ld error=%@",
            tx.payment.productIdentifier,
            (long)tx.transactionState,
            tx.error.localizedDescription ?: @"none"]);
    }
    %orig;
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
    dumpToFile([NSString stringWithFormat:@"[STOREKIT RESTORE FAILED] %@", error]);
    %orig;
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue {
    dumpToFile(@"[STOREKIT RESTORE FINISHED]");
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
