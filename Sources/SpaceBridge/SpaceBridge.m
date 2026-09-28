#import "SpaceBridge.h"
#import <dlfcn.h>

static void *symbol(const char *name) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    });
    return handle ? dlsym(handle, name) : NULL;
}
static int connection(void) {
    int (*fn)(void) = symbol("SLSMainConnectionID");
    return fn ? fn() : 0;
}
BOOL YBHasSpaceReadAPI(void) {
    return symbol("SLSMainConnectionID") && symbol("SLSCopyManagedDisplaySpaces") && symbol("SLSCopySpacesForWindows");
}
BOOL YBHasWindowMoveAPI(void) {
    return YBHasSpaceReadAPI() && symbol("SLSSpaceSetCompatID") && symbol("SLSSetWindowListWorkspace");
}
NSArray *YBCopyDisplays(void) {
    CFArrayRef (*fn)(int) = symbol("SLSCopyManagedDisplaySpaces");
    return fn ? CFBridgingRelease(fn(connection())) : nil;
}
NSArray<NSNumber *> *YBCopyWindowSpaces(uint32_t window) {
    CFArrayRef (*fn)(int, int, CFArrayRef) = symbol("SLSCopySpacesForWindows");
    return fn ? CFBridgingRelease(fn(connection(), 7, (__bridge CFArrayRef)@[@(window)])) : nil;
}
int YBMoveWindow(uint32_t window, uint64_t space) {
    CGError (*compat)(int, uint64_t, int) = symbol("SLSSpaceSetCompatID");
    CGError (*move)(int, uint32_t *, int, int) = symbol("SLSSetWindowListWorkspace");
    if (!YBHasWindowMoveAPI()) return -1;
    int cid = connection();
    // Compatibility workspace technique documented by yabai / Hammerspoon.
    // Never inject into Dock; callers must verify membership after this best-effort call.
    int workspace = 0x79626279;
    CGError result = compat(cid, space, workspace);
    if (result != kCGErrorSuccess) return result;
    result = move(cid, &window, 1, workspace);
    CGError reset = compat(cid, space, 0);
    return result == kCGErrorSuccess ? reset : result;
}
uint32_t YBWindowID(AXUIElementRef element) {
    typedef AXError (*WindowIDFn)(AXUIElementRef, uint32_t *);
    static WindowIDFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (WindowIDFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow"); });
    uint32_t wid = 0;
    if (fn) fn(element, &wid);
    return wid;
}
