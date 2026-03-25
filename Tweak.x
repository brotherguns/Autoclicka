#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define SPOOF_CREDITS 99999

// Recursively patch any dict/array coming out of JSON that has a "credits" key
static id patchCredits(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [((NSDictionary *)obj) mutableCopy];
        if (d[@"credits"] != nil) {
            d[@"credits"] = @(SPOOF_CREDITS);
        }
        for (NSString *key in [d allKeys]) {
            d[key] = patchCredits(d[key]);
        }
        return [d copy];
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [((NSArray *)obj) mutableCopy];
        for (NSUInteger i = 0; i < a.count; i++) {
            a[i] = patchCredits(a[i]);
        }
        return [a copy];
    }
    return obj;
}

%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id result = %orig(data, opt, error);
    if (result) {
        result = patchCredits(result);
    }
    return result;
}

%end


// Keep Tapjoy hooks for the credit meter display
@interface TJCurrency : NSObject
@property (nonatomic, assign) NSInteger balance;
@end

@interface TJCCurrencyManager : NSObject
- (NSInteger)getCurrencyBalance;
- (NSInteger)getBalanceForCurrencyId:(NSString *)currencyId;
@end

%hook TJCurrency
- (NSInteger)balance { return SPOOF_CREDITS; }
%end

%hook TJCCurrencyManager
- (NSInteger)getCurrencyBalance { return SPOOF_CREDITS; }
- (NSInteger)getBalanceForCurrencyId:(NSString *)currencyId { return SPOOF_CREDITS; }
%end
