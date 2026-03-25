#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// ── Helpers ──────────────────────────────────────────────────────────────────

static id patchJSON(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [((NSDictionary *)obj) mutableCopy];
        // Patch subscription/premium fields
        if (d[@"isSubscribed"] != nil)  d[@"isSubscribed"]  = @YES;
        if (d[@"isPremium"] != nil)     d[@"isPremium"]     = @YES;
        if (d[@"premium"] != nil)       d[@"premium"]       = @YES;
        if (d[@"subscribed"] != nil)    d[@"subscribed"]    = @YES;
        if (d[@"credits"] != nil)       d[@"credits"]       = @99999;
        if (d[@"redeemPrice"] != nil)   d[@"redeemPrice"]   = @0;
        for (NSString *key in [d allKeys]) {
            d[key] = patchJSON(d[key]);
        }
        return [d copy];
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [((NSArray *)obj) mutableCopy];
        for (NSUInteger i = 0; i < a.count; i++) {
            a[i] = patchJSON(a[i]);
        }
        return [a copy];
    }
    return obj;
}

// ── NSJSONSerialization — patches all parsed JSON ────────────────────────────

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig(data, opt, error);
    if (result) result = patchJSON(result);
    return result;
}

%end


// ── NSURLSession — patch responses from the unlockr server ───────────────────
// Catches the async server response before NSJSONSerialization even runs,
// in case the app uses a streaming/manual JSON parse path.

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                           completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!completionHandler) return %orig;

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSData *patchedData = data;
            if (data && !error) {
                NSError *jsonError = nil;
                id obj = [NSJSONSerialization JSONObjectWithData:data
                                                        options:NSJSONReadingMutableContainers
                                                          error:&jsonError];
                if (obj && !jsonError) {
                    id patched = patchJSON(obj);
                    NSData *reencoded = [NSJSONSerialization dataWithJSONObject:patched
                                                                        options:0
                                                                          error:nil];
                    if (reencoded) patchedData = reencoded;
                }
            }
            completionHandler(patchedData, response, error);
        };

    return %orig(request, wrappedHandler);
}

%end


// ── WKWebView JS bridge — intercept getIsSubscribed replies ──────────────────
// When the JS layer asks Swift "are you subscribed?", Swift calls
// evaluateJavaScript to post the reply back. We intercept outgoing JS
// calls and inject isSubscribed=true into any reply payload.

%hook WKWebView

- (void)evaluateJavaScript:(NSString *)js completionHandler:(void (^)(id, NSError *))completion {
    // The SDK bridge posts replies as JSON strings — patch them on the fly
    if ([js containsString:@"isSubscribed"] || [js containsString:@"isPremium"]) {
        // Replace false with true in the JS string being evaluated
        NSString *patched = [js stringByReplacingOccurrencesOfString:@"\"isSubscribed\":false"
                                                          withString:@"\"isSubscribed\":true"];
        patched = [patched stringByReplacingOccurrencesOfString:@"\"isPremium\":false"
                                                     withString:@"\"isPremium\":true"];
        patched = [patched stringByReplacingOccurrencesOfString:@"\\\"isSubscribed\\\":false"
                                                     withString:@"\\\"isSubscribed\\\":true"];
        patched = [patched stringByReplacingOccurrencesOfString:@"\\\"isPremium\\\":false"
                                                     withString:@"\\\"isPremium\\\":true"];
        %orig(patched, completion);
        return;
    }
    %orig;
}

%end


// ── NSUserDefaults — catch any locally cached subscription state ──────────────

%hook NSUserDefaults

- (BOOL)boolForKey:(NSString *)key {
    if ([key containsString:@"subscri"] || [key containsString:@"Subscri"] ||
        [key containsString:@"premium"] || [key containsString:@"Premium"] ||
        [key containsString:@"isSubscribed"] || [key containsString:@"IsSubscribed"]) {
        return YES;
    }
    return %orig;
}

- (id)objectForKey:(NSString *)key {
    id val = %orig;
    // If it's a stored bool/number for subscription, override
    if ([key containsString:@"subscri"] || [key containsString:@"Subscri"] ||
        [key containsString:@"premium"] || [key containsString:@"Premium"]) {
        if (!val || [val isKindOfClass:[NSNumber class]]) {
            return @YES;
        }
    }
    return val;
}

%end
