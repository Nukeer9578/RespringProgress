#import <objc/runtime.h>
#import <libkern/OSAtomic.h>

@interface PUIProgressWindow : NSObject
- (void)setProgressValue:(float)arg1;
- (void)_createLayer;
- (void)setVisible:(BOOL)arg1;
-(id)initWithProgressBarVisibility:(BOOL)arg1 createContext:(BOOL)arg2 contextLevel:(float)arg3 appearance:(int)arg4;
@end

CFDataRef receiveProgress(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info);

PUIProgressWindow *window;

%hook BKSystemAppSentinel


- (void) _handleRelaunchRequestFromSystemApp:(id)arg1 withOptions:(unsigned long)arg2{
    arg2 = 2;
    %orig;
}


%end


%hook BKDisplayRenderOverlaySpinny

-(id)initWithOverlayDescriptor:(id)arg1 level:(float)arg2{
    if (window == nil && arg2 > -1)
    {
        window = [[PUIProgressWindow alloc] initWithProgressBarVisibility:YES createContext:YES contextLevel:1000 appearance:0];
        [window setProgressValue:0.01];
        [window setVisible:YES];
    }
    return %orig(arg1, -1);
}

- (BOOL) presentWithAnimationSettings:(id)arg1{
    return true;
}

%end

%hook PUIProgressWindow

- (id)initWithProgressBarVisibility:(BOOL)arg1 createContext:(BOOL)arg2 contextLevel:(float)arg3 appearance:(int)arg4 {

    
    CFMessagePortRef port = CFMessagePortCreateLocal(kCFAllocatorDefault, CFSTR("com.ethanarbuckle.launch-progress"), &receiveProgress, NULL, NULL);
    CFMessagePortSetDispatchQueue(port, dispatch_get_main_queue());
    window = %orig(YES, arg2, arg3, arg4);
    return window;
}

CFDataRef receiveProgress(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
    if (window == nil)
    {
        window = [[PUIProgressWindow alloc] initWithProgressBarVisibility:YES createContext:YES contextLevel:1000 appearance:0];
        [window setVisible:true];
        [window _createLayer];
    }
    NSData *receivedData = (NSData *)data;
    int progressPointer;
    [receivedData getBytes:&progressPointer length:sizeof(progressPointer)];

    if(progressPointer < 95)
    {
        [window setProgressValue:(float)progressPointer / 100];

        [window setVisible:true];
    }
    else
    {
        [window _createLayer];
        [window setVisible:false];
    }
    

    return NULL;
}

%end

static volatile int64_t ping = 0;

//1 counts every init, but takes the longest. Higher the number, fast the loading, but less accurate. i like 8-12
int classSkipCount = 1;
int averageObjectCount = pow(10, 7); //assuming this is how many objects SB creates (9.0 on 6s+ will be close to this)

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application {

    __block clock_t begin, end;
    __block double time_spent;
    begin = clock();

    __block NSDictionary *storedData;
    [window init];    
    [window setProgressValue:0.01];
    [window setVisible:YES];

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
                if (currentProgress > local && (((currentProgress % 2) == 0) || currentProgress >= 94)) { //6 seems to be a good interval to prevent screen flashes
                    local = currentProgress;
                    if (port) {
                        //Hoping it is never smaller than 0, original expr was 'if (port > 0)'-> err - can't compare pointer to int
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

        for (int i = 0; i < totalClasses; i++) {

            if (strncmp(object_getClassName(classBuffer[i]), "SB", 2) == 0 && strncmp(object_getClassName(classBuffer[i]),"SBClockApplicationIconImageView", 31) != 0) {

                if ((jumpAhead++ % classSkipCount) == 0) { //save some resources and time by only swapping every nth class
                    Method originalMethod = class_getInstanceMethod(classBuffer[i], @selector(init));
                    if (originalMethod != NULL) {

                        //IMP originalImp = class_getMethodImplementation(classBuffer[i], @selector(init));
                        IMP newImp = imp_implementationWithBlock(^(id _self, SEL selector) {

                            if (ping > -1) {
                                #pragma GCC diagnostic push
                                #pragma GCC diagnostic ignored "-Wdeprecated-declarations"
                                OSAtomicIncrement64(&ping);
                                #pragma GCC diagnostic pop
                            }

                            return class_getMethodImplementation(_self, @selector(init));
                        });
                        method_setImplementation(originalMethod, newImp);

                    }
                }
            }

        }

    });
    

    %orig;

    int64_t finalObjectCount = ping;
    ping = -1;
    end = clock();
    time_spent = (double)(end - begin) / CLOCKS_PER_SEC;
    HBLogDebug(@"Springboard launched with %lld -init calls, estimation of %d off by %.2f%%, in %.2f seconds", finalObjectCount, averageObjectCount, (ABS(finalObjectCount - ((float)averageObjectCount / classSkipCount)) / ((finalObjectCount + ((float)averageObjectCount / classSkipCount)) / 2)) * 100, time_spent);
    
    int32_t local = 100;
    CFMessagePortRef port = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("com.ethanarbuckle.launch-progress"));
    int progressPointer = local;
    NSData *progressMessage = [NSData dataWithBytes:&local length:sizeof(progressPointer)];
    
    if (port != NULL || port != nil) {
        //same as ln 124
        CFMessagePortSendRequest(port, 0, (CFDataRef)progressMessage, 1000, 0, NULL, NULL);
    }
    
    
    if (![storedData valueForKey:@"deviceInits"]) {
        NSDictionary *newData = @{ @"deviceInits" : @(finalObjectCount) };
        [newData writeToFile:@"/var/mobile/Library/Preferences/com.abusing_sb.plist" atomically:YES];
    } 
}

%end
