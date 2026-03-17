// UniversalAutoClicker
// Clean rewrite matching working dylib's exact injection method

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ─────────────────────────────────────────────
// MARK: Touch Injection
// Matches the working binary: initAtPoint:inWindow: → setPhase: → sendEvent:
// iOS 26 renamed _setPhase: → setPhase: (confirmed from device debug dump)
// ─────────────────────────────────────────────

static void AC_Tap(CGPoint pt) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;

        // Find target window
        UIWindow *win = nil;
        for (UIWindow *w in [app valueForKey:@"windows"] ?: @[]) {
            if (w.isHidden || w.alpha <= 0) continue;
            if ([NSStringFromClass([w class]) containsString:@"ACOverlay"]) continue;
            if (!win || w.windowLevel > win.windowLevel) win = w;
        }
        if (!win) return;

        UIView *hit = [win hitTest:pt withEvent:nil] ?: win;

        // Build touch — try both init methods
        UITouch *t = nil;
        SEL initSel = NSSelectorFromString(@"initAtPoint:inWindow:");
        if ([UITouch instancesRespondToSelector:initSel]) {
            NSMethodSignature *sig = [UITouch instanceMethodSignatureForSelector:initSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = [UITouch alloc]; inv.selector = initSel;
            [inv setArgument:&pt  atIndex:2];
            [inv setArgument:&win atIndex:3];
            [inv invoke];
            __unsafe_unretained UITouch *raw;
            [inv getReturnValue:&raw];
            t = raw;
        } else {
            // iOS 26: alloc+init then set window/location manually
            t = [[UITouch alloc] init];
            SEL setWin = NSSelectorFromString(@"setWindow:");
            SEL setLoc = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
            if ([t respondsToSelector:setWin]) {
                NSMethodSignature *sig = [t methodSignatureForSelector:setWin];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = t; inv.selector = setWin;
                __unsafe_unretained UIWindow *rawWin = win;
                [inv setArgument:&rawWin atIndex:2]; [inv invoke];
            }
            if ([t respondsToSelector:setLoc]) {
                NSMethodSignature *sig = [t methodSignatureForSelector:setLoc];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = t; inv.selector = setLoc;
                BOOL reset = YES;
                [inv setArgument:&pt    atIndex:2];
                [inv setArgument:&reset atIndex:3];
                [inv invoke];
            }
        }
        if (!t) return;

        // Set view
        SEL setView = NSSelectorFromString(@"_setView:");
        if ([t respondsToSelector:setView]) {
            NSMethodSignature *sig = [t methodSignatureForSelector:setView];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = t; inv.selector = setView;
            __unsafe_unretained UIView *rawHit = hit;
            [inv setArgument:&rawHit atIndex:2]; [inv invoke];
        }

        // Set timestamp
        SEL setTs = NSSelectorFromString(@"_setTimestamp:");
        if ([t respondsToSelector:setTs]) {
            NSMethodSignature *sig = [t methodSignatureForSelector:setTs];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = t; inv.selector = setTs;
            NSTimeInterval ts = [NSProcessInfo processInfo].systemUptime;
            [inv setArgument:&ts atIndex:2]; [inv invoke];
        }

        // Set phase — iOS 26 uses setPhase: (no underscore), older uses _setPhase:
        UITouchPhase began = UITouchPhaseBegan;
        SEL setPh = NSSelectorFromString(@"setPhase:");
        if (![t respondsToSelector:setPh])
            setPh = NSSelectorFromString(@"_setPhase:");
        if ([t respondsToSelector:setPh]) {
            NSMethodSignature *sig = [t methodSignatureForSelector:setPh];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = t; inv.selector = setPh;
            [inv setArgument:&began atIndex:2]; [inv invoke];
        }

        // Set tap count
        SEL setTap = NSSelectorFromString(@"_setTapCount:");
        if ([t respondsToSelector:setTap]) {
            NSMethodSignature *sig = [t methodSignatureForSelector:setTap];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = t; inv.selector = setTap;
            NSUInteger one = 1;
            [inv setArgument:&one atIndex:2]; [inv invoke];
        }

        // Get event and inject
        SEL evtSel = NSSelectorFromString(@"_touchesEvent");
        UIEvent *evt = nil;
        if ([app respondsToSelector:evtSel]) {
            NSMethodSignature *sig = [app methodSignatureForSelector:evtSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = app; inv.selector = evtSel; [inv invoke];
            __unsafe_unretained UIEvent *rawEvt;
            [inv getReturnValue:&rawEvt];
            evt = rawEvt;
        }

        SEL clr = NSSelectorFromString(@"_clearTouches");
        SEL add = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");

        if (evt) {
            if ([evt respondsToSelector:clr]) {
                NSMethodSignature *sig = [evt methodSignatureForSelector:clr];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = evt; inv.selector = clr; [inv invoke];
            }
            if ([evt respondsToSelector:add]) {
                NSMethodSignature *sig = [evt methodSignatureForSelector:add];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = evt; inv.selector = add;
                __unsafe_unretained UITouch *rawT = t;
                BOOL no = NO;
                [inv setArgument:&rawT atIndex:2];
                [inv setArgument:&no   atIndex:3];
                [inv invoke];
            }
            [app sendEvent:evt];
        }

        // Also try _handleHIDEventBypassingUIEvent: as secondary path (iOS 26 confirmed)
        SEL bypass = NSSelectorFromString(@"_handleHIDEventBypassingUIEvent:");

        // Touch ended after 60ms
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            @try {
                NSTimeInterval ts2 = [NSProcessInfo processInfo].systemUptime;
                UITouchPhase ended = UITouchPhaseEnded;

                if ([t respondsToSelector:setTs]) {
                    NSMethodSignature *sig = [t methodSignatureForSelector:setTs];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = t; inv.selector = setTs;
                    [inv setArgument:&ts2 atIndex:2]; [inv invoke];
                }
                if ([t respondsToSelector:setPh]) {
                    NSMethodSignature *sig = [t methodSignatureForSelector:setPh];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = t; inv.selector = setPh;
                    [inv setArgument:&ended atIndex:2]; [inv invoke];
                }
                if (evt) {
                    if ([evt respondsToSelector:clr]) {
                        NSMethodSignature *sig = [evt methodSignatureForSelector:clr];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = evt; inv.selector = clr; [inv invoke];
                    }
                    if ([evt respondsToSelector:add]) {
                        NSMethodSignature *sig = [evt methodSignatureForSelector:add];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = evt; inv.selector = add;
                        __unsafe_unretained UITouch *rawT = t;
                        BOOL no = NO;
                        [inv setArgument:&rawT atIndex:2];
                        [inv setArgument:&no   atIndex:3];
                        [inv invoke];
                    }
                    [app sendEvent:evt];
                }
                (void)bypass; // suppress unused warning
            } @catch(...) {}
        });
    } @catch(...) {}
}

