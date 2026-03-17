// UniversalAutoClicker - Tweak.x
// Floating panel UI, single-point + multi-point sequence modes
// Hybrid injection: IOHIDEvent attached to UITouch via _setHIDEvent: (reverse engineered from working dylib)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

// ============================================================
// MARK: - IOHIDEvent
// ============================================================

typedef CFTypeRef IOHIDEventRef;

#define kIOHIDDigitizerEventTouch    (1 << 0)
#define kIOHIDDigitizerEventRange    (1 << 1)
#define kIOHIDDigitizerEventPosition (1 << 2)

typedef IOHIDEventRef (*_IOHIDEventCreateDigitizerFingerEvent)(
    CFAllocatorRef, uint64_t,
    uint32_t, uint32_t, uint32_t,
    double, double, double,
    double, double, double, double,
    bool, bool, uint32_t
);

static _IOHIDEventCreateDigitizerFingerEvent _createFinger = NULL;

static void AC_LoadIOHID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (h) _createFinger = (_IOHIDEventCreateDigitizerFingerEvent)
            dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
    });
}

// ============================================================
// MARK: - Injection
// ============================================================

static IOHIDEventRef AC_MakeHIDEvent(CGPoint pt, bool down) {
    if (!_createFinger) return NULL;
    uint32_t mask = kIOHIDDigitizerEventPosition;
    if (down) mask |= (kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventRange);
    // IOHIDEventCreateDigitizerFingerEvent expects actual point coords (not normalized, not pixels)
    return _createFinger(
        kCFAllocatorDefault, mach_absolute_time(),
        1, 1, mask,
        pt.x, pt.y, 0,          // x, y in UIKit points
        down ? 1.0 : 0.0, 0,    // pressure, twist
        5, 5,                    // minor/major radius
        down, down, 0
    );
}

static void AC_InvokeVoid(id obj, SEL sel) {
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj; inv.selector = sel; [inv invoke];
}

