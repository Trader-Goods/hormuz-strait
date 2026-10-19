#import "ResourceSize.h"

long long LiveResourceFileSize(PHAssetResource *resource) {
    @try {
        id value = [resource valueForKey:@"fileSize"];
        if ([value isKindOfClass:[NSNumber class]]) {
            return [(NSNumber *)value longLongValue];
        }
    } @catch (NSException *exception) {
        return 0;
    }
    return 0;
}
