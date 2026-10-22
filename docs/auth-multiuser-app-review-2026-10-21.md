# サインインと複数人化 アプリ側レビュー（2026-10-21）

対象: 計画 `auth-multiuser-implementation-plan.md` §2（2-1〜2-8）で opus が書き、親が直した未 commit のアプリ側（`Sources/Auth/`・`Views/Auth/`・`LaunchPlan`・`DataAccessError`・`SignInSideEffects`・data source の変更・`LifeTrackerApp`・`Continuity`・`StreakWidget`・`RestAlerts`・`ProfileViews`・`Info.plist`・xcconfig の例・`project.pbxproj`・テスト）。土台は計画 §2・設計 §7・§9・計画のレビュー P1〜P24（食い違いは計画が正）。

- 読んだもの: 対象の全ファイル（新規は全文、変更は `git diff -w`）・計画・設計・計画のレビュー・0014 の view と関数と主キー・手元の supabase-swift 2.44.1（`AuthClient`・`SessionManager`・`APIClient`・`SupabaseClient`・`AuthError`・`Keychain`・`CodeVerifierStorage`・`Helpers.extractParams`）・GoogleSignIn-iOS 10.0.0（`GIDSignIn.h`・`GIDSignIn.m`）・GoTrue（supabase/auth master の `verify.go`・`resend.go`・`mail.go`。公開ソースを取得して読んだ）
- 実行したもの: 単体テスト `xcodebuild test ... -only-testing:LifeTrackerTests`（Debug・iPhone 17）→ **TEST SUCCEEDED・383 件 passed・0 failed**（ログは scratchpad。認証のファイルに warning 無し）。UI テスト・シミュレータの操作・本番・MCP・本物の認証は使っていない
- 書いたのはこのファイルだけ。対象のファイル・DB・Supabase・本物の認証には触れていない。秘密の値（UID・メールアドレス・キー・Bundle ID・クライアント ID）は書いていない。gitignore 済みの `LifeTracker.xcconfig` は開いていない
- 凡例: 【事実】ファイル・ライブラリのソース・実行で確かめた ／【推測】見立て。重さ: 高 = 本番で壊れる・守りの穴 ／ 中 = 直すべき ／ 低 = 好み・将来。番号は A1〜

---

## 要約

- **高 0・中 5・低 13**（A1〜A18）。本人に聞く点: **無し**
- 守り（依頼 1）は全体として計画どおりで、穴は見つからなかった【事実】: PKCE の `code` は端末の verifier（Keychain）無しでは使えない／implicit 形式はセッションを作らない／ログに URL・トークン・メールアドレスは出ない（`AuthFailure` だけを出す。URL を含む supabase-swift の文言は捨てている）／セッションと verifier は Keychain（`supabase.gotrue.swift`・AfterFirstUnlock・access group 無しでウィジェットから読めない）、印と Bool だけ UserDefaults／`-mock-*` と `XCTestConfigurationFilePath` は `LaunchPlan.make(isDebug:)` と `#if DEBUG` で Release に漏れない（Release 構成に `DEBUG` の条件無し）／Google の nonce は「SHA-256 の小文字 16 進を Google に・元の値を Supabase に」で、GoogleSignIn-iOS 10.0.0 は `nonce` を変えずに AppAuth へ渡す
- 中の 5 つ: (A1) 再送した確認メールのリンクは implicit 形式で戻る——GoTrue のソースで【推測】→【事実】に格上げ。fragment に有効なセッションが入り、カスタムスキームは横取りされうる。今は新規登録を閉じているので影響なし、配る前に直す／(A2) `linksInFlight` の守りをテストが検出しない（守りを消しても通る）／(A3)「テストの環境で `SupabaseClient` を作らない」のテストは、本番コードが使わない `needsSupabaseClient` を見ている／(A4) サインアウトで `GIDSignIn.signOut()` を呼ばず、Google の refresh token が Keychain に残る／(A5) 別の人のリンクで人が変わるとき、前の人の端末側の片付け（ウィジェットのスナップショット・休憩の通知）が走らない
- 0014 との整合（依頼 4）は一致【事実】: `exercise_for_user` の列は `Exercise` と同じ／衝突先 3 つは 0014 の主キー・一意と同じ／`user_id` を送らない／`fetchTaps` の投げ分け。P4 の主張（0014 前のビルドで予定・睡眠は動き、トレーニングと保存 3 つが止まる）も一致。0014 前に `ensure_user_defaults` が無い間は PGRST202 をログに流すだけで画面は出る
- 42501（依頼 3）: Supabase の読み書きは全部 `DataAccessGuard` を通る（grep で `client.from`・`client.rpc` は 2 つの data source だけ、計 55 か所（Day 22・Workout 33）がすべて `access.run` か `access.translate` の中）。`RuleErrorMapping` より先に変える。更新は 1 本（加えて supabase-swift 自身も in-flight を 1 本にまとめる）

---

## 指摘（中）

### A1（中・守り・配る前に）再送した確認メールのリンクは implicit 形式で戻る（【推測】→【事実】）。fragment のセッションは横取りされうる