static void AC_Inject(CGPoint point) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return;

        // Find target window
        UIWindow *win = nil;
        for (UIWindow *w in [app valueForKey:@"windows"] ?: @[]) {
            if (w.isHidden || w.alpha <= 0) continue;
            if ([NSStringFromClass([w class]) isEqualToString:@"ACOverlayWindow"]) continue;
            if (!win || w.windowLevel > win.windowLevel) win = w;
        }
        if (!win) return;

        UIView *hitView = [win hitTest:point withEvent:nil] ?: win;

        // Build IOHIDEvent (makes games register the touch as real hardware input)
        IOHIDEventRef hidEvt = AC_MakeHIDEvent(point, true);

        // Build UITouch and attach the IOHIDEvent to it (_setHIDEvent: is the key)
        SEL initSel    = NSSelectorFromString(@"initAtPoint:inWindow:");
        SEL hidSel     = NSSelectorFromString(@"_setHIDEvent:");
        SEL phaseSel   = NSSelectorFromString(@"_setPhase:");
        SEL tsSel      = NSSelectorFromString(@"_setTimestamp:");
        SEL viewSel    = NSSelectorFromString(@"_setView:");
        SEL tapSel     = NSSelectorFromString(@"_setTapCount:");
        SEL evtSel     = NSSelectorFromString(@"_touchesEvent");
        SEL clrSel     = NSSelectorFromString(@"_clearTouches");
        SEL addSel     = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");

        if (![UITouch instancesRespondToSelector:initSel]) {
            // Fallback: enqueue raw HID event only
            if (hidEvt) {
                SEL eq = NSSelectorFromString(@"_enqueueHIDEvent:");
                if ([app respondsToSelector:eq]) {
                    NSMethodSignature *sig = [app methodSignatureForSelector:eq];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = app; inv.selector = eq;
                    [inv setArgument:&hidEvt atIndex:2]; [inv invoke];
                }
                CFRelease(hidEvt);
            }
            return;
        }

        // Init UITouch
        __unsafe_unretained UITouch *rawTouch = nil;
        {
            NSMethodSignature *sig = [UITouch instanceMethodSignatureForSelector:initSel];
            if (!sig) return;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            UITouch *alloc = [UITouch alloc];
            inv.target = alloc; inv.selector = initSel;
            [inv setArgument:&point atIndex:2];
            [inv setArgument:&win   atIndex:3];
            [inv invoke];
            [inv getReturnValue:&rawTouch];
        }
        UITouch *touch = rawTouch;
        if (!touch) { if (hidEvt) CFRelease(hidEvt); return; }

        // Attach IOHIDEvent to UITouch — this is what makes games see it
        if (hidEvt && [touch respondsToSelector:hidSel]) {
            NSMethodSignature *sig = [touch methodSignatureForSelector:hidSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = touch; inv.selector = hidSel;
            [inv setArgument:&hidEvt atIndex:2]; [inv invoke];
        }

        NSTimeInterval ts = [NSProcessInfo processInfo].systemUptime;
        UITouchPhase began = UITouchPhaseBegan;
        NSUInteger tapCount = 1;

        if ([touch respondsToSelector:phaseSel]) {
            NSMethodSignature *sig = [touch methodSignatureForSelector:phaseSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = touch; inv.selector = phaseSel;
            [inv setArgument:&began atIndex:2]; [inv invoke];
        }
        if ([touch respondsToSelector:tsSel]) {
            NSMethodSignature *sig = [touch methodSignatureForSelector:tsSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = touch; inv.selector = tsSel;
            [inv setArgument:&ts atIndex:2]; [inv invoke];
        }
        if ([touch respondsToSelector:viewSel]) {
            NSMethodSignature *sig = [touch methodSignatureForSelector:viewSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = touch; inv.selector = viewSel;
            __unsafe_unretained UIView *rv = hitView;
            [inv setArgument:&rv atIndex:2]; [inv invoke];
        }
        if ([touch respondsToSelector:tapSel]) {
            NSMethodSignature *sig = [touch methodSignatureForSelector:tapSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = touch; inv.selector = tapSel;
            [inv setArgument:&tapCount atIndex:2]; [inv invoke];
        }

        // Get UIEvent and inject
        __unsafe_unretained UIEvent *rawEvt = nil;
        if ([app respondsToSelector:evtSel]) {
            NSMethodSignature *sig = [app methodSignatureForSelector:evtSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = app; inv.selector = evtSel;
            [inv invoke]; [inv getReturnValue:&rawEvt];
        }
        UIEvent *evt = rawEvt;
        if (evt) {
            if ([evt respondsToSelector:clrSel]) AC_InvokeVoid(evt, clrSel);
            if ([evt respondsToSelector:addSel]) {
                NSMethodSignature *sig = [evt methodSignatureForSelector:addSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = evt; inv.selector = addSel;
                __unsafe_unretained UITouch *rawT = touch;
                BOOL delayed = NO;
                [inv setArgument:&rawT    atIndex:2];
                [inv setArgument:&delayed atIndex:3];
                [inv invoke];
            }
            [app sendEvent:evt];
        }

        // Also enqueue raw HID event — games that bypass UIKit pick this up
        SEL enqueueSel = NSSelectorFromString(@"_enqueueHIDEvent:");
        if (hidEvt && [app respondsToSelector:enqueueSel]) {
            NSMethodSignature *sig = [app methodSignatureForSelector:enqueueSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = app; inv.selector = enqueueSel;
            [inv setArgument:&hidEvt atIndex:2];
            [inv invoke];
        }
        if (hidEvt) CFRelease(hidEvt);

        // End touch after 80ms
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            @try {
                IOHIDEventRef hidEnd = AC_MakeHIDEvent(point, false);
                NSTimeInterval ts2 = [NSProcessInfo processInfo].systemUptime;
                UITouchPhase ended = UITouchPhaseEnded;

                if ([touch respondsToSelector:hidSel] && hidEnd) {
                    NSMethodSignature *sig = [touch methodSignatureForSelector:hidSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = touch; inv.selector = hidSel;
                    [inv setArgument:&hidEnd atIndex:2]; [inv invoke];
                }
                if ([touch respondsToSelector:phaseSel]) {
                    NSMethodSignature *sig = [touch methodSignatureForSelector:phaseSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = touch; inv.selector = phaseSel;
                    [inv setArgument:&ended atIndex:2]; [inv invoke];
                }
                if ([touch respondsToSelector:tsSel]) {
                    NSMethodSignature *sig = [touch methodSignatureForSelector:tsSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = touch; inv.selector = tsSel;
                    [inv setArgument:&ts2 atIndex:2]; [inv invoke];
                }
                if (evt) {
                    if ([evt respondsToSelector:clrSel]) AC_InvokeVoid(evt, clrSel);
                    if ([evt respondsToSelector:addSel]) {
                        NSMethodSignature *sig = [evt methodSignatureForSelector:addSel];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = evt; inv.selector = addSel;
                        __unsafe_unretained UITouch *rawT = touch;
                        BOOL delayed = NO;
                        [inv setArgument:&rawT    atIndex:2];
                        [inv setArgument:&delayed atIndex:3];
                        [inv invoke];
                    }
                    [app sendEvent:evt];
                }
                SEL enqueueSel = NSSelectorFromString(@"_enqueueHIDEvent:");
                if (hidEnd && [app respondsToSelector:enqueueSel]) {
                    NSMethodSignature *sig = [app methodSignatureForSelector:enqueueSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = app; inv.selector = enqueueSel;
                    [inv setArgument:&hidEnd atIndex:2];
                    [inv invoke];
                }
                if (hidEnd) CFRelease(hidEnd);
            } @catch(...) {}
        });
    } @catch(...) {}
}

// ============================================================
// MARK: - Engine
// ============================================================

@interface ACEngine : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL sequenceMode;
@property (nonatomic) CGPoint singlePoint;
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic, readonly) NSMutableArray<NSValue *> *sequence;
@property (nonatomic) NSUInteger seqIndex;
- (void)start;
- (void)stop;
- (void)addPoint:(CGPoint)pt;
- (void)clearSequence;
@end

@implementation ACEngine {
    dispatch_source_t _src;
}

+ (instancetype)shared {
    static ACEngine *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [self new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _interval  = 0.10;
        _singlePoint = CGPointMake(200, 400);
        _sequence  = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    if (_running) return;
    _running   = YES;
    _seqIndex  = 0;

    uint64_t iv = (uint64_t)(_interval * NSEC_PER_SEC);
    _src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_src, dispatch_time(DISPATCH_TIME_NOW, iv), iv, 1 * NSEC_PER_MSEC);

    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_src, ^{
        ACEngine *e = ws;
        if (!e || !e.running) return;
        if (!e.sequenceMode) {
            AC_Inject(e.singlePoint);
        } else {
            if (e.sequence.count == 0) return;
            AC_Inject([e.sequence[e.seqIndex] CGPointValue]);
            e->_seqIndex = (e->_seqIndex + 1) % e.sequence.count;
        }
    });
    dispatch_resume(_src);
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    dispatch_source_cancel(_src);
    _src = nil;
}

- (void)addPoint:(CGPoint)pt {
    [_sequence addObject:[NSValue valueWithCGPoint:pt]];
}

- (void)clearSequence {
    [_sequence removeAllObjects];
    _seqIndex = 0;
}

@end

// Pass-through root view — only claims hits on actual subviews, not its own background
@interface ACPassthroughView : UIView
@end
@implementation ACPassthroughView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    return (hit == self) ? nil : hit;
}
@end

// ============================================================
// MARK: - Pass-through Overlay Window
// ============================================================

@interface ACOverlayWindow : UIWindow
@end

@implementation ACOverlayWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *hit = [super hitTest:p withEvent:e];
    // Only claim the hit if it landed on a real subview (panel or capture overlay)
    // If it hit the window background itself, pass through to underlying app
    return (hit == self) ? nil : hit;
}
@end

// ============================================================
// MARK: - Panel
// ============================================================

@interface ACPanel : UIView
@property (nonatomic, strong) UIButton *startBtn;
@property (nonatomic, strong) UISegmentedControl *modeSeg;
@property (nonatomic, strong) UISlider *ivSlider;
@property (nonatomic, strong) UILabel *ivLabel;
@property (nonatomic, strong) UILabel *ptLabel;
@property (nonatomic, strong) UIButton *setPtBtn;
@property (nonatomic, strong) UIView *seqSection;
@property (nonatomic, strong) UILabel *seqCountLabel;
@property (nonatomic, strong) UIButton *recBtn;
@property (nonatomic, strong) UIView *captureOverlay;
@property (nonatomic, copy) void (^captureCallback)(CGPoint);
@property (nonatomic) BOOL capturing;
@property (nonatomic) BOOL recording;
+ (instancetype)make;
@end

@implementation ACPanel

+ (instancetype)make {
    ACPanel *p = [[self alloc] initWithFrame:CGRectMake(15, 80, 215, 272)];
    [p buildUI];
    return p;
}

- (void)buildUI {
    const CGFloat W = 215, x = 10, w = W - 20;

    self.backgroundColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.11 alpha:0.93];
    self.layer.cornerRadius = 14;
    self.layer.borderColor  = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    self.layer.borderWidth  = 0.5;
    self.layer.shadowColor  = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.7;
    self.layer.shadowRadius = 10;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.clipsToBounds = NO;

    // ---- Title bar / drag handle ----
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 38)];
    bar.backgroundColor = [UIColor colorWithRed:0.12 green:0.48 blue:1.0 alpha:1.0];
    bar.layer.cornerRadius = 14;
    bar.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [self addSubview:bar];

    UILabel *ttl = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, W - 52, 38)];
    ttl.text      = @"AutoClicker";
    ttl.textColor = [UIColor whiteColor];
    ttl.font      = [UIFont boldSystemFontOfSize:14];
    [bar addSubview:ttl];

    // Minimize button
    UIButton *minBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    minBtn.frame = CGRectMake(W - 42, 7, 28, 24);
    minBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    minBtn.layer.cornerRadius = 6;
    [minBtn setTitle:@"—" forState:UIControlStateNormal];
    [minBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [minBtn addTarget:self action:@selector(onMinimize) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:minBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [bar addGestureRecognizer:pan];

    CGFloat y = 46;

    // ---- Start / Stop ----
    _startBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _startBtn.frame = CGRectMake(x, y, w, 34);
    _startBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.72 blue:0.32 alpha:1];
    _startBtn.layer.cornerRadius = 8;
    [_startBtn setTitle:@"START" forState:UIControlStateNormal];
    [_startBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_startBtn addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_startBtn];
    y += 42;

    // ---- Mode ----
    _modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"Single", @"Sequence"]];
    _modeSeg.frame = CGRectMake(x, y, w, 28);
    _modeSeg.selectedSegmentIndex = 0;
    if (@available(iOS 13, *)) {
        _modeSeg.selectedSegmentTintColor = [UIColor colorWithRed:0.12 green:0.48 blue:1.0 alpha:1.0];
        [_modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]} forState:UIControlStateSelected];
        [_modeSeg setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:0.65 alpha:1]} forState:UIControlStateNormal];
    }
    [_modeSeg addTarget:self action:@selector(onModeChange:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_modeSeg];
    y += 36;

    // ---- Interval ----
    _ivLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 16)];
    [self updateIvLabel:0.10];
    _ivLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1];
    _ivLabel.font = [UIFont systemFontOfSize:11];
    [self addSubview:_ivLabel];
    y += 18;

    _ivSlider = [[UISlider alloc] initWithFrame:CGRectMake(x, y, w, 26)];
    _ivSlider.minimumValue = 0.05;
    _ivSlider.maximumValue = 2.0;
    _ivSlider.value        = 0.10;
    _ivSlider.tintColor    = [UIColor colorWithRed:0.12 green:0.48 blue:1.0 alpha:1.0];
    [_ivSlider addTarget:self action:@selector(onInterval:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_ivSlider];
    y += 32;

    // ---- Point row ----
    _ptLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y + 2, 110, 16)];
    _ptLabel.text      = @"Tap: (200, 400)";
    _ptLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1];
    _ptLabel.font      = [UIFont systemFontOfSize:11];
    [self addSubview:_ptLabel];

    _setPtBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _setPtBtn.frame = CGRectMake(x + 113, y, 72, 22);
    _setPtBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.48 blue:1.0 alpha:0.85];
    _setPtBtn.layer.cornerRadius = 5;
    [_setPtBtn setTitle:@"Set Point" forState:UIControlStateNormal];
    [_setPtBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _setPtBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    [_setPtBtn addTarget:self action:@selector(onSetPoint) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_setPtBtn];
    y += 26;

    // ---- Sequence section (initially hidden) ----
    _seqSection = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 54)];
    _seqSection.hidden = YES;

    _seqCountLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 16)];
    _seqCountLabel.text      = @"Steps: 0";
    _seqCountLabel.textColor = [UIColor colorWithWhite:0.68 alpha:1];
    _seqCountLabel.font      = [UIFont systemFontOfSize:11];
    [_seqSection addSubview:_seqCountLabel];

    CGFloat bw = (w - 8) / 2;

    _recBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    _recBtn.frame = CGRectMake(0, 20, bw, 28);
    _recBtn.backgroundColor = [UIColor colorWithRed:0.78 green:0.12 blue:0.12 alpha:1];
    _recBtn.layer.cornerRadius = 6;
    [_recBtn setTitle:@"Record" forState:UIControlStateNormal];
    [_recBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _recBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [_recBtn addTarget:self action:@selector(onRecord) forControlEvents:UIControlEventTouchUpInside];
    [_seqSection addSubview:_recBtn];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    clearBtn.frame = CGRectMake(bw + 8, 20, bw, 28);
    clearBtn.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    clearBtn.layer.cornerRadius = 6;
    [clearBtn setTitle:@"Clear" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor colorWithWhite:0.8 alpha:1] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [clearBtn addTarget:self action:@selector(onClearSeq) forControlEvents:UIControlEventTouchUpInside];
    [_seqSection addSubview:clearBtn];

    [self addSubview:_seqSection];
}

