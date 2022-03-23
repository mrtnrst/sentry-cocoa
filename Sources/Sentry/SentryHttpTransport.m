#import "SentryHttpTransport.h"
#import "SentryClientReport.h"
#import "SentryDataCategoryMapper.h"
#import "SentryDiscardReasonMapper.h"
#import "SentryDiscardedEvent.h"
#import "SentryDispatchQueueWrapper.h"
#import "SentryDsn.h"
#import "SentryEnvelope.h"
#import "SentryEnvelopeItemType.h"
#import "SentryEnvelopeRateLimit.h"
#import "SentryEvent.h"
#import "SentryFileContents.h"
#import "SentryFileManager.h"
#import "SentryLog.h"
#import "SentryNSURLRequest.h"
#import "SentryOptions.h"
#import "SentrySerialization.h"
#import "SentryTraceState.h"

@interface
SentryHttpTransport ()

@property (nonatomic, strong) SentryFileManager *fileManager;
@property (nonatomic, strong) id<SentryRequestManager> requestManager;
@property (nonatomic, strong) SentryOptions *options;
@property (nonatomic, strong) id<SentryRateLimits> rateLimits;
@property (nonatomic, strong) SentryEnvelopeRateLimit *envelopeRateLimit;
@property (nonatomic, strong) SentryDispatchQueueWrapper *dispatchQueue;

/**
 * Relay expects the discarded events split by data category and reason; see
 * https://develop.sentry.dev/sdk/client-reports/#envelope-item-payload.
 * We could use nested dictionaries, but instead, we use a dictionary with `data-category:reason`
 * and value `quantity` because it's easier to read and type.
 */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *discardedEvents;

/**
 * Synching with a dispatch queue to have concurrent reads and writes as barrier blocks is roughly
 * 30% slower than using atomic here.
 */
@property (atomic) BOOL isSending;

@end

@implementation SentryHttpTransport

- (id)initWithOptions:(SentryOptions *)options
             fileManager:(SentryFileManager *)fileManager
          requestManager:(id<SentryRequestManager>)requestManager
              rateLimits:(id<SentryRateLimits>)rateLimits
       envelopeRateLimit:(SentryEnvelopeRateLimit *)envelopeRateLimit
    dispatchQueueWrapper:(SentryDispatchQueueWrapper *)dispatchQueueWrapper
{
    if (self = [super init]) {
        self.options = options;
        self.requestManager = requestManager;
        self.fileManager = fileManager;
        self.rateLimits = rateLimits;
        self.envelopeRateLimit = envelopeRateLimit;
        self.dispatchQueue = dispatchQueueWrapper;
        _isSending = NO;
        self.discardedEvents = [NSMutableDictionary new];

        [self sendAllCachedEnvelopes];
    }
    return self;
}

- (void)recordLostEvent:(SentryDiscardReason)reason category:(SentryDataCategory)category
{
    NSString *key = [NSString stringWithFormat:@"%@:%@", SentryDataCategoryNames[category],
                              SentryDiscardReasonNames[reason]];

    @synchronized(self.discardedEvents) {
        NSNumber *value = self.discardedEvents[key];
        if (value == nil) {
            value = @(0);
        }

        self.discardedEvents[key] = @(value.integerValue + 1);
    }
}

- (void)sendEvent:(SentryEvent *)event attachments:(NSArray<SentryAttachment *> *)attachments
{
    [self sendEvent:event traceState:nil attachments:attachments];
}

- (void)sendEvent:(SentryEvent *)event
      withSession:(SentrySession *)session
      attachments:(NSArray<SentryAttachment *> *)attachments
{
    [self sendEvent:event withSession:session traceState:nil attachments:attachments];
}

- (void)sendEvent:(SentryEvent *)event
       traceState:(nullable SentryTraceState *)traceState
      attachments:(NSArray<SentryAttachment *> *)attachments
{
    [self sendEvent:event
                     traceState:traceState
                    attachments:attachments
        additionalEnvelopeItems:@[]];
}

- (void)sendEvent:(SentryEvent *)event
                 traceState:(nullable SentryTraceState *)traceState
                attachments:(NSArray<SentryAttachment *> *)attachments
    additionalEnvelopeItems:(NSArray<SentryEnvelopeItem *> *)additionalEnvelopeItems
{
    NSMutableArray<SentryEnvelopeItem *> *items = [self buildEnvelopeItems:event
                                                               attachments:attachments];
    [items addObjectsFromArray:additionalEnvelopeItems];

    SentryEnvelopeHeader *envelopeHeader = [[SentryEnvelopeHeader alloc] initWithId:event.eventId
                                                                         traceState:traceState];
    SentryEnvelope *envelope = [[SentryEnvelope alloc] initWithHeader:envelopeHeader items:items];

    [self sendEnvelope:envelope];
}

- (void)sendEvent:(SentryEvent *)event
      withSession:(SentrySession *)session
       traceState:(SentryTraceState *)traceState
      attachments:(NSArray<SentryAttachment *> *)attachments
{
    NSMutableArray<SentryEnvelopeItem *> *items = [self buildEnvelopeItems:event
                                                               attachments:attachments];
    [items addObject:[[SentryEnvelopeItem alloc] initWithSession:session]];

    SentryEnvelopeHeader *envelopeHeader = [[SentryEnvelopeHeader alloc] initWithId:event.eventId
                                                                         traceState:traceState];

    SentryEnvelope *envelope = [[SentryEnvelope alloc] initWithHeader:envelopeHeader items:items];

    [self sendEnvelope:envelope];
}