- どこ: `Sources/Auth/AuthService.swift:51-61`（`isImplicitGrant`）、`Sources/Auth/AuthStore.swift:215-219, 330-342`、`Sources/Auth/SupabaseAuthService.swift:45-51`
- 何が起きるか【事実・GoTrue master のソース】:
  - `verify.go`: 戻りの形は **token の接頭辞**で決まる（`if strings.HasPrefix(params.Token, PKCEPrefix) { flowType = models.PKCEFlow }`。既定は implicit）。flow_state を人で引く形ではない
  - `resend.go`（`type=signup`）: `flowType := getFlowFromChallenge(params.CodeChallenge)`。`mail.go`: `u.ConfirmationToken = addFlowPrefixToToken(token, flowType)`。supabase-swift 2.44.1 の `resend` は `code_challenge` を送らない（`AuthClient.swift:1098-1123`・`ResendEmailParams` に欄が無い）→ 再送のリンクは implicit で、`lifetracker://auth-callback#access_token=...&refresh_token=...&type=signup` の形で戻る。計画の「見込み」は事実
  - このアプリはそれを `isImplicitGrant` で見分けてセッションを作らない（ログインの CSRF を避ける。妥当）。ただし fragment には**本人の有効なセッション（access・refresh）**が入っている。`lifetracker://` はカスタムスキームなので、同じスキームを名乗る別のアプリが入っていれば iOS がどちらを開くか決まらず、そちらに渡りうる（設計 §7 が PKCE を選んだ理由そのもの）。PKCE の `code` なら verifier 無しで無価値だが、implicit のトークンはそのまま使える
  - なお implicit のエラーは fragment だけに入る（`prepErrorRedirectURL`）。`#error=...` は `isImplicitGrant` が false → `session(from:)` → `isPKCEFlow`（`error_description` あり）→ `pkceGrantCodeExchange` →「リンクが無効です」。文言は正しく出る【事実・`AuthClient.swift:1462-1466`】
- 今の影響: 無し（新規登録はダッシュボードで閉じている・本人のアドレスは確認済み・再送は確認待ちの画面からしか呼べない）
- 直し方の案（配る準備のとき。計画の作業時間 10-21 17:5x の決定「配る準備のときに見直す」に合う）: 確認メールの型を `{{ .Token }}`（6 桁）にし、確認待ちの画面に入力欄を足して `verifyOTP(email:token:type: .signup)` で確認する（設計 §7 の代案。URL スキームに依らず、fragment にトークンが出ない）。再送は `resend` のまま（コードが届く）。それまでは新規登録を閉じたままにする、と計画の「本人に聞くこと・知らせること」か §2-8 の 4 に 1 行足す
- リンクのまま直す代案【事実・GoTrue master `signup.go`】: 未確認のアドレスで `/signup` をもう一度呼ぶと、GoTrue は既存の人をそのまま返し、`code_challenge` があれば `generateFlowState` → PKCE で確認メールを送り直す（supabase-swift の `signUp` は `code_challenge` を送る・`AuthClient.swift:287`）。つまり「再送」を `resend` でなく `signUp(email:password:)` の再呼び出しにすれば PKCE のまま。ただし確認待ちの画面はパスワードを持っていないので、再送のたびに入れてもらう形になる。6 桁コードの方が素直

### A2（中・テストの穴）`linksInFlight` の守り（リンクの処理中の `.signedIn` を無視）をテストが検出しない。守りを消しても通る

- どこ: `LifeTrackerTests/AuthStoreTests.swift:398-415`（`signedInEventDuringLinkDoesNotSkipNewPassword`）、守りは `Sources/Auth/AuthStore.swift:107-112, 220-221`
- 何が起きるか【推測・コードを追った】: このテストは最後に `phase == .newPassword` だけを見る。守りを消すと、先に届いた `.signedIn(A)` で `enterSignedIn(A)`（`phase = .signedIn`・`onSignedIn()`・`ensureUserDefaults` の Task）が走り、その後リンクの処理が `phase = .newPassword(A)` に上書きする。最終の phase は同じ `.newPassword` なので **テストは通る**。守りが守っているのは「新しいパスワードを決める前に `onSignedIn`（ウィジェットの印を true）と `ensure_user_defaults` が走らない」ことで、それを見ていない。`freshMarkLeadsToNewPassword`（:368-396）は `ensure.value == 0` を見るが、`.signedIn` を先に流していない
- あわせて: `FakeAuthService.session(from:)` の `Task.yield()` ×5（:72）で出来事が先に届くかは順序に依る。今は守りの有無で結果が変わらないので表に出ないが、下の直しを入れると順序依存が表に出る
- 直し方の案: (1) このテストに `ensureCount` と `onSignedIn` の記録（`SideEffectLog` の形）を足し、`.newPassword` の時点で `ensure.value == 0`・`onSignedIn` 未呼び出し、`saveNewPassword` の後に 1 回、を見る。(2) 順序を決めるため、`AuthStore` に `private(set) var appliedChanges = 0`（`apply` で +1。`@testable` 用）を足し、Fake は出来事を流した後に `waitUntil { store.appliedChanges == n }` してから返す（`Task.yield()` の回数に頼らない）

### A3（中・テストの穴）「テストの環境で `SupabaseClient` を作らない」のテストは、本番コードが使わない値を見ている