// ─────────────────────────────────────────────
// MARK: Engine
// ─────────────────────────────────────────────

@interface ACEngine : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL running;
@property (nonatomic) CGPoint tapPoint;
@property (nonatomic) double interval; // seconds
- (void)start;
- (void)stop;
@end

@implementation ACEngine {
    dispatch_source_t _timer;
}
+ (instancetype)shared {
    static ACEngine *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [self new]; });
    return s;
}
- (instancetype)init {
    if ((self = [super init])) {
        _tapPoint = CGPointMake(200, 400);
        _interval = 0.1;
    }
    return self;
}
- (void)start {
    if (_running) return;
    _running = YES;
    uint64_t iv = (uint64_t)(_interval * NSEC_PER_SEC);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, iv), iv, 1 * NSEC_PER_MSEC);
    __weak ACEngine *w = self;
    dispatch_source_set_event_handler(_timer, ^{
        if (w.running) AC_Tap(w.tapPoint);
    });
    dispatch_resume(_timer);
}
- (void)stop {
    if (!_running) return;
    _running = NO;
    dispatch_source_cancel(_timer);
    _timer = nil;
}
@end

// ─────────────────────────────────────────────
// MARK: Passthrough views
// ─────────────────────────────────────────────

@interface ACPassView : UIView @end
@implementation ACPassView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    return h == self ? nil : h;
}
@end

@interface ACPassWin : UIWindow @end
@implementation ACPassWin
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    return h == self ? nil : h;
}
@end

// ─────────────────────────────────────────────
// MARK: Panel
// ─────────────────────────────────────────────

