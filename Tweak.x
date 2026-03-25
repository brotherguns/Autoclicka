#import <UIKit/UIKit.h>

// How many credits to spoof
#define SPOOF_CREDITS 99999

// ── TJCurrency ───────────────────────────────────────────────────────────────
// Each currency object has a `balance` property. Spoofing here covers
// any codepath that reads balance off the object directly.

@interface TJCurrency : NSObject
@property (nonatomic, assign) NSInteger balance;
@property (nonatomic, assign) NSInteger lastBalanceChange;
@end

%hook TJCurrency

- (NSInteger)balance {
    return SPOOF_CREDITS;
}

- (NSInteger)lastBalanceChange {
    return 0;
}

%end


// ── TJCCurrencyManager ───────────────────────────────────────────────────────
// getCurrencyBalance is the sync getter the app polls.
// getCurrencyWithCompletion: is the async server fetch — we let it run but
// swap the balance on the returned TJCurrency before the app sees it.

@interface TJCCurrencyManager : NSObject
- (NSInteger)getCurrencyBalance;
- (NSInteger)getBalanceForCurrencyId:(NSString *)currencyId;
- (void)getCurrencyWithCompletion:(void (^)(TJCurrency *, NSError *))completion;
@end

%hook TJCCurrencyManager

- (NSInteger)getCurrencyBalance {
    return SPOOF_CREDITS;
}

- (NSInteger)getBalanceForCurrencyId:(NSString *)currencyId {
    return SPOOF_CREDITS;
}

- (void)getCurrencyWithCompletion:(void (^)(TJCurrency *, NSError *))completion {
    // Let the real call run so the SDK stays happy, but wrap the callback
    %orig(^(TJCurrency *currency, NSError *error) {
        // Force the balance before handing it to the app
        if (currency) {
            // Use KVC to bypass any readonly enforcement
            [currency setValue:@(SPOOF_CREDITS) forKey:@"balance"];
        }
        if (completion) completion(currency, error);
    });
}

%end