- どこ: `Sources/Services/LaunchPlan.swift:24-26`（`needsSupabaseClient`）、`LifeTrackerTests/AuthStoreTests.swift:620-664`（`LaunchPlanTests`）、`LifeTrackerApp.swift:46-61, 98-108`
- 何が起きるか【事実・grep】: `needsSupabaseClient` を参照するのはテストだけ。`makeSetup` は遅延の `client()`／`access()` を各分岐で呼ぶ形で、この値を見ない。今の `makeSetup` は正しい（`memoryDay`・`memoryWorkout`・`.mockSignedIn` の組ではどの分岐も `client()` を呼ばない）が、将来 `makeSetup` に `client()` を無条件で呼ぶ行（例: `access()` を先に作る）が入っても、このテストは落ちない。計画 §2-7「テストの環境で `SupabaseClient` を作らないこと」を確かめる形になっていない
- 良い点: `currentProcessIsTestEnvironment`（:631-636）は TEST_HOST のアプリに `XCTestConfigurationFilePath` が本当に渡っていることを見ていて、Xcode 側が変わったら落ちる砦になっている【事実・今回の実行で通った】
- 直し方の案: `makeSetup(plan:makeClient:)` の形で `makeClient` を引数（既定は今の `Self.makeClient`）にし、テストから「呼ばれたら `Issue.record`」する closure を渡して `LaunchPlan(auth: .mockSignedIn, memoryDay: true, memoryWorkout: true)` と `.mockSignedOut` で `makeSetup` を呼ぶ（`SignInSideEffects` も差し込めるようにしないと App Group に書くので、`sideEffects:` も引数にする → A5 の直しと同じ口）。`needsSupabaseClient` は消すか、`makeSetup` の `precondition` に使う

### A4（中・守り）サインアウトで `GIDSignIn.sharedInstance.signOut()` を呼ばず、Google の refresh token が端末の Keychain に残る

- どこ: `Sources/Services/SignInSideEffects.swift:22-27`、`Sources/Auth/GoogleSignInHelper.swift`（`signOut`・`disconnect` の呼び出し無し【事実・grep 0 件】）
- 何が起きるか【事実・GoogleSignIn-iOS 10.0.0 `GIDSignIn.m:1131, 1345-1348`】: サインインが成功すると `saveAuthState:` が `GTMKeychainStore` に auth state（Google の access／refresh token）を保存する（`restorePreviousSignIn` 用）。消すのは `signOut`（:553, 1342 `removeAuthSessionWithError:`）だけ。このアプリは `restorePreviousSignIn` を使わないので動作には出ないが、Supabase をサインアウトしても Google の refresh token は端末に残る。1 台を複数人で使う・端末を渡す場面で、前の人の Google の資格情報が残る
- 直し方の案: `SignInSideEffects.live.stopRestAlerts` と並べて `signOutGoogle: { GIDSignIn.sharedInstance.signOut() }` を足し、`signedOut()` の最後で呼ぶ（端末内の処理だけで、通信しない。Google 以外で入った人でも害は無い）。テストは closure の呼び出しを記録するだけでよい

### A5（中・状態）サインアウトを経ずに人が変わるとき（別の人のリンク・別の人の Google）、前の人の端末側の片付けが走らない

- どこ: `Sources/Auth/AuthStore.swift:293-311`（`enterSignedIn`）
- 何が起きるか【事実・コード】: `enterSignedIn(B)` は `phase` が `.signedIn(A)` でも `onSignedIn()` だけを呼び、`onSignedOut()`（スナップショットを消す・休憩の通知と Live Activity を止める）は呼ばない。経路: A でサインイン中に B の確認メール／再設定のリンクを開く（`handle(url:)` → `session(from:)` が端末のセッションを B に置き換える）、または `.signedIn(B)` がサーバーから届く。`MainTabView` は `.id(uid)` で作り直るので画面は B になるが、App Group の `continuity.v1` は A の記録のまま（B の `ContinuityStore` が書くまでウィジェットに A の連続週数が出る）、A の休憩の通知の予約は残る
- 頻度: 低い（1 台で 2 人が使い、サインアウトせずにリンクを開く）。今は本人 1 人
- 直し方の案: `enterSignedIn` で、`phase` が `.signedIn(old)`／`.newPassword(old)` かつ `old != userID` なら先に `onSignedOut()` を呼ぶ（その後 `onSignedIn()`）。テスト: `switchUser`（`AuthStoreTests.swift:213-219`）に `SideEffectLog` を足し、`["reload(... signedIn: false)", "stopRest", "reload(... signedIn: true)"]` の順を見る

---

## 指摘（低）

### A6（低・計画との食い違い）Google の設定が無いときの扱い: 計画は「ボタンを出さない」、実装は「出して、押すと『Google の設定がまだです』」

- どこ: `Sources/Views/Auth/SignInView.swift:68-76`、`Sources/Auth/GoogleSignInHelper.swift:68-70`、計画の作業時間 10-21 17:1x「印のままなら Google のボタンを出さない」、`LifeTracker.xcconfig.example` の注記（実装の形を書いている）
- 計画が正なら: `SignInView` で `GoogleSignInConfig.isConfigured(info: Bundle.main.infoDictionary ?? [:])` が false のときは Google の節を出さない（`AuthStore` に `isGoogleAvailable` を持たせ、テストでは closure で差し込む）。実装の形を採るなら計画の行を直す。どちらでも守りには影響しない

