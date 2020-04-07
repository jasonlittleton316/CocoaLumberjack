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

#if canImport(Combine)

@testable import CocoaLumberjackSwift
import Combine
import XCTest

@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
class DDLogCombineTests: XCTestCase {

    var subscriptions = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        DDLog.removeAllLoggers()
    }

    override func tearDown() {
        self.subscriptions.removeAll()
        DDLog.removeAllLoggers()
        super.tearDown()
    }

    func testMessagePublisherWithDDLogLevelAll() {

        DDLog.sharedInstance.messagePublisher()
            .sink(receiveValue: { _ in })
            .store(in: &self.subscriptions)

        XCTAssertEqual(DDLog.allLoggers.count, 1)
        XCTAssertEqual(DDLog.allLoggersWithLevel.count, 1)
        XCTAssertEqual(DDLog.allLoggersWithLevel.last?.level, .all)
    }

    func testMessagePublisherWithSpecifiedLevelMask() {

        DDLog.sharedInstance.messagePublisher(with: .error)
            .sink(receiveValue: { _ in })
            .store(in: &self.subscriptions)

        XCTAssertEqual(DDLog.allLoggers.count, 1)
        XCTAssertEqual(DDLog.allLoggersWithLevel.count, 1)
        XCTAssertEqual(DDLog.allLoggersWithLevel.last?.level, .error)
    }

    func testMessagePublisherRemovedWhenSubscriptionIsCanceled() {

        let sub = DDLog.sharedInstance.messagePublisher()
            .sink(receiveValue: { _ in })

        XCTAssertEqual(DDLog.allLoggers.count, 1)
        XCTAssertEqual(DDLog.allLoggersWithLevel.count, 1)
        XCTAssertEqual(DDLog.allLoggersWithLevel.last?.level, .all)

        sub.cancel()

        XCTAssertTrue(DDLog.allLoggers.isEmpty)
        XCTAssertTrue(DDLog.allLoggersWithLevel.isEmpty)
    }

    func testReceivedValuesWithDDLogLevelAll() {

        var reveicedValues = [DDLogMessage]()

        DDLog.sharedInstance.messagePublisher()
            .sink(receiveValue: { reveicedValues.append($0) })
            .store(in: &self.subscriptions)

        DDLogError("Error")
        DDLogWarn("Warn")
        DDLogInfo("Info")
        DDLogDebug("Debug")
        DDLogVerbose("Verbose")

        DDLog.flushLog()

        let messages = reveicedValues.map { $0.message }
        XCTAssertEqual(messages, ["Error",
                                  "Warn",
                                  "Info",
                                  "Debug",
                                  "Verbose"])

        let levels = reveicedValues.map { $0.flag }
        XCTAssertEqual(levels, [.error,
                                .warning,
                                .info,
                                .debug,
                                .verbose])
    }

    func testReceivedValuesWithDDLogLevelWarning() {

        var reveicedValues = [DDLogMessage]()

        DDLog.sharedInstance.messagePublisher(with: .warning)
            .sink(receiveValue: { reveicedValues.append($0) })
            .store(in: &self.subscriptions)

        DDLogError("Error")
        DDLogWarn("Warn")
        DDLogInfo("Info")
        DDLogDebug("Debug")
        DDLogVerbose("Verbose")

        DDLog.flushLog()

        let messages = reveicedValues.map { $0.message }
        XCTAssertEqual(messages, ["Error", "Warn"])

        let levels = reveicedValues.map { $0.flag }
        XCTAssertEqual(levels, [.error,
                                .warning])
    }
}

#endif
