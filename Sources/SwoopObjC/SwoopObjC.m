#import "SwoopObjC.h"

BOOL SwoopTouchPosition(NSTouch *touch, NSPoint *position) {
    @try {
        *position = touch.normalizedPosition;
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