- (NSMutableArray<SentryEnvelopeItem *> *)buildEnvelopeItems:(SentryEvent *)event
                                                 attachments:
                                                     (NSArray<SentryAttachment *> *)attachments
{
    NSMutableArray<SentryEnvelopeItem *> *items = [NSMutableArray new];
    [items addObject:[[SentryEnvelopeItem alloc] initWithEvent:event]];

    for (SentryAttachment *attachment in attachments) {
        SentryEnvelopeItem *item =
            [[SentryEnvelopeItem alloc] initWithAttachment:attachment
                                         maxAttachmentSize:self.options.maxAttachmentSize];
        // The item is nil, when creating the envelopeItem failed.
        if (nil != item) {
            [items addObject:item];
        }
    }

    return items;
}

- (void)sendUserFeedback:(SentryUserFeedback *)userFeedback
{
    SentryEnvelope *envelope = [[SentryEnvelope alloc] initWithUserFeedback:userFeedback];
    [self sendEnvelope:envelope];
}

- (void)sendEnvelope:(SentryEnvelope *)envelope
{
    envelope = [self.envelopeRateLimit removeRateLimitedItems:envelope];

    if (envelope.items.count == 0) {
        [SentryLog logWithMessage:@"RateLimit is active for all envelope items."
                         andLevel:kSentryLevelDebug];
        return;
    }

    // With this we accept the a tradeoff. We might loose some envelopes when a hard crash happens,
    // because this being done on a background thread, but instead we don't block the calling
    // thread, which could be the main thread.
    [self.dispatchQueue dispatchAsyncWithBlock:^{
        [self.fileManager storeEnvelope:envelope];
        [self sendAllCachedEnvelopes];
    }];
}

#pragma mark private methods

- (void)sendAllCachedEnvelopes
{
    @synchronized(self) {
        if (self.isSending || ![self.requestManager isReady]) {
            return;
        }
        self.isSending = YES;
    }

    SentryFileContents *envelopeFileContents = [self.fileManager getOldestEnvelope];
    if (nil == envelopeFileContents) {
        self.isSending = NO;
        return;
    }

    SentryEnvelope *envelope = [SentrySerialization envelopeWithData:envelopeFileContents.contents];
    if (nil == envelope) {
        [self deleteEnvelopeAndSendNext:envelopeFileContents.path];
        return;
    }

    SentryEnvelope *rateLimitedEnvelope = [self.envelopeRateLimit removeRateLimitedItems:envelope];
    if (rateLimitedEnvelope.items.count == 0) {
        [self deleteEnvelopeAndSendNext:envelopeFileContents.path];
        return;
    }

    SentryEnvelope *envelopeToSend = [self addClientReport:rateLimitedEnvelope];

    NSError *requestError = nil;
    NSURLRequest *request = [self createEnvelopeRequest:envelopeToSend
                                       didFailWithError:requestError];

    if (nil != requestError) {
        [self deleteEnvelopeAndSendNext:envelopeFileContents.path];
        return;
    } else {
        [self sendEnvelope:envelopeFileContents.path request:request];
    }
}

- (SentryEnvelope *)addClientReport:(SentryEnvelope *)envelope
{
    @synchronized(self.discardedEvents) {
        if (self.discardedEvents.count == 0) {
            return envelope;
        }

        NSMutableArray<SentryDiscardedEvent *> *events = [NSMutableArray new];
        for (NSString *key in self.discardedEvents) {
            NSNumber *quantity = self.discardedEvents[key];

            NSArray<NSString *> *comp = [key componentsSeparatedByString:@":"];

            SentryDataCategory category = [SentryDataCategoryMapper mapStringToCategory:comp[0]];
            SentryDiscardReason reason = [SentryDiscardReasonMapper mapStringToReason:comp[1]];

            SentryDiscardedEvent *event =
                [[SentryDiscardedEvent alloc] initWithReason:reason
                                                    category:category
                                                    quantity:quantity.integerValue];

            [events addObject:event];
        }

        SentryClientReport *clientReport =
            [[SentryClientReport alloc] initWithDiscardedEvents:events];

        SentryEnvelopeItem *clientReportEnvelopeItem =
            [[SentryEnvelopeItem alloc] initWithClientReport:clientReport];

        NSMutableArray<SentryEnvelopeItem *> *currentItems =
            [[NSMutableArray alloc] initWithArray:envelope.items];
        [currentItems addObject:clientReportEnvelopeItem];

        return [[SentryEnvelope alloc] initWithHeader:envelope.header items:currentItems];
    }
}

- (void)deleteEnvelopeAndSendNext:(NSString *)envelopePath
{
    [self.fileManager removeFileAtPath:envelopePath];
    self.isSending = NO;
    [self sendAllCachedEnvelopes];
}

- (NSURLRequest *)createEnvelopeRequest:(SentryEnvelope *)envelope
                       didFailWithError:(NSError *_Nullable)error
{
    return [[SentryNSURLRequest alloc]
        initEnvelopeRequestWithDsn:self.options.parsedDsn
                           andData:[SentrySerialization dataWithEnvelope:envelope error:&error]
                  didFailWithError:&error];
}

- (void)sendEnvelope:(NSString *)envelopePath request:(NSURLRequest *)request
{
    __block SentryHttpTransport *_self = self;
    [self.requestManager
               addRequest:request
        completionHandler:^(NSHTTPURLResponse *_Nullable response, NSError *_Nullable error) {
            // If the response is not nil we had an internet connection.
            // We don't worry about errors here.
            if (nil != response) {
                [_self.rateLimits update:response];
                [_self deleteEnvelopeAndSendNext:envelopePath];
            } else {
                _self.isSending = NO;
            }
        }];
}

@end
