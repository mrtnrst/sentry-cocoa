#import <Foundation/Foundation.h>

/**
 * The data category used for envelopes: https://develop.sentry.dev/sdk/envelopes/#data-model, rate
 * limits: https://develop.sentry.dev/sdk/rate-limiting/#definitions and client reports:
 * https://develop.sentry.dev/sdk/client-reports/#envelope-item-payload.
 */
typedef NS_ENUM(NSUInteger, SentryDataCategory) {
    kSentryDataCategoryAll = 0,
    kSentryDataCategoryDefault = 1,
    kSentryDataCategoryError = 2,
    kSentryDataCategorySession = 3,
    kSentryDataCategoryTransaction = 4,
    kSentryDataCategoryAttachment = 5,
    kSentryDataCategoryUserFeedback = 6,
    kSentryDataCategoryUnknown = 7
};

static NSString *_Nonnull const SentryDataCategoryNames[] = {
    @"", // empty on purpose
    @"default",
    @"error",
    @"session",
    @"transaction",
    @"attachment",
    @"user_report",
    @"unkown",
};
