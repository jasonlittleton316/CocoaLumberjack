// Software License Agreement (BSD License)
//
// Copyright (c) 2010-2014, Deusty, LLC
// All rights reserved.
//
// Redistribution and use of this software in source and binary forms,
// with or without modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// * Neither the name of Deusty nor the names of its contributors may be used
//   to endorse or promote products derived from this software without specific
//   prior written permission of Deusty, LLC.

#import "DDASLLogCapture.h"
#import "DDLog.h"

#include <asl.h>
#include <notify.h>
#include <notify_keys.h>
#include <sys/time.h>

static BOOL _cancel = YES;
static DDLogLevel _captureLogLevel = DDLogLevelVerbose;

@implementation DDASLLogCapture

+ (void)start {
    // Ignore subsequent calls
    if (!_cancel) {
        return;
    }

    _cancel = NO;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        [DDASLLogCapture captureAslLogs];
    });
}

+ (void)stop {
    _cancel = YES;
}

+ (DDLogLevel)captureLogLevel {
    return _captureLogLevel;
}

+ (void)setCaptureLogLevel:(DDLogLevel)LOG_LEVEL_XXX {
    _captureLogLevel = LOG_LEVEL_XXX;
}

# pragma mark - Private methods

+ (void)configureAslQuery:(aslmsg)query {
    const char param[] = "7";  // ASL_LEVEL_DEBUG, which is everything. We'll rely on regular DDlog log level to filter

    asl_set_query(query, ASL_KEY_LEVEL, param, ASL_QUERY_OP_LESS_EQUAL | ASL_QUERY_OP_NUMERIC);

#if !TARGET_OS_IPHONE || TARGET_IPHONE_SIMULATOR
    int processId = [[NSProcessInfo processInfo] processIdentifier];
    char pid[16];
    sprintf(pid, "%d", processId);
    asl_set_query(query, ASL_KEY_PID, pid, ASL_QUERY_OP_EQUAL | ASL_QUERY_OP_NUMERIC);
#endif
}

+ (void)aslMessageRecieved:(aslmsg)msg {
    //  NSString * sender = [NSString stringWithCString:asl_get(msg, ASL_KEY_SENDER) encoding:NSUTF8StringEncoding];
    NSString *message = @(asl_get(msg, ASL_KEY_MSG));
    NSString *level = @(asl_get(msg, ASL_KEY_LEVEL));
    NSString *secondsStr = @(asl_get(msg, ASL_KEY_TIME));
    NSString *nanoStr = @(asl_get(msg, ASL_KEY_TIME_NSEC));

    NSTimeInterval seconds = [secondsStr doubleValue];
    NSTimeInterval nanoSeconds = [nanoStr doubleValue];
    NSTimeInterval totalSeconds = seconds + (nanoSeconds / 1e9);

    NSDate *timeStamp = [NSDate dateWithTimeIntervalSince1970:totalSeconds];

    int flag;
    BOOL async;

    switch ([level intValue]) {
        // By default all NSLog's with a ASL_LEVEL_WARNING level
        case ASL_LEVEL_EMERG    :
        case ASL_LEVEL_ALERT    :
        case ASL_LEVEL_CRIT     : flag = DDLogFlagError;    async = LOG_ASYNC_ERROR;    break;
        case ASL_LEVEL_ERR      : flag = DDLogFlagWarning;  async = LOG_ASYNC_WARN;     break;
        case ASL_LEVEL_WARNING  : flag = DDLogFlagInfo;     async = LOG_ASYNC_INFO;     break;
        case ASL_LEVEL_NOTICE   : flag = DDLogFlagDebug;    async = LOG_ASYNC_DEBUG;    break;
        case ASL_LEVEL_INFO     :
        case ASL_LEVEL_DEBUG    :
        default                 : flag = DDLogFlagVerbose;  async = LOG_ASYNC_VERBOSE;  break;
    }

    if (!(_captureLogLevel & flag)) {
        return;
    }

    DDLogMessage *logMessage = [[DDLogMessage alloc]initWithLogMsg:message
                                                             level:_captureLogLevel
                                                              flag:flag
                                                           context:0
                                                              file:"DDASLLogCapture"
                                                          function:0
                                                              line:0
                                                               tag:nil
                                                           options:0
                                                         timestamp:timeStamp];

    [DDLog log:async message:logMessage];
}