// ---- Helpers ----

- (void)updateIvLabel:(float)v {
    int ms  = (int)(v * 1000);
    float cps = 1.0f / v;
    _ivLabel.text = [NSString stringWithFormat:@"Interval: %dms  (%.1f CPS)", ms, cps];
}

// ---- Actions ----

- (void)onMinimize {
    BOOL isMin = self.frame.size.height == 38;
    CGRect f   = self.frame;
    if (isMin) {
        // restore
        f.size.height = (_modeSeg.selectedSegmentIndex == 1) ? 326 : 272;
        self.frame = f;
        for (UIView *v in self.subviews)
            if (v.tag != 99) v.hidden = NO;
    } else {
        // minimize — hide everything except title bar
        f.size.height = 38;
        self.frame = f;
        for (UIView *v in self.subviews)
            if (v.tag != 99) v.hidden = (v != [self.subviews firstObject]);
    }
}

- (void)onPan:(UIPanGestureRecognizer *)gr {
    CGPoint t = [gr translationInView:self.superview];
    CGRect f  = self.frame;
    CGRect sc = [UIScreen mainScreen].bounds;
    f.origin.x = MAX(0, MIN(f.origin.x + t.x, sc.size.width  - f.size.width));
    f.origin.y = MAX(20, MIN(f.origin.y + t.y, sc.size.height - f.size.height));
    self.frame = f;
    [gr setTranslation:CGPointZero inView:self.superview];
}

