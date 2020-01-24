// Software License Agreement (BSD License)
//
// Copyright (c) 2010-2020, Deusty, LLC
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

#import <CocoaLumberjack/DDDispatchQueueLogFormatter.h>
#import <pthread/pthread.h>

#if !__has_feature(objc_arc)
#error This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

#pragma mark - DDDispatchQueueLogFormatter

@interface DDDispatchQueueLogFormatter () {
    NSDateFormatter *_dateFormatter;      // Use [self stringFromDate]

    pthread_mutex_t _mutex;

    NSUInteger _minQueueLength;           // _prefix == Only access via atomic property
    NSUInteger _maxQueueLength;           // _prefix == Only access via atomic property
    NSMutableDictionary *_replacements;   // _prefix == Only access from within spinlock
}

@end


@implementation DDDispatchQueueLogFormatter

- (instancetype)init {
    if ((self = [super init])) {
        _dateFormatter = [self createDateFormatter];

        pthread_mutex_init(&_mutex, NULL);
        _replacements = [[NSMutableDictionary alloc] init];

        // Set default replacements:
        _replacements[@"com.apple.main-thread"] = @"main";
    }

    return self;
}

- (instancetype)initWithMode:(DDDispatchQueueLogFormatterMode)mode {
    return [self init];
}

- (void)dealloc {
    pthread_mutex_destroy(&_mutex);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Configuration
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@synthesize minQueueLength = _minQueueLength;
@synthesize maxQueueLength = _maxQueueLength;

- (NSString *)replacementStringForQueueLabel:(NSString *)longLabel {
    NSString *result = nil;

    pthread_mutex_lock(&_mutex);
    {
        result = _replacements[longLabel];
    }
    pthread_mutex_unlock(&_mutex);

    return result;
}

- (void)setReplacementString:(NSString *)shortLabel forQueueLabel:(NSString *)longLabel {
    pthread_mutex_lock(&_mutex);
    {
        if (shortLabel) {
            _replacements[longLabel] = shortLabel;
        } else {
            [_replacements removeObjectForKey:longLabel];
        }
    }
    pthread_mutex_unlock(&_mutex);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark DDLogFormatter
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSDateFormatter *)createDateFormatter {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [self configureDateFormatter:formatter];
    return formatter;
}

- (void)configureDateFormatter:(NSDateFormatter *)dateFormatter {
    [dateFormatter setFormatterBehavior:NSDateFormatterBehavior10_4];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss:SSS"];
    [dateFormatter setLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    [dateFormatter setCalendar:[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]];
}

- (NSString *)stringFromDate:(NSDate *)date {
    return [_dateFormatter stringFromDate:date];
}

- (NSString *)queueThreadLabelForLogMessage:(DDLogMessage *)logMessage {
    // As per the DDLogFormatter contract, this method is always invoked on the same thread/dispatch_queue

    NSUInteger minQueueLength = self.minQueueLength;
    NSUInteger maxQueueLength = self.maxQueueLength;

    // Get the name of the queue, thread, or machID (whichever we are to use).

    NSString *queueThreadLabel = nil;

    BOOL useQueueLabel = YES;
    BOOL useThreadName = NO;

    if (logMessage->_queueLabel) {
        // If you manually create a thread, it's dispatch_queue will have one of the thread names below.
        // Since all such threads have the same name, we'd prefer to use the threadName or the machThreadID.

        NSArray *names = @[
            @"com.apple.root.low-priority",
            @"com.apple.root.default-priority",
            @"com.apple.root.high-priority",
            @"com.apple.root.low-overcommit-priority",
            @"com.apple.root.default-overcommit-priority",
            @"com.apple.root.high-overcommit-priority",
            @"com.apple.root.default-qos.overcommit"
        ];

        for (NSString * name in names) {
            if ([logMessage->_queueLabel isEqualToString:name]) {
                useQueueLabel = NO;
                useThreadName = [logMessage->_threadName length] > 0;
                break;
            }
        }
    } else {
        useQueueLabel = NO;
        useThreadName = [logMessage->_threadName length] > 0;
    }

    if (useQueueLabel || useThreadName) {
        NSString *fullLabel;
        NSString *abrvLabel;

        if (useQueueLabel) {
            fullLabel = logMessage->_queueLabel;
        } else {
            fullLabel = logMessage->_threadName;
        }

        pthread_mutex_lock(&_mutex);
        {
            abrvLabel = _replacements[fullLabel];
        }
        pthread_mutex_unlock(&_mutex);

        if (abrvLabel) {
            queueThreadLabel = abrvLabel;
        } else {
            queueThreadLabel = fullLabel;
        }
    } else {
        queueThreadLabel = logMessage->_threadID;
    }

    // Now use the thread label in the output

    NSUInteger labelLength = [queueThreadLabel length];

    // labelLength > maxQueueLength : truncate
    // labelLength < minQueueLength : padding
    //                              : exact

    if ((maxQueueLength > 0) && (labelLength > maxQueueLength)) {
        // Truncate

        return [queueThreadLabel substringToIndex:maxQueueLength];
    } else if (labelLength < minQueueLength) {
        // Padding

        NSUInteger numSpaces = minQueueLength - labelLength;

        char spaces[numSpaces + 1];
        memset(spaces, ' ', numSpaces);
        spaces[numSpaces] = '\0';

        return [NSString stringWithFormat:@"%@%s", queueThreadLabel, spaces];
    } else {
        // Exact

        return queueThreadLabel;
    }
}

- (NSString *)formatLogMessage:(DDLogMessage *)logMessage {
    NSString *timestamp = [self stringFromDate:(logMessage->_timestamp)];
    NSString *queueThreadLabel = [self queueThreadLabelForLogMessage:logMessage];

    return [NSString stringWithFormat:@"%@ [%@] %@", timestamp, queueThreadLabel, logMessage->_message];
}

@end