static aslmsg priv_ASLNext(aslresponse response)
{
#if defined(__IPHONE_7_0) || defined(__MAC_10_10)
#if MACOSX_DEPLOYMENT_TARGET < __MAC_10_10 || IOS_DEPLOYMENT_TARGET < __IPHONE_7_0
    if (asl_next)
#endif
        return asl_next(response);
#if MACOSX_DEPLOYMENT_TARGET < __MAC_10_10 || IOS_DEPLOYMENT_TARGET < __IPHONE_7_0
    else
#endif
#endif
        return aslresponse_next(response);

}

static void priv_ASLRelease(aslresponse response)
{
#if defined(__IPHONE_7_0) || defined(__MAC_10_10)
#if MACOSX_DEPLOYMENT_TARGET < __MAC_10_10 || IOS_DEPLOYMENT_TARGET < __IPHONE_7_0
    if (asl_release)
#endif
        asl_release(response);
#if MACOSX_DEPLOYMENT_TARGET < __MAC_10_10 || IOS_DEPLOYMENT_TARGET < __IPHONE_7_0
    else
#endif
#endif
        aslresponse_free(response);
}

+ (void)captureAslLogs {
    @autoreleasepool
    {
        /*
           We use ASL_KEY_MSG_ID to see each message once, but there's no
           obvious way to get the "next" ID. To bootstrap the process, we'll
           search by timestamp until we've seen a message.
         */

        struct timeval timeval = {
            .tv_sec = 0
        };
        gettimeofday(&timeval, NULL);
        unsigned long long startTime = timeval.tv_sec;
        __block unsigned long long lastSeenID = 0;

        /*
           syslogd posts kNotifyASLDBUpdate (com.apple.system.logger.message)
           through the notify API when it saves messages to the ASL database.
           There is some coalescing - currently it is sent at most twice per
           second - but there is no documented guarantee about this. In any
           case, there may be multiple messages per notification.

           Notify notifications don't carry any payload, so we need to search
           for the messages.
         */
        int notifyToken = 0;  // Can be used to unregister with notify_cancel().
        notify_register_dispatch(kNotifyASLDBUpdate, &notifyToken, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^(int token)
        {
            // At least one message has been posted; build a search query.
            @autoreleasepool
            {
                aslmsg query = asl_new(ASL_TYPE_QUERY);
                char stringValue[64];

                if (lastSeenID > 0) {
                    snprintf(stringValue, sizeof stringValue, "%llu", lastSeenID);
                    asl_set_query(query, ASL_KEY_MSG_ID, stringValue, ASL_QUERY_OP_GREATER | ASL_QUERY_OP_NUMERIC);
                } else {
                    snprintf(stringValue, sizeof stringValue, "%llu", startTime);
                    asl_set_query(query, ASL_KEY_TIME, stringValue, ASL_QUERY_OP_GREATER_EQUAL | ASL_QUERY_OP_NUMERIC);
                }

                [DDASLLogCapture configureAslQuery:query];

                // Iterate over new messages.
                aslmsg msg;
                aslresponse response = asl_search(NULL, query);
                while ((msg = priv_ASLNext(response)))
                {
                    [DDASLLogCapture aslMessageRecieved:msg];

                    // Keep track of which messages we've seen.
                    lastSeenID = atoll(asl_get(msg, ASL_KEY_MSG_ID));
                }
                priv_ASLRelease(response);

                if (_cancel) {
                    notify_cancel(notifyToken);
                    return;
                }

                free(query);
            }
        });
    }
}

@end