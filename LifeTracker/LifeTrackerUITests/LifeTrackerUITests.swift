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

    /// 前の日に 0:30 に記録する (docs/training-day-implementation-plan.md 付録 B-5):
    /// `-mock-now` で 10/23(金) 0:30 に起動 → トレーニングのタブ → 週の帯で前の日 10/22(木) を選ぶ → 編集できる一覧が出る →
    /// 種目を足して ✓ → 前の日の合計が 1 セット増え、上の帯は前の日のまま。今日 (10/23) には点が付かない
    /// (確認用のデータは前の日にも記録がある (背中の日 3 種目 8 セット) ので、点は前の日の「記録あり」と今日の「無し」で見る)
    @MainActor
    func testRecordPreviousDayAfterMidnight() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.mockSignedIn + ["-mock-now", "2026-10-23T00:30:00+09:00"]
        app.launch()

        // サインイン済みで起動したときは、タブの識別子が付かないことがある (2026-10-23 の 2 回目の通しで、4 つのタブとも
        // identifier なしの階層を実測)。識別子か、タブの名前で引く
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "tab.workout", "トレーニング")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "トレーニングのタブ")
        tab.tap()
        XCTAssertTrue(app.buttons["workout.analysis"].waitForExistence(timeout: 10), "トレーニング")
        let previousDay = dayCell(app, "10/22(")
        XCTAssertTrue(previousDay.waitForExistence(timeout: 10), "週の帯の前の日")
        XCTAssertEqual(dayCell(app, "10/23(").label, "10/23(金)", "-mock-now の今日。まだ記録なし")
        previousDay.tap()

        // 前の日はまだ開いている (2:00 まで・今日に記録なし) ので、読むだけの画面ではなく編集できる一覧
        XCTAssertTrue(app.buttons["今日へ"].waitForExistence(timeout: 5), "上の帯は前の日")
        XCTAssertTrue(app.staticTexts["8セット"].waitForExistence(timeout: 5), "前の日の確認用の記録")
        let addExercise = app.buttons["種目を追加"]
        scrollUntilHittable(app, addExercise, "前の日の一覧の「種目を追加」")
        addExercise.tap()

        let bench = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ベンチプレス")).firstMatch
        XCTAssertTrue(bench.waitForExistence(timeout: 5), "種目の一覧")
        bench.tap()
        app.buttons["1種目を追加"].tap()

        // 足したカードの 1 行目 (前回の値で埋まっている) を ✓
        let check = app.buttons["セット1を記録"]
        scrollUntilHittable(app, check, "足したカードの 1 行目の ✓")
        check.tap()

        XCTAssertTrue(app.staticTexts["9セット"].waitForExistence(timeout: 5), "前の日の合計に入る")
        XCTAssertTrue(app.staticTexts["4種目"].exists)
        XCTAssertTrue(app.buttons["今日へ"].exists, "上の帯は前の日のまま")
        XCTAssertTrue(app.staticTexts["10/22(木)"].exists, "上の帯は前の日のまま")
        XCTAssertEqual(dayCell(app, "10/22(").label, "10/22(木) 記録あり", "前の日に点")
        XCTAssertEqual(dayCell(app, "10/23(").label, "10/23(金)", "今日 (時計の日) には点が付かない")
    }

    /// トレーニングの週の帯の日 (アクセシビリティの名前は「10/22(木)」＋記録があれば「 記録あり」)
    @MainActor
    private func dayCell(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// 一覧を上へ送って、要素が押せるところまで出す
    @MainActor
    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement, _ name: String) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForHittable(timeout: 5), name)
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
