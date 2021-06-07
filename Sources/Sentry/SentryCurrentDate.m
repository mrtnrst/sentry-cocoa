#import "SentryCurrentDate.h"
#import "SentryCurrentDateProvider.h"
#import "SentryDefaultCurrentDateProvider.h"
#import "SentryDependencies.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface
SentryCurrentDate ()

@end

@implementation SentryCurrentDate

static id<SentryCurrentDateProvider> currentDateProvider;

+ (NSDate *_Nonnull)date
{
    if (nil == currentDateProvider) {
        currentDateProvider = SentryDependencies.currentDateProvider;
    }
    return [currentDateProvider date];
}

+ (void)setCurrentDateProvider:(id<SentryCurrentDateProvider>)value
{
    currentDateProvider = value;
}

@end

NS_ASSUME_NONNULL_END
