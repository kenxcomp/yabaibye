#import "SpaceBridge.h"
#import <dlfcn.h>

// Read-only migration diagnostics. yabai's below/normal settings use sublevels,
// which differ from kCGWindowLayer and may outlive the managing process.
// This private getter was verified on macOS 27.2; no setter or injection is used.
BOOL YBReadWindowSublevel(uint32_t window, int32_t *result) {
    NSArray *records = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window));
    if (!records.count || ![records.firstObject[(__bridge NSString *)kCGWindowNumber] isEqual:@(window)]) return NO;
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    });
    if (!handle) return NO;
    int (*mainConnection)(void) = dlsym(handle, "SLSMainConnectionID");
    int32_t (*getSublevel)(int, uint32_t) = dlsym(handle, "SLSGetWindowSubLevel");
    if (!mainConnection || !getSublevel) return NO;
    *result = getSublevel(mainConnection(), window);
    return YES;
}