### A7（低・文言）「Mac など別の端末で開くと、登録が終わりません。」は不正確

- どこ: `Sources/Views/Auth/ConfirmationPendingView.swift:24`、`Sources/Views/Auth/SignUpView.swift:43`
- 【事実・GoTrue `verify.go`】リンクを開くと `/verify` が先にメールアドレスを確認済みにし、その後 `lifetracker://...?code=` へ転送する。Mac で開くと転送先が開けないだけで、確認はサーバーで済む。その人は iPhone のサインインの画面からメールとパスワードで入れる（`email_not_confirmed` にならない）。「登録が終わりません」だと、もう一度登録し直すものと読める
- 案: 「Mac など別の端末で開いたときは、この iPhone のサインインの画面からメールアドレスとパスワードで入ってください」

### A8（低・ログ）`ensure_user_defaults failed:` のログが、エラーの `String(describing:)` を公開で出す

- どこ: `Sources/Auth/AuthStore.swift:308`
- 【事実】ここに来る `error` は `DataAccessError`／`PostgrestError`／`URLError`。`URLError` の説明には失敗した URL（`https://<プロジェクトの ref>.supabase.co/rest/v1/rpc/ensure_user_defaults`）が入る。キー・トークン・メールアドレスは入らないので守りの穴ではないが、同じファイルの `log(_:during:)`（:360-362）と `DataAccessGuard`（型だけ。`DataAccessError.swift:102`）が守っている「中身を出さない」形に揃える
- 案: `String(describing: type(of: error))` と、`PostgrestError` なら `code` だけ

### A9（低・設定との連動）再設定の印の 1 時間は、ダッシュボードの「Email OTP expiration」（既定 3600 秒）と手で合わせている

- どこ: `Sources/Auth/AuthStore.swift:36`（`passwordResetMarkLifetime`）、`Sources/Views/Auth/PasswordResetRequestView.swift:45`（「1 時間以内に」）
- 【事実】リンクの期限はサーバー側の設定。設定を長くすると、1 時間を過ぎてから開いたリンクは「新しいパスワード」を出さずにそのままサインイン済みになる（`staleMarkSignsIn` のとおり）。短くすると印だけ残るが害は無い
- 案: 計画 U3 に「Email OTP expiration は 3600 秒のまま（アプリの印の 1 時間と同じ）」を 1 行足す。設定と文言を別々に変えないため

### A10（低・設定との連動）`PasswordPolicy` はダッシュボードの「Letters and digits」の設定と同じでないと、画面の文言がずれる

- どこ: `Sources/Auth/PasswordPolicy.swift:5-23`、`Sources/Auth/AuthFailure.swift:39`
- 【事実】画面は「12 文字以上・ASCII の英字と数字を含む」を先に検査し、サーバーの `weak_password` も同じ文言で出す。ダッシュボードで「Lowercase, uppercase letters and digits」以上を選ぶと、画面の検査は通るがサーバーで落ち、出る文言が「英字と数字を含めてください」のままになる（理由が伝わらない）
- 案: U3 に「文字種は『Letters and digits』を選ぶ」と明記（今の U3 は「英字と数字」）。将来強くするなら `PasswordPolicy` と同時に

### A11（低・docs）計画 §2-6「キーが無いときはサインイン済みとみなす（新しいビルドを入れた直後にウィジェットが変わらないように）」の理由は、22:4x の決定で薄れた

- どこ: `Shared/Continuity.swift`（`isSignedIn` の既定 true）、`Sources/Auth/AuthStore.swift:314-324`（起動中からの `enterSignedOut` でも片付ける）、計画 §2-6・作業時間 10-21 22:4x
- 【事実・コード】新しいビルドの最初の起動は端末にセッションが無い（今のビルドには認証が無い）ので `.initialSession(nil)` → `enterSignedOut` → `clearSnapshot` と `setSignedIn(false)` → ウィジェットは本人がサインインするまで「アプリでサインインしてください」になり、連続週数のスナップショットも消える。サインインすれば `ContinuityStore` が書き直す。挙動としては正しい（サインインしていないのは事実）。「キーが無い = サインイン済み」が効くのは、インストール後にアプリを起動する前にウィジェットが描き直される短い間だけ
- 案: 計画 §2-6 のこの行の理由を「起動前の短い間だけ」に直す。U6（0013 の直前に入れる）の手順に「サインインの画面を見た後、ウィジェットが『サインインしてください』になるのは正常」と 1 行

### A12（低・文言）再設定のメールを 2 回送ると、1 通目のリンクは「リンクが無効です。もう一度送ってください」になる

- どこ: `Sources/Auth/AuthFailure.swift:72-77`、supabase-swift `AuthClient.swift:1440-1455`（`prepareForPKCE` は verifier を 1 枠に上書き）
- 【事実】verifier は Keychain に 1 つ。2 通目を頼むと 1 通目の `code` は `bad_code_verifier` で失敗する。文言は「もう一度送って」だが、正しくは「最新のメールのリンクを開く」。害は無い（2 通目は通る）
- 案: `linkInvalid` の文言を「リンクが無効です。いちばん新しいメールのリンクを開くか、もう一度送ってください」に

### A13（低・将来）「新しいパスワード」の途中でアプリを落として起動し直すと、そのままサインイン済みになり、アプリの中にパスワードを決め直す口が無い

- どこ: `Sources/Auth/AuthStore.swift:100-106`（`.initialSession(uid)` は印を見ない）
- 【事実】再設定のリンクのセッションは普通のセッションなので、起動し直すと `.signedIn`。印は残る（1 時間以内に別の PKCE リンクを開けば出る）。サインアウトしてもう一度リンクを頼めば決め直せる。設定画面（食事で作る）ができれば「パスワードを変える」を置く
- 案: 今は直さない。`.initialSession(uid)` のときも印が新しければ `.newPassword` にする手もあるが、「確認メールのリンクを開いた直後に落ちた」場合も新しいパスワードの画面になるので採らない

### A14（低・開発時）`-mock-auth`／`-mock-auth-signed-out` でも `SignInSideEffects.live` を使うので、実機で起動すると App Group のスナップショットを消し、印を false にする

- どこ: `LifeTrackerApp.swift:111`
- 【事実・コード】メモリ上の認証でも起動時の `enterSignedOut`（`-mock-auth-signed-out`）や `signOut()` で本物の App Group に書き、`WidgetCenter.reloadAllTimelines()` と休憩の通知の取り消しをする。シミュレータでは害が無いが、開発者が実機で `-mock-*` を付けて起動すると本人のウィジェットの表示が消える（次に本物でサインインすれば戻る）
- 案: `plan.auth != .supabase` のときは `SignInSideEffects(defaults: nil, reloadWidgets: {}, stopRestAlerts: {})` にする（A3 の `makeSetup(plan:makeClient:sideEffects:)` と同じ口）

### A15（低・docs）Keychain のセッションはアプリを削除しても残る（iOS の仕様）

- 【事実・supabase-swift `KeychainLocalStorage`・`Keychain.swift:85`】セッションと verifier は Keychain（service `supabase.gotrue.swift`・`kSecAttrAccessibleAfterFirstUnlock`・access group 無し）。【推測・iOS の挙動として広く知られている。Apple の文書には明記が無い】iOS は同じ App ID の Keychain の項目をアプリの削除後も残すので、入れ直すとサインイン済みから始まる見込み。「削除 = サインアウト」ではない。端末を人に渡すときはサインアウトが要る
- 案: 設計 §7 のセッションの節に 1 行。アプリ側の変更は不要

### A16（低・docs）42501 は anon キーのほかにも返る（RLS の WITH CHECK 違反・`ensure_user_defaults` の `RAISE ... insufficient_privilege`）。そのときも「確認できませんでした。もう一度」＋更新になる

- どこ: `Sources/Services/DataAccessError.swift:24-28, 72-77`、0014 の `ensure_user_defaults`（`auth.uid()` が NULL なら 42501 を投げる）
- 【事実】今のアプリは `user_id` を送らず、`ensure_user_defaults` は JWT 付きでしか呼べないので、この経路は無い。将来 `user_id` を送る書き込み（MCP の形）をアプリに足すと、WITH CHECK 違反（403・42501）が「もう一度お試しください」になり、原因が伝わらない
- 案: `DataAccessError` の注記に「42501 は WITH CHECK 違反でも返る。アプリは `user_id` を送らないこと（設計 §1）」を 1 行

### A17（低・テストの穴）`SupabaseDayDataSource.apply`／`applyCheckIn` の「`translate` → `RuleErrorMapping`」の順はテストが無い

- どこ: `Sources/Services/SupabaseDayDataSource.swift:187-209`
- 【事実】`SupabaseClient` が要るので今の形では書けない。42501 が先に `DataAccessError` になり、`RuleErrorMapping` に渡らないことは読んで確かめた（正しい）
- 案: `static func classify(_ error: Error, access: DataAccessGuard, rule: (PostgrestError) -> Error?) -> Error` の純粋な関数に切り出し、`DataAccessGuardTests` に 2 件足す（42501 → `DataAccessError`、23514 → `RuleErrorMapping` の型）

### A18（低・テストの壊れやすさ）UI テストの「パスワードを保存しますか?」の閉じ方は、アプリの外の画面のボタンを位置（左）で選ぶ

- どこ: `LifeTrackerUITests/LifeTrackerUITests.swift:93-109`、repo の `CLAUDE.md` の注記
- 【事実】iOS の版で並びや文言が変わると、保存する側を押すか、閉じられずに `tab.workout` が押せなくなる。今の形（5 秒待って無ければ進む）は壊れたときに「サインインの後にタブが押せない」で落ちるので検出はできる
- 案: 今は残す。落ちたらまずここを疑う、と注記にある（`CLAUDE.md`）ので十分

---

## 確かめて問題なしだったもの（依頼 1〜7）

