#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

@interface PUIProgressWindow : UIView
- (void)setProgressValue:(float)arg1;
- (void)_createLayer;
- (void)setVisible:(BOOL)arg1;
@end

PUIProgressWindow *window;
CATextLayer *label;

@interface EAClassNameTicker : NSObject

@property (nonatomic, retain) NSMutableArray *queuedMessages;
@property (nonatomic, retain) NSLock *messageLock;

@property (nonatomic) NSInteger pushedMessageCount;
@property (nonatomic) NSInteger maxMessageCount;

@property (nonatomic) CGFloat currentLaunchProgress;

@property (nonatomic) BOOL isDrawing;

+ (id)sharedInstance;
- (void)addMessage:(NSString *)message;
- (void)redrawMessages;
- (void)haltOperations;
- (void)updateProgress:(CGFloat)progress;
@end

@implementation EAClassNameTicker

+ (id)sharedInstance {

    static dispatch_once_t onceToken;
    static EAClassNameTicker *sharedInstance = nil;
    dispatch_once(&onceToken, ^{
        sharedInstance = [EAClassNameTicker new];
    });

    return sharedInstance;
}

- (id)init {

    if ((self = [super init])) {

        _pushedMessageCount = 0;
        _currentLaunchProgress = 0;
        _queuedMessages = [[NSMutableArray alloc] init];
        _messageLock = [[NSLock alloc] init];

        _maxMessageCount = 70;
        _isDrawing = NO;

    }

    return self;
}

- (void)addMessage:(NSString *)message {

    if (!message || [message length] <= 0) {

        return;
    }

    if (_queuedMessages) {

        [_messageLock lock];
        [_queuedMessages addObject:message];
        [_messageLock unlock];
    }

    if ([_queuedMessages count] > 0 && !_isDrawing) {

        [self redrawMessages];
    }
}

- (void)redrawMessages {

    if ([_queuedMessages count] < 1) {

        _isDrawing = NO;

        return;
    }

    if (!label || !window) return;

    _isDrawing = YES;
    _pushedMessageCount++;

    if (_pushedMessageCount >= _maxMessageCount && [_queuedMessages count] > ([_queuedMessages count] - _pushedMessageCount) + 1) {

        [_messageLock lock];
        [_queuedMessages removeObjectAtIndex:0];
        [_messageLock unlock];

        _pushedMessageCount--;
    }


    NSMutableString *appendedMsg = [[NSMutableString alloc] init];
    CGFloat exposedMessageCount = fmin([_queuedMessages count], fmin(_maxMessageCount, _pushedMessageCount));
    for (int i = 0; i < exposedMessageCount; i++) {
        [appendedMsg appendString:[NSString stringWithFormat:@"%@ %@\n", _queuedMessages[i], (i + 1 == exposedMessageCount) ? [NSString stringWithFormat:@"- [%.0f%% loaded...]", [[EAClassNameTicker sharedInstance] currentLaunchProgress]] : @""]];
    }

    [label setString:appendedMsg];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.005 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{

        [self redrawMessages];
    });

}

- (void)haltOperations {

    if ([_queuedMessages count] > 0) {

        [_messageLock lock];
        [_queuedMessages removeAllObjects];
        [_messageLock unlock];
    }

    _pushedMessageCount = 0;
    _currentLaunchProgress = 0;
    _isDrawing = NO;
}

- (void)updateProgress:(CGFloat)progress {

    if (progress > _currentLaunchProgress) {

        _currentLaunchProgress = progress;
    }

    if (_currentLaunchProgress >= 99) {

        [self haltOperations];
    }

}

@end

CFDataRef classInfoMessage(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info);
CFDataRef receiveProgress(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info);

%hook PUIProgressWindow

- (id)initWithProgressBarVisibility:(BOOL)arg1 createContext:(BOOL)arg2 contextLevel:(float)arg3 appearance:(int)arg4 {

    window = %orig(YES, arg2, arg3, 1);
    [window setProgressValue:0.01];

    label = [[CATextLayer alloc] init];
    [label setFont:@"Courier-Bold"];
    [label setFontSize:20];
    [label setString:@"\n"];
    [label setFrame:CGRectMake(0, 0, [[window layer] frame].size.width, [[window layer] frame].size.height)];
    [label setForegroundColor:[[UIColor greenColor] CGColor]];
    [(CALayer *)[window valueForKey:@"_layer"] addSublayer:label];

    CFMessagePortRef launchPort = CFMessagePortCreateLocal(kCFAllocatorDefault, CFSTR("com.ethanarbuckle.launch-progress"), &receiveProgress, NULL, NULL);
    CFMessagePortSetDispatchQueue(launchPort, dispatch_get_main_queue());

    CFMessagePortRef infoPort = CFMessagePortCreateLocal(kCFAllocatorDefault, CFSTR("com.ethanarbuckle.class-information"), &classInfoMessage, NULL, NULL);
    CFMessagePortSetDispatchQueue(infoPort, dispatch_get_main_queue());

    return window;
}

