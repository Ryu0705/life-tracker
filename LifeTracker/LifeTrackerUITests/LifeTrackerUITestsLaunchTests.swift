//
//  LifeTrackerUITestsLaunchTests.swift
//  LifeTrackerUITests
//
//  Created by 山下竜之介 on 2026/04/26.
//

import XCTest

final class LifeTrackerUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        // 本番につながない起動 (計画 §2-7 P10)
        app.launchArguments = ["-mock-day", "-mock-workout", "-mock-auth"]
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