### 1. 守り
- **PKCE と URL**【事実・supabase-swift】`session(from:)` は `extractParams` で query と fragment の両方を読み、`.pkce` では `code` を `exchangeCodeForSession`（`/token?grant_type=pkce`・`code_verifier` は Keychain から）に渡す（`AuthClient.swift:612-640, 835-855, 908-925`）。横取りされた `code` は verifier 無しでは使えない。`code` の無い URL（implicit 形式）は `isPKCEFlow` が false で `pkceGrantCodeExchange("Not a valid PKCE flow URL: <URL 全体>")` を投げる——**この文言には fragment のトークンが入る**が、アプリは `.link` のときは文言を捨てて `linkInvalid` にし（`AuthFailure.swift:72-77`）、ログは `AuthFailure` の名前だけ（`AuthStore.swift:360-362`）。`handle(_:)`（URL ごとログに出す。`AuthClient.swift:823-831`）は使っていない。この形は保つこと（`.link` で `AuthError.message` をログに出さない）
- **Google の URL**: `AuthCallback.matches` が `lifetracker`＋`auth-callback` だけを AuthStore に渡し、ほかは `GIDSignIn.handle(url)`（`LifeTrackerApp.swift:181-187`）。GSI 10.0.0 の `handleURL` は path を見て違えば `NO` を返すだけ（`GIDSignIn.m:210-226`）
- **nonce**【事実】`GoogleNonce.makeRaw` は `SecRandomCopyBytes` 32 バイトの 16 進（64 文字）、`hashed` は UTF-8 の SHA-256 の小文字 16 進（`String(format: "%02x")`）。Google へは `hashed`、Supabase へは raw（`GoogleSignInHelper.swift:74-87`・`SupabaseAuthService.swift:69-77`）。GSI 10.0.0 は `signInWithPresentingViewController:hint:additionalScopes:nonce:completion:` から `nonce:options.nonce` をそのまま `OIDAuthorizationRequest` に渡す（`GIDSignIn.m:297-306, 899-907`）。テストは FIPS 180-2 の `"abc"` の値で確かめている（`AuthStoreTests.swift:552`）。GoTrue は `hex(sha256(nonce))` と ID トークンの `nonce` を比べる（計画のレビュー §0-3）ので通る。「Skip nonce check」は OFF のままでよい
- **ログ**: `AuthStore` は `AuthFailure` の名前と操作名だけ（`.unknown` の中身は GoTrue のエラーコードと文言で、メールアドレス・トークンは含まない）。`DataAccessGuard` は型名だけ。supabase-swift の `logger` は設定していないので何も出ない。GSI の URL も出さない。例外は A8（URL の ref）
- **Keychain と UserDefaults**: セッション・verifier は Keychain（`AuthLocalStorage.swift:11`・`CodeVerifierStorage.swift:17-32`）。印（時刻）は `UserDefaults.standard`、ウィジェットの印（Bool）は App Group。秘密は UserDefaults に無い。ウィジェットは Keychain を読めない（access group 無し）
- **再設定の印（P2）の悪用**: 印はただの出し分け。印があってもセッションは `code`＋verifier でしか作れない。他人の端末の印は他人の端末にしか置かれない。悪用の筋は無い。`handle(url:)` で印が新しいとき `.newPassword` になり、`saveNewPassword` は `update(user:)`（supabase-swift は `sessionManager.session()` でセッションを確かめてから PUT `/user`。`AuthClient.swift:1183-1211`）
- **テストの環境・DEBUG**【事実】`LaunchPlan.make(isDebug: false)` は引数も環境も見ない（`LaunchPlan.swift:31-33`・テスト `release`）。`MockAuthService` は `#if DEBUG`。`project.pbxproj` の `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"` は Debug 構成だけ（1 か所）。`-mock-no-profile`・`-mock-fetch-delay` も `#if DEBUG` の中。単体テストは `XCTestConfigurationFilePath` でメモリ上に切り替わり、テストから `SupabaseClient` を作る所は無い（grep 0 件）。UI テストは 3 か所とも起動引数を渡す（P10）
- **`Info.plist`・xcconfig**: `CFBundleURLTypes` は `lifetracker` と `$(GOOGLE_REVERSED_CLIENT_ID)` の 2 つ、`GIDClientID` は `$(GOOGLE_IOS_CLIENT_ID)`。例は `unset`・`com.googleusercontent.apps.unset`。`isConfigured` は空・`unset`・展開されない `$(`・`.unset` を全部「未設定」にする（テストあり）。`-ObjC` は無く、P20 のとおり不要。GoogleSignIn-iOS は 10.0.0 で固定（`Package.resolved`。AppAuth 3.0.0・GTMAppAuth 6.0.0）