CFDataRef classInfoMessage(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {

    NSString *msg = [[NSString alloc] initWithData:(NSData *)data encoding:NSUTF8StringEncoding];
    [[EAClassNameTicker sharedInstance] addMessage:msg];

    return NULL;
}

CFDataRef receiveProgress(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {

    NSData *receivedData = (NSData *)data;
    int progressPointer;
    [receivedData getBytes:&progressPointer length:sizeof(progressPointer)];

    [window setProgressValue:(float)progressPointer / 100];
    [window _createLayer];
    [(CALayer *)[window valueForKey:@"_layer"] addSublayer:label];
    [window setVisible:YES];

    [[EAClassNameTicker sharedInstance] updateProgress:(CGFloat)progressPointer];

    return NULL;
}

%end

static volatile int64_t ping = 0;

//1 counts every init, but takes the longest. Higher the number, fast the loading, but less accurate. i like 8-12
int classSkipCount = 8;
int averageObjectCount = pow(10, 7); //assuming this is how many objects SB creates (9.0 on 6s+ will be close to this)
int classNameSendCount = 6; //send every nth class

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {

    __block clock_t begin, end;
    __block double time_spent;
    begin = clock();

    __block NSDictionary *storedData;

    static dispatch_once_t swizzleOnce;
    dispatch_once(&swizzleOnce, ^{

        storedData = [[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.abusing_sb.plist"];
        if (![storedData valueForKey:@"deviceInits"]) {
            classSkipCount = 1;
        } else {
            averageObjectCount = [[storedData valueForKey:@"deviceInits"] intValue];
        }

        dispatch_queue_t progressThread =  dispatch_queue_create("progressThread", DISPATCH_QUEUE_CONCURRENT);
        dispatch_async(progressThread, ^{

            CFMessagePortRef port = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("com.ethanarbuckle.launch-progress"));

            int32_t local = 0;
            while (ping <= (averageObjectCount / classSkipCount) && ping > -1) {

                int32_t currentProgress = ((float)100 / (averageObjectCount / classSkipCount)) * ping;

                if (currentProgress > local && (((currentProgress % 6) == 0) || currentProgress >= 95)) {

                    local = currentProgress;
                    if (port > 0) {

                        int progressPointer = local;
                        NSData *progressMessage = [NSData dataWithBytes:&local length:sizeof(progressPointer)];
                        CFMessagePortSendRequest(port, 0, (CFDataRef)progressMessage, 1000, 0, NULL, NULL);
                    }
                }

            }

        });

        uint32_t totalClasses = 0;
        Class *classBuffer = objc_copyClassList(&totalClasses);
        int jumpAhead = 0;
        int classNameJumpAhead = classNameSendCount - 1; // want it to send the name on first run

        CFMessagePortRef port = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("com.ethanarbuckle.class-information"));

        for (int i = 0; i < totalClasses; i++) {

            if (strncmp(object_getClassName(classBuffer[i]), "SB", 2) == 0) {

                if ((jumpAhead++ % classSkipCount) == 0) { //save some resources and time by only swapping every nth class

                    Method originalMethod = class_getInstanceMethod(classBuffer[i], @selector(init));
                    if (originalMethod != NULL) {

                        IMP originalImp = class_getMethodImplementation(classBuffer[i], @selector(init));
                        IMP newImp = imp_implementationWithBlock(^(id _self, SEL selector) {

                            if (ping > -1) {

                                OSAtomicIncrement64(&ping);
                            }

                            return originalImp(_self, @selector(init));
                        });

                        method_setImplementation(originalMethod, newImp);

                    }
                }
            }

            if ((classNameJumpAhead++ % classNameSendCount) == 0) {

                NSData *message = [[NSString stringWithFormat:@"[%p](%s)", class_getInstanceMethod(classBuffer[i], @selector(init)), object_getClassName(classBuffer[i])] dataUsingEncoding:NSUTF8StringEncoding];
                CFMessagePortSendRequest(port, 0, (CFDataRef)message, 1000, 0, NULL, NULL);
            }
        }


    });

    %orig;

    int64_t finalObjectCount = ping;
    ping = -1;
    end = clock();
    time_spent = (double)(end - begin) / CLOCKS_PER_SEC;
    HBLogDebug(@"Springboard launched with %lld -init calls, estimation of %d off by %.2f%%, in %.2f seconds", finalObjectCount, averageObjectCount, (ABS(finalObjectCount - ((float)averageObjectCount / classSkipCount)) / ((finalObjectCount + ((float)averageObjectCount / classSkipCount)) / 2)) * 100, time_spent);

    if (![storedData valueForKey:@"deviceInits"]) {
        NSDictionary *newData = @{ @"deviceInits" : @(finalObjectCount) };
        [newData writeToFile:@"/var/mobile/Library/Preferences/com.abusing_sb.plist" atomically:YES];
    }
}

%end