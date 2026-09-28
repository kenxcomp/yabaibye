#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Every private symbol is resolved at runtime. Missing symbols disable only that capability.
NSArray * _Nullable YBCopyDisplays(void);
NSArray<NSNumber *> * _Nullable YBCopyWindowSpaces(uint32_t window);
BOOL YBHasSpaceReadAPI(void);
int YBToggleMissionControl(void);
BOOL YBHasBridgedWindowMoveAPI(void);
BOOL YBHasWindowMoveAPI(void);
int YBMoveWindow(uint32_t window, uint64_t space);
uint32_t YBWindowID(AXUIElementRef element);
NS_ASSUME_NONNULL_END