### 2. 状態の正しさ
- **出来事の順の組み合わせ**【事実・コード】`.initialSession` は起動中だけ受ける（2 回目は無視）／`.signedIn` はリンクの処理中と「同じ人の `.newPassword`」で無視、ほかは `enterSignedIn`（同じ phase なら `onSignedIn` を呼ばない・`ensure` は UID ごと 1 回）／`.signedOut` はセッションのある状態と起動中だけ `enterSignedOut`、確認待ち・未サインインは動かさない／`.updated` は何もしない。サインイン（メール・Google・リンク・新規登録でセッション）はどれも直接 `enterSignedIn` を呼び、同じ出来事が前後どちらに届いても二重にならない
- **`emitLocalSessionAsInitialSession: true`**【事実・`AuthClient.swift:1403-1414`】端末のセッションを期限切れでもそのまま `.initialSession` で流し、期限切れなら裏で `try? refreshSession`。更新が通信で落ちても何も出ない。サーバーが `session_not_found`／`session_expired`／`refresh_token_not_found`／`refresh_token_already_used` を返したときだけセッションを消して `.signedOut`（`APIClient.swift` の `sessionCleanupErrorCodes`）。計画 §2-1 の記述と一致
- **オフラインの起動**: `.initialSession(uid)` → サインイン済み → `ensure` と各 store の読み込みは `URLError`（42501 ではない）→ 文言は今までの「通信できません」系。サインインの画面には戻らない（§2-8 の 3「機内モード」の期待どおり）
- **サインアウトの失敗**【事実・`AuthClient.swift:972-1002`】supabase-swift はセッションが無ければ何もせず戻り（`.signedOut` も出ない）、あれば先に端末のセッションを消して `.signedOut` を流してから `/logout`（401・403・404 は無視、通信の失敗は投げる）。`AuthStore.signOut()` は結果に依らず `enterSignedOut`。`.signedOut` が先に届いても後に届いても片付けは 1 回（`hadSession` で判定）
- **`.id(uid)`**: `MainTabView(...).id(userID)`。未サインインに切り替わると `switch` の分岐が変わって `MainTabView` ごと消えるので、同じ人で入り直しても `@StateObject` は作り直る。`UserDefaults`・`@AppStorage` を使う store は無い（grep 0 件）ので、人ごとに残る端末側の状態は App Group の 2 キーだけ
- **`ensure_user_defaults`**: `ScheduleDataSource.ensureUserDefaults()` 経由で `access.run`。失敗はログだけ。`ensuredUserID` でサインイン 1 回につき 1 回、サインアウトでリセット。新しい人で catalog の読み込みと競走するが、本人（行がある）では関係ない
- **片付け**: `enterSignedOut` だけから `onSignedOut`、`enterSignedIn` だけから `onSignedIn`。順は「スナップショットを消す → 印 false → reload → 休憩の通知の予約を消して Live Activity を終える」（`SignInSideEffects.swift:22-27`。計画 §2-6 どおり）。`RestAlerts.cancelAll` は `@MainActor` で `enterSignedOut`（MainActor）から呼ばれる。例外は A5（人が変わるとき）

### 3. 42501（P9）
- **包みの漏れ**【事実・grep】`client.from(`・`client.rpc(` は `SupabaseDayDataSource`（22 か所・11 メソッド）と `SupabaseWorkoutDataSource`（33 か所・28 メソッド）だけ。Day は `loadDayContext`（中の `async let` 8 本と `fetchTaps`）・`loadTodos`・`fetchCatalog`・`createCategory`・`ensureUserDefaults`・睡眠 4 つが `access.run`、`apply`・`applyCheckIn`・`fetchTaps` が `access.translate`。Workout は 28 メソッド全部 `access.run`。`SupabaseClient` を持つのは App・認証の層・2 つの data source・`SupabaseSessionAccess` だけ
- **`RuleErrorMapping` との順**: `translate` が先。42501 は `DataAccessError` になって `RuleErrorMapping` に渡らない。ほかの `PostgrestError` は今までどおり（`SupabaseDayDataSource.swift:187-209`）。`SleepRules.message(for:)` は `DataAccessError` を先に見る（`SleepRules.swift:355`）。`fetchTaps` は `translate` した上で `DataAccessError` だけ投げ、ほかは空（R2 を保つ）
- **更新 1 本**: `DataAccessGuard` は `NSLock` の `refreshing` で 1 本。さらに supabase-swift 自身も `inFlightRefreshTask` で同時の更新を 1 本にまとめる（`SessionManager.swift`）ので、データの呼び出しの `session` getter の更新と `DataAccessGuard` の更新がぶつかっても二重には送らない。更新が無効と返れば `.signedOut` → サインインの画面（`hasStoredSession` も false になり、以後は「サインインし直してください」）
- **文言の出し分け**: `hasStoredSession` は `currentSession != nil`（期限を見ない。`AuthClient.swift:106-108`）。期限切れ＋更新失敗の直後は true →「確認できませんでした。もう一度お試しください」（P9 どおり）。セッション無しは「サインインし直してください」。`SleepRulesTests` の 42501 の期待も新しい文言に直してある。`PGRST3xx` も同じ扱い

### 4. 0014 との整合
- `exercise_for_user` の列（`id, name, muscle_group, equipment, metric_kind, note, is_archived, sort_order`）は `Exercise`（`Workout.swift:6-14`）と同じ【事実】。`.eq("is_archived", false)`・`.order("sort_order")` は view の列で通る
- 衝突先: `user_profile_pkey PRIMARY KEY (user_id)`（0014:202）／`body_weight_record_pkey (user_id, recorded_on)`（:207）／`training_goal_user_id_effective_from_key UNIQUE (user_id, effective_from)`（:217）と `Conflict` の 3 つが一致。`ProfileRow` に `id` 無し、`WeeklyGoalRow`・`BodyWeightRecord` に `user_id` 無し（テスト `payloadColumns` が JSON のキーで見ている）
- **P4（0014 の前の本番に新しいビルドを入れた間）**【事実・コードと 0014】動く: 認証・予定タブ（表 7 つと RPC）・睡眠タブ・`fetchTaps`・トレーニングの読み（`routine`・`workout_*`・`training_goal`・`user_profile`・`body_weight_record`・`workout_training_day`）・ウィジェットのスナップショット（`ContinuityStore` は `fetchTrainingDays`＋`fetchWeeklyGoals`）・前日のセッションを閉じる自動の書き込み（`WorkoutSessionStore.close(staleSession:)` → `endSession`／`deleteSession`。`user_id` 無しで入り、0014 の e が拾う）。止まる: 種目の一覧（`exercise_for_user` が無い → PGRST205。トレーニングタブの読み込みの失敗）・プロフィール／週の目標／体重の保存（`on_conflict` の列が無い）・`ensure_user_defaults`（PGRST202 → ログだけ、画面は出る。0014 の後に起動し直すとまた呼ぶ。本人では何も作らない）。計画の前提の節の主張と一致
- 0014 の `ensure_user_defaults` は `auth.uid()` が NULL なら 42501 を投げる → アプリは A16 の扱い。JWT 付きで呼ぶので起きない