- (void)onToggle {
    ACEngine *e = [ACEngine shared];
    if (e.running) {
        [e stop];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.72 blue:0.32 alpha:1];
        [_startBtn setTitle:@"START" forState:UIControlStateNormal];
    } else {
        [e start];
        _startBtn.backgroundColor = [UIColor colorWithRed:0.85 green:0.18 blue:0.18 alpha:1];
        [_startBtn setTitle:@"STOP" forState:UIControlStateNormal];
    }
}

- (void)onModeChange:(UISegmentedControl *)seg {
    BOOL seq = seg.selectedSegmentIndex == 1;
    [ACEngine shared].sequenceMode = seq;
    _seqSection.hidden = !seq;
    _setPtBtn.hidden   = seq;
    _ptLabel.hidden    = seq;

    CGRect f = self.frame;
    f.size.height = seq ? 326 : 272;
    self.frame = f;
}

- (void)onInterval:(UISlider *)sl {
    float v = sl.value;
    // Snap to nearest 10ms
    v = roundf(v * 100.0f) / 100.0f;
    [ACEngine shared].interval = v;
    [self updateIvLabel:v];
}

- (void)onSetPoint {
    if (_capturing) {
        _capturing = NO;
        [_setPtBtn setTitle:@"Set Point" forState:UIControlStateNormal];
        _setPtBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.48 blue:1.0 alpha:0.85];
        [self hideCaptureOverlay];
        return;
    }
    _capturing = YES;
    [_setPtBtn setTitle:@"Cancel" forState:UIControlStateNormal];
    _setPtBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.45 blue:0.0 alpha:0.9];

    __weak ACPanel *ws = self;
    [self showCaptureOverlay:^(CGPoint pt) {
        ACPanel *s = ws;
        if (!s) return;
        [ACEngine shared].singlePoint = pt;
        s->_ptLabel.text = [NSString stringWithFormat:@"Tap: (%.0f, %.0f)", pt.x, pt.y];
        s->_capturing = NO;
        [s->_setPtBtn setTitle:@"Set Point" forState:UIControlStateNormal];
        s->_setPtBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.48 blue:1.0 alpha:0.85];
    }];
}

