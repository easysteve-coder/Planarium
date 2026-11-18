#import "PlanariumObjCCatch.h"

@implementation PlanariumObjCCatch
+ (BOOL)perform:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        // Deliberately omit userInfo, stack, call addresses and arbitrary
        // exception metadata. Only the documented name/reason cross to Swift.
        if (error) {
            *error = [NSError errorWithDomain:@"PlanariumObjCCatch" code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]}];
        }
        return NO;
    }
}
@end