### 5. 画面と文言
- 文言はすべて日本語。alert の題「リンクを開けませんでした」、起動中の `accessibilityLabel`「読み込み中」も日本語
- 存在を隠す【事実・GoTrue master の `signup.go`・`resend.go`・`token.go` を読んだ】: 新規登録は `signupDisabled`・`weakPassword`・`network` 以外を「確認メールを送りました」に（GoTrue は `DisableSignup` を先頭で見てからアドレスを引くので、閉じている間はどのアドレスでも同じ 422。開いているときは、確認済みの既存のアドレスには `sanitizeUser` で id を作り直した 200 を返す＝アプリの `.user` → 確認待ち）／再送は `network` 以外「送りました」（GoTrue は確認済みのアドレスには何もせず 200）／再設定は `network` 以外「メールを送りました」、印は成功のときだけ。サインインの `email_not_confirmed` は GoTrue がパスワードの照合（`isValidPassword`）の後にしか返さないので、存在の漏れにはならない
- パスワードの規則: 新規登録と新しいパスワードで先に検査、サインインでは検査しない（前からの短いパスワードを通す。妥当）。全角の英数字は数えない（テストあり）
- 60 秒の再送: `confirmationSentAt` を新規登録の成功・再送のたびに置き、`TimelineView(.periodic)` で残り秒を出す。`email_not_confirmed` から来たときは即再送できる（サーバーの 60 秒の制限に当たれば `rateLimited` を隠して「送りました」。妥当）
- 確認待ちの案内: 「このメールをこの iPhone で開いてください」（太字・識別子あり）。A7 の 1 文だけ不正確
- 新しいパスワードの出口: 「保存」→ `update(user:)` → 印を消してサインイン済み／「やめて、サインインの画面に戻る」→ 印を消してサインアウト（リンクは使い切りなので、やめたら新しいリンクが要る。妥当）

### 6. テスト
- 単体 383 件すべて成功（今回の実行）。認証の層の 2 ファイルは、状態の移り変わり（初期セッションあり／なし／`.signedOut`／確認待ち／人の切り替え）・再設定の印（新しい／古い／無い／通常のサインインで消す／やめる）・リンクの失敗 3 種・implicit 形式 5 件・nonce・設定の有無・`LaunchPlan` 4 件・サインアウトの片付け 6 件・`DataAccessGuard` 6 件・タップと衝突先と送る列、を見ている。本番につながる経路は無い（差し込んだ `UserDefaults`・Fake のサービス）
- 「通るべきでないのに通る」: A2・A3 の 2 つ。ほかの砦（`awaitingIgnoresSignedOut`・`serverSignedOut` の起動中の片付け・`refreshOnlyOnceWhileRunning`・`currentProcessIsTestEnvironment`）は、守りを消すと落ちる形になっている【推測・コードを追った】
- 見ていないもの: `SupabaseAuthService.authChanges()` の変換と `onTermination`（`AuthChange.from` は見ている）／`GoogleSignInHelper.signIn`（UI が要る。シミュレータで本物の Google で確かめる §2-8 の 3 に任せる）／A17

### 7. 計画 §2・P1〜P24 の充足（アプリ側）
- 2-1〜2-7 の各項目は、上の確認のとおり満たしている。食い違いは A6（Google のボタン）と A11（§2-6 の理由の文）だけ
- P2・P8・P9・P10・P19・P20 は満たしている。P22（このレビュー）
- 2-8（シミュレータ・本物の認証・実機のリンク）は親と本人の作業で、このレビューでは見ていない。本物の Google と再設定のリンクは U2・U3 の後に §2-8 の 3 で確かめる

---

## 本人に聞く点

無し。A1 の「配る前に 6 桁コードへ」は計画の作業時間（10-21 17:5x）にある決定の裏付けで、新しい方針ではない。ほかはすべて AI が直してよい細部

## 作業時間（JST）

- 2026-10-21 23:0x 開始。計画・設計・計画のレビュー → 対象の全ファイル → supabase-swift・GoogleSignIn のソース → GoTrue の公開ソース（verify・resend・mail）→ 単体テストの実行（TEST SUCCEEDED・383 件）→ このファイル
- 本番・MCP・本物の認証・UI テスト・シミュレータの操作は使っていない。対象のファイルは変えていない