- (void)onRecord {
    if (_recording) {
        _recording = NO;
        [_recBtn setTitle:@"Record" forState:UIControlStateNormal];
        _recBtn.backgroundColor = [UIColor colorWithRed:0.78 green:0.12 blue:0.12 alpha:1];
        [self hideCaptureOverlay];
        return;
    }
    _recording = YES;
    [_recBtn setTitle:@"Stop Rec" forState:UIControlStateNormal];
    _recBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.45 blue:0.0 alpha:0.9];

    __weak ACPanel *ws = self;
    [self showRecordingOverlay:^(CGPoint pt) {
        ACPanel *s = ws;
        if (!s || !s.recording) return;
        [[ACEngine shared] addPoint:pt];
        s->_seqCountLabel.text = [NSString stringWithFormat:@"Steps: %lu",
                                  (unsigned long)[ACEngine shared].sequence.count];
    }];
}

- (void)onClearSeq {
    [[ACEngine shared] clearSequence];
    _seqCountLabel.text = @"Steps: 0";
}

// ---- Capture overlays ----

- (void)showCaptureOverlay:(void(^)(CGPoint))cb {
    _captureCallback = cb;
    // Add to the window directly, not rootVC.view (which has userInteractionEnabled=NO)
    UIView *sup = self.window ?: self.superview;
    if (!sup) return;

    CGRect screen = [UIScreen mainScreen].bounds;
    _captureOverlay = [[UIView alloc] initWithFrame:screen];
    _captureOverlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.38];
    _captureOverlay.userInteractionEnabled = YES;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20, screen.size.height/2 - 28, screen.size.width - 40, 56)];
    lbl.text          = @"Tap to set click point";
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.textColor     = [UIColor whiteColor];
    lbl.font          = [UIFont boldSystemFontOfSize:20];
    lbl.numberOfLines = 2;
    [_captureOverlay addSubview:lbl];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onCaptureTap:)];
    [_captureOverlay addGestureRecognizer:tap];
    [sup addSubview:_captureOverlay];
    [sup bringSubviewToFront:self];
}