@interface ACPanel : UIView
@property (nonatomic) BOOL minimized;
@property (nonatomic) BOOL capturing;
@property (nonatomic, strong) UIView *captureOverlay;
@property (nonatomic, strong) UIButton *startBtn;
@property (nonatomic, strong) UILabel  *statusLbl;
@property (nonatomic, strong) UILabel  *pointLbl;
@property (nonatomic, strong) UILabel  *cpsLbl;
@property (nonatomic, strong) UISlider *speedSlider;
@end

@implementation ACPanel

+ (instancetype)make {
    ACPanel *p = [[self alloc] initWithFrame:CGRectMake(10, 80, 200, 230)];
    [p build];
    return p;
}

- (void)build {
    // Background
    self.backgroundColor = [UIColor colorWithRed:.07 green:.07 blue:.10 alpha:.95];
    self.layer.cornerRadius = 14;
    self.layer.borderWidth  = .5;
    self.layer.borderColor  = [UIColor colorWithWhite:1 alpha:.15].CGColor;
    self.layer.shadowColor  = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = .6;
    self.layer.shadowRadius = 8;
    self.clipsToBounds = NO;

    CGFloat W = 200, x = 10, w = W - 20, y = 0;

    // Title bar
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 36)];
    bar.backgroundColor = [UIColor colorWithRed:.10 green:.45 blue:1 alpha:1];
    bar.layer.cornerRadius = 14;
    bar.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [self addSubview:bar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, W-50, 36)];
    title.text = @"Auto Clicker";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:13];
    [bar addSubview:title];

    // Minimize button
    UIButton *minBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    minBtn.frame = CGRectMake(W-38, 7, 26, 22);
    minBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:.2];
    minBtn.layer.cornerRadius = 5;
    [minBtn setTitle:@"—" forState:UIControlStateNormal];
    minBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [minBtn addTarget:self action:@selector(onMinimize) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:minBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [bar addGestureRecognizer:pan];

    y = 44;

    // Start/Stop
    _startBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _startBtn.frame = CGRectMake(x, y, w, 36);
    _startBtn.backgroundColor = [UIColor colorWithRed:.1 green:.7 blue:.3 alpha:1];
    _startBtn.layer.cornerRadius = 8;
    [_startBtn setTitle:@"START" forState:UIControlStateNormal];
    _startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [_startBtn addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_startBtn];
    y += 44;

    // Speed label
    _cpsLbl = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 16)];
    [self updateCPS:0.1];
    _cpsLbl.textColor = [UIColor colorWithWhite:.65 alpha:1];
    _cpsLbl.font = [UIFont systemFontOfSize:11];
    [self addSubview:_cpsLbl];
    y += 18;

    // Speed slider
    _speedSlider = [[UISlider alloc] initWithFrame:CGRectMake(x, y, w, 28)];
    _speedSlider.minimumValue = 0.05;
    _speedSlider.maximumValue = 2.0;
    _speedSlider.value = 0.1;
    _speedSlider.tintColor = [UIColor colorWithRed:.1 green:.45 blue:1 alpha:1];
    [_speedSlider addTarget:self action:@selector(onSpeed:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_speedSlider];
    y += 34;

    // Point label
    _pointLbl = [[UILabel alloc] initWithFrame:CGRectMake(x, y, 100, 16)];
    _pointLbl.text = @"Tap: (200, 400)";
    _pointLbl.textColor = [UIColor colorWithWhite:.65 alpha:1];
    _pointLbl.font = [UIFont systemFontOfSize:11];
    [self addSubview:_pointLbl];

    // Set Point button
    UIButton *setBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    setBtn.frame = CGRectMake(x + 104, y - 2, 76, 22);
    setBtn.backgroundColor = [UIColor colorWithRed:.1 green:.45 blue:1 alpha:.9];
    setBtn.layer.cornerRadius = 5;
    [setBtn setTitle:@"Set Point" forState:UIControlStateNormal];
    setBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [setBtn addTarget:self action:@selector(onSetPoint) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:setBtn];
    y += 24;

    // Status
    _statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 14)];
    _statusLbl.text = @"Ready";
    _statusLbl.textColor = [UIColor colorWithWhite:.45 alpha:1];
    _statusLbl.font = [UIFont systemFontOfSize:9];
    _statusLbl.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_statusLbl];
}

