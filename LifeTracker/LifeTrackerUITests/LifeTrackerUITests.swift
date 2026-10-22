//
//  LifeTrackerUITests.swift
//  LifeTrackerUITests
//
//  Created by 山下竜之介 on 2026/04/26.
//

import XCTest

final class LifeTrackerUITests: XCTestCase {
    /// 本番につながない起動 (メモリ上のデータとサインイン済みの MockAuthService。計画 §2-7 P10)
    static let mockSignedIn = ["-mock-day", "-mock-workout", "-mock-auth"]
    /// メモリ上のデータと、未サインインから始める MockAuthService
    static let mockSignedOut = ["-mock-day", "-mock-workout", "-mock-auth-signed-out"]

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launchArguments = Self.mockSignedIn
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = Self.mockSignedIn
            app.launch()
        }
    }

    /// サインイン (メールアドレス →「コードを送る」→ コード (MockAuthService の 123456) →「認証」。2026-10-22 パスワードレスに替えた) →
    /// タブ → プロフィールのタブ → サインイン中のメールアドレス → サインアウト → サインインの画面
    /// (計画 §2-7 P10。2026-10-22 サインアウトを分析のプロフィールからプロフィールのタブへ移した)。
    /// 要素は accessibilityIdentifier で引く (画面の文言では引かない)
    @MainActor
    func testSignInThenSignOutFromProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.mockSignedOut
        app.launch()

        sendCode(app, to: "test@example.com")
        enterCodeAndVerify(app, "123456")

        let signOut = app.buttons["profile.signOut"]
        openTab(app, "tab.profile", landmark: signOut, "プロフィールのタブのサインアウト")

        // サインインしたメールアドレスが読むだけで出る
        let email = app.descendants(matching: .any)["profile.email"].firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 5), "アカウントのメールアドレス")
        XCTAssertTrue(email.label.contains("test@example.com"), "メールアドレスの行: \(email.label)")

        if !signOut.isHittable { app.swipeUp() }
        signOut.tap()

        // 確認のダイアログは同じ識別子の要素が 2 つ見える (iOS 26 のダイアログの作り)。最初の 1 つを押す
        let confirm = app.buttons["profile.signOut.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "サインアウトの確認")
        confirm.tap()

        XCTAssertTrue(app.textFields["auth.email"].waitForExistence(timeout: 10), "サインインの画面に戻る")
        XCTAssertFalse(app.buttons["tab.profile"].exists)
    }

    /// コードでサインイン (はじめての人と同じ手順。2026-10-22 パスワードの再設定のテストから置き換えた):
    /// メールアドレス →「コードを送る」→ コードの画面 (送り先・「認証」は 6 桁まで押せない・送り直しは 60 秒待つ) →
    /// 誤りのコード → 誤りの文言 →「変更」→ サインインの画面 (欄にメールアドレスが残る) → もう一度送る → 正しいコード → タブ
    @MainActor
    func testSignInWithCode() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.mockSignedOut
        app.launch()

        let address = "new@example.com"
        sendCode(app, to: address)

        let code = app.textFields["auth.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "コードの画面")
        let sentTo = app.staticTexts["auth.sentEmail"]
        XCTAssertTrue(sentTo.waitForExistence(timeout: 5), "送り先のメールアドレス")
        XCTAssertEqual(sentTo.label, address)
        let verify = app.buttons["auth.verifyCode"]
        XCTAssertFalse(verify.isEnabled, "6 桁になるまで「認証」は押せない")
        XCTAssertFalse(app.buttons["auth.resendCode"].isEnabled, "送り直しは 60 秒待つ")

        // 誤りのコード
        code.tap()
        code.typeText("000000")
        XCTAssertTrue(verify.isEnabled)
        verify.tap()
        let error = app.descendants(matching: .any)["auth.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "誤りの文言")
        XCTAssertTrue(code.exists, "コードの画面のまま")

        // 「変更」でサインインの画面へ。欄にメールアドレスが残っている
        app.buttons["auth.changeEmail"].tap()
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "サインインの画面に戻る")
        XCTAssertEqual(emailField.value as? String, address, "送ったメールアドレスが残る")

        // もう一度送って、正しいコード
        let send = app.buttons["auth.sendCode"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        enterCodeAndVerify(app, "123456")

        openTab(app, "tab.workout", landmark: app.buttons["workout.analysis"], "トレーニング")
    }

    /// サインインの後のタブから `identifier` のタブを開き、その中の `landmark` が出るのを待つ
    @MainActor
    private func openTab(_ app: XCUIApplication, _ identifier: String, landmark: XCUIElement, _ name: String) {
        let tab = app.buttons[identifier]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "サインインの後にタブが出る")
        XCTAssertTrue(tab.waitForHittable(timeout: 5), "タブが押せる")
        tab.tap()
        XCTAssertTrue(landmark.waitForExistence(timeout: 10), name)
    }

    /// サインインの画面: メールアドレスを入れて「コードを送る」(押せるのはメールアドレスを入れてから)
    @MainActor
    private func sendCode(_ app: XCUIApplication, to address: String) {
        let email = app.textFields["auth.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), "サインインの画面")
        let send = app.buttons["auth.sendCode"]
        XCTAssertFalse(send.isEnabled, "メールアドレスを入れるまで「コードを送る」は押せない")
        email.tap()
        email.typeText(address)
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    /// コードの画面: 6 桁を入れて「認証」
    @MainActor
    private func enterCodeAndVerify(_ app: XCUIApplication, _ value: String) {
        let code = app.textFields["auth.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10), "コードの画面")
        code.tap()
        code.typeText(value)
        app.buttons["auth.verifyCode"].tap()
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isHittable { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return exists && isHittable
    }
}