- (void)showRecordingOverlay:(void(^)(CGPoint))cb {
    _captureCallback = cb;
    UIView *sup = self.window ?: self.superview;
    if (!sup) return;

    CGRect screen = [UIScreen mainScreen].bounds;
    _captureOverlay = [[UIView alloc] initWithFrame:screen];
    _captureOverlay.backgroundColor = [UIColor colorWithRed:0.8 green:0 blue:0 alpha:0.06];
    _captureOverlay.userInteractionEnabled = YES;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 55, screen.size.width - 40, 28)];
    lbl.text          = @"Tap anywhere to record steps";
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.textColor     = [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
    lbl.font          = [UIFont boldSystemFontOfSize:13];
    [_captureOverlay addSubview:lbl];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onCaptureTap:)];
    [_captureOverlay addGestureRecognizer:tap];
    [sup addSubview:_captureOverlay];
    [sup bringSubviewToFront:self];
}

- (void)onCaptureTap:(UITapGestureRecognizer *)gr {
    // Convert tap location to screen coords
    CGPoint pt = [gr locationInView:self.superview];
    if (_captureCallback) _captureCallback(pt);
    // For recording mode keep overlay; for capture mode remove it
    if (!_recording) [self hideCaptureOverlay];
}

- (void)hideCaptureOverlay {
    [_captureOverlay removeFromSuperview];
    _captureOverlay = nil;
    _captureCallback = nil;
}

@end

// ============================================================
// MARK: - Manager (window host)
// ============================================================

@interface ACManager : NSObject
+ (instancetype)shared;
- (void)setup;
@end

@implementation ACManager {
    ACOverlayWindow *_win;
}

+ (instancetype)shared {
    static ACManager *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [self new]; });
    return s;
}

- (void)setup {
    _win = [[ACOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    if (@available(iOS 13, *)) {
        for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (sc.activationState == UISceneActivationStateForegroundActive) {
                _win.windowScene = (UIWindowScene *)sc;
                break;
            }
        }
    }

    // Keep window level reasonable — high enough to float above app, low enough
    // not to intercept system gestures or steal touches from the app
    _win.windowLevel       = UIWindowLevelNormal + 1;
    _win.backgroundColor   = [UIColor clearColor];
    // Disable interaction on the window itself; only the panel will be interactive
    _win.userInteractionEnabled = YES;

    UIViewController *rootVC = [UIViewController new];
    // Use passthrough view so background passes touches to the app underneath
    ACPassthroughView *ptView = [[ACPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ptView.backgroundColor = [UIColor clearColor];
    rootVC.view = ptView;
    _win.rootViewController = rootVC;
    _win.hidden = NO;

    ACPanel *panel = [ACPanel make];
    panel.userInteractionEnabled = YES;
    [rootVC.view addSubview:panel];
}

@end

// ============================================================
// MARK: - Constructor
// ============================================================

%ctor {
    AC_LoadIOHID();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ACManager shared] setup];
    });
}