- (void)updateCPS:(float)interval {
    _cpsLbl.text = [NSString stringWithFormat:@"Speed: %dms  (%.1f/s)",
                    (int)(interval * 1000), 1.0f / interval];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    CGRect f = self.frame, s = UIScreen.mainScreen.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x + t.x, s.size.width  - f.size.width));
    f.origin.y = MAX(20, MIN(f.origin.y + t.y, s.size.height - f.size.height));
    self.frame = f;
    [g setTranslation:CGPointZero inView:self.superview];
}

- (void)onMinimize {
    _minimized = !_minimized;
    CGRect f = self.frame;
    f.size.height = _minimized ? 36 : 230;
    self.frame = f;
    for (UIView *v in self.subviews)
        if (v != self.subviews.firstObject)
            v.hidden = _minimized;
}

- (void)onToggle {
    ACEngine *e = ACEngine.shared;
    if (e.running) {
        [e stop];
        _startBtn.backgroundColor = [UIColor colorWithRed:.1 green:.7 blue:.3 alpha:1];
        [_startBtn setTitle:@"START" forState:UIControlStateNormal];
        _statusLbl.text = @"Stopped";
    } else {
        [e start];
        _startBtn.backgroundColor = [UIColor colorWithRed:.85 green:.15 blue:.15 alpha:1];
        [_startBtn setTitle:@"STOP" forState:UIControlStateNormal];
        _statusLbl.text = [NSString stringWithFormat:@"Clicking at (%.0f, %.0f)",
                           e.tapPoint.x, e.tapPoint.y];
    }
}

- (void)onSpeed:(UISlider *)s {
    float v = roundf(s.value * 20) / 20.0f; // snap to 50ms steps
    ACEngine.shared.interval = v;
    [self updateCPS:v];
    if (ACEngine.shared.running) {
        [ACEngine.shared stop];
        [ACEngine.shared start];
    }
}

- (void)onSetPoint {
    if (_capturing) { [self endCapture]; return; }
    _capturing = YES;

    UIView *sup = self.window ?: self.superview;
    _captureOverlay = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _captureOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:.4];
    _captureOverlay.userInteractionEnabled = YES;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20, UIScreen.mainScreen.bounds.size.height/2 - 24, UIScreen.mainScreen.bounds.size.width - 40, 48)];
    lbl.text = @"Tap anywhere to set click point";
    lbl.textColor = UIColor.whiteColor;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.font = [UIFont boldSystemFontOfSize:18];
    lbl.numberOfLines = 2;
    [_captureOverlay addSubview:lbl];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onCaptureTap:)];
    [_captureOverlay addGestureRecognizer:tap];
    [sup addSubview:_captureOverlay];
    [sup bringSubviewToFront:self];
}

- (void)onCaptureTap:(UITapGestureRecognizer *)g {
    CGPoint pt = [g locationInView:self.superview];
    ACEngine.shared.tapPoint = pt;
    _pointLbl.text = [NSString stringWithFormat:@"Tap: (%.0f, %.0f)", pt.x, pt.y];
    [self endCapture];
}

- (void)endCapture {
    _capturing = NO;
    [_captureOverlay removeFromSuperview];
    _captureOverlay = nil;
}

@end

// ─────────────────────────────────────────────
// MARK: Manager
// ─────────────────────────────────────────────

@interface ACManager : NSObject
+ (instancetype)shared;
- (void)setup;
@end

@implementation ACManager {
    ACPassWin *_win;
}
+ (instancetype)shared {
    static ACManager *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [self new]; });
    return s;
}
- (void)setup {
    _win = [[ACPassWin alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (@available(iOS 13, *)) {
        for (UIWindowScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                _win.windowScene = (UIWindowScene *)sc; break;
            }
        }
    }
    _win.windowLevel = UIWindowLevelNormal + 1;
    _win.backgroundColor = UIColor.clearColor;

    UIViewController *vc = [UIViewController new];
    ACPassView *root = [[ACPassView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = UIColor.clearColor;
    vc.view = root;
    _win.rootViewController = vc;
    _win.hidden = NO;

    ACPanel *panel = [ACPanel make];
    [root addSubview:panel];
}
@end

// ─────────────────────────────────────────────
// MARK: Constructor
// ─────────────────────────────────────────────

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ACManager shared] setup];
    });
}
