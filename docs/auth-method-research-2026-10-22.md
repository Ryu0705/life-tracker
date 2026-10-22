# サインインの方法の調べ（2026-10-22）

本人の問い（10-22）「そもそもSlackのようにパスワードレスの方が良いのかな？」「最新のトレンドやセキュリティレベルをベースにどうすべきか検討したい。」への資料。本人の指示で軽めに調べた。設計は `auth-multiuser-design.md`。

凡例: 【事実】出典あり／【推測】。今の作り（未 commit）: メール＋パスワード（12 文字以上・英字と数字）＋Google。確認と再設定は 6 桁のコード（期限 3600 秒）。画面はメール →「次へ」→ パスワード。

## 結論（推奨）

**パスワードレスに寄せる。主はメールの 6 桁のコード＋Google。パスワードは「パスワードでサインイン」の小さな入口だけ残す（下の案 C の軽い形）。配る前に Sign in with Apple を足す。パスキーは Program とドメインができてから足す。**

- 今もメールのコードでパスワードを再設定できる。だから守りの底は、もともと「メールの受信箱」。パスワードを外しても底は下がらず、使い回し・推測の穴が消える（Free では漏えいの検査が使えない）【推測】
- サインインは新しい端末とサインアウトの後だけ。たまにしか使わないパスワードは忘れやすい。コードなら登録とサインインが 1 つの流れになる【推測】
- 大手も同じ向き。Slack の主はメールのコード・パスキー・Apple/Google。Microsoft は 2025-05 から新しいアカウントをパスワード無しが既定にした【事実】
- パスワードの入口を残すのは、審査用・テスト用・本人の今のアカウントのため。審査の人はメールのコードを受け取れない【推測】
- 注意: NIST はメールを「サインインの要素」に認めていない。ただ NIST は米国の政府向けの基準。今の作りも再設定がメールなので、実際の守りは変わらない【推測】

## 調べた事実

**NIST SP 800-63B-4**（2025-07 の最終版）【事実】
- パスワード: それだけで使うなら 15 文字以上。文字種の規則を課してはいけない（SHALL NOT）。よくある・漏れたパスワードの一覧と照らす（SHALL）。定期の変更は強いない（§3.1.1.2）
- メール: 「Email SHALL NOT be used for out-of-band authentication」（§3.1.3.1）。アドレスの確認のコードと再設定のコードは、この禁止に入らない
- コード: 6 桁以上。サインインのコードは 10 分で無効（§3.1.3）。メールで送る再設定のコードは 24 時間まで（§4.2）
- 同期するパスキー: AAL2 まで使える（AAL3 は不可）。AAL2 では、フィッシングに強い方法を少なくとも 1 つ選べるようにする（§2.2.3）

**動向**【事実】
- FIDO Alliance（2026-05-07）: 使われているパスキーは約 50 億。75% の人が 1 つ以上のアカウントでパスキーを有効にした
- Microsoft（2025-05-01）: 新しいアカウントは「passwordless by default」。サインインの成功率はパスキー約 98%、パスワード 32%
- Slack: メールのコード・パスキー・Apple/Google でサインインする。パスワードは一部の利用者（現場の従業員）だけ

**App Store**【事実】
- 4.8: Google のような第三者のサインインで主なアカウントを作るなら、同等のサインイン（名前とメールだけ・メールを隠せる・同意なく広告に使わない）も出す。自前のサインインだけなら要らない。Sign in with Apple は条件に合う。自前のメールのサインインが「同等」に入るかは書かれていない【推測: 入らない】
- 2.1(a): サインインがあるアプリは、審査用のアカウントを出す。出せないときは、Apple の事前の承認でデモのモード
- 5.1.1(v): アカウントを作れるアプリは、アプリの中で削除もできるようにする
- Apple の対応表（HTML の表を読んで確かめた）: Sign in with Apple と Associated Domains（パスキーに要る）は有料の Program だけ。無料のアカウントは使えない。設計 §「レビューで確かめていないもの」の未確認が解けた

**Supabase**【事実】
- メールのコード: `signInWithOTP(email:)` → `verifyOTP(type: .email)`。Magic Link のテンプレートに `{{ .Token }}` を入れるとコードになる。まだいない人は自動で登録される（`shouldCreateUser`）。期限は 86400 秒まで、文書は 3600 秒以下を勧める
- 制限: 同じ人へのコードは 60 秒に 1 回。`/verify` は IP ごとに 1 時間 360 回
- パスキー: 主のサインインに使える（`signInWithPasskey`）。ただし試験的で、supabase-swift 2.48.0 以上（今は 2.44.1）。登録には確認済みのユーザーが要る（最初はメールか Google）。iOS は `webcredentials` の Associated Domains（自分のドメイン・Program）が要る
- Sign in with Apple（ネイティブ）: `signInWithIdToken(provider: .apple)`。今の Google と同じ形。名前は最初のサインインでしか来ない
- MFA（TOTP）は全部のプロジェクトで無料。CAPTCHA（hCaptcha・Turnstile）は登録・サインイン・再設定に付けられる。文書の例は Web だけ（iOS は Web の画面が要る見込み【推測】）
- 審査用の固定のコード: 文書で見つかったのは電話番号用（`SMS_TEST_OTP`）だけ。メール用は見つからなかった

## 案の比べ

| 案 | 守り | 使い勝手 | 運用 | 今の作りからの差分 |
|---|---|---|---|---|
| A 今のまま | 底はメール（再設定）。パスワードの使い回し・推測の穴が残る。NIST の長さ・文字種と合わない | パスワードを覚える。2 段（1 画面にもできる） | 規則と再設定を持ち続ける | なし（1 画面なら画面だけ） |
| B コード＋Google | 底はメール。パスワードの穴が消える。コードはフィッシングで盗まれうる（A も同じ） | 覚えるものが無い。毎回メールを開く | メールが届くことが要。審査用の入口が無い | パスワードの作成・規則・再設定を外し、コードの送信を足す（入力欄は今のを使える【推測】） |
| **C（軽い形・推奨）** B＋パスワードの入口 | B と同じ。入口はパスワードを持つ人だけ（新しい人は作らない） | B と同じ。本人は今のパスワードも使える | 審査用・テスト用はパスワードで入る | B ＋ 今のパスワードのサインインを小さく残す |
| D パスキーが主 | 一番強い（フィッシングに強い） | Face ID だけで入れる | Program・ドメイン・試験的な API | 今は作れない。B・C の上に後から足せる |

Sign in with Apple: どの案でも、Google を出したまま配るなら足す（4.8）。Google をやめれば要らない。

## 今の設定で直すとよいもの

- コードでサインインするなら、Email OTP expiration を 3600 → 600 秒に。NIST はサインインのコードを 10 分で無効にする。当てられる時間も 6 分の 1 になる。この設定は確認・再設定のコードにも効く見込み【推測】。メールの文面（U7 の再設定のテンプレートの「1 時間で使えなくなります」）も合わせる（親の訂正 10-22: アプリの再設定の印はコードに替えたときに消したので、合わせるものは無い）
- A のままパスワードを作らせるなら、12 文字＋英字と数字 → 15 文字以上・文字種の規則なしに（NIST）

## 決裁チェックリスト（推奨の C の軽い形）

1. **要点**: 今「メール → 次へ → パスワード」（登録は別にパスワードを作り、コードで確認）→ 後「メール → コードを送る → 6 桁」。登録とサインインが同じ流れ。下に「パスワードでサインイン」の小さな入口。Google はそのまま。期限は 600 秒
2. **エッジケース**
   - コードのメールが迷惑メールに入る・遅れる → その人は入れない。Google が予備。送り手が Gmail の SMTP なので、迷惑メールの扱いを受けやすい【推測】
   - だれでも他人のアドレスにコードを送らせられる → 送り手の Gmail が止まる恐れ【推測】。同じ人へ 60 秒に 1 回、外部の SMTP は既定で 1 時間 30 通の上限がある。荒らされたら CAPTCHA を足す
   - Apple の「メールを非公開」の人: 中継のアドレスに送るには、送り手のアドレスを Apple に登録する（しないと戻ってくる）【事実】。同じ人でも Google のアカウントと別のユーザーになる【推測】
3. **戻し方**: サーバーのパスワードのサインインは止めない。画面を戻せば A に戻る。DB とデータは変えない。期限は設定の数字 1 つ
4. **記録**: 決定は `auth-multiuser-design.md`（本人の決定・§7）、期限の手順は `auth-multiuser-user-steps.md`
5. **ほかの案を採らない理由**: A はパスワードの穴と作るものが残り、守りの底は変わらない／B は審査用の入口が無い／D は Program・ドメインが無く、Supabase でも試験的（C の上に後から足せる）

## 本人の決定（2026-10-22 15:0x）

- サインインの主: **B（コード＋Google だけ）**（推奨は C の軽い形だった。パスワードの入口も無くす）
- コードの期限: **600 秒**
- Sign in with Apple: **Program に入るときに足す**
- B を選んだので、審査用の入り方（2.1(a)）は配る前に別に決める。経緯は `auth-multiuser-implementation-plan.md` の「本人の決定」

## 本人に決めてほしい問い

1. サインインの主: (1) C の軽い形（推奨）／(2) B（パスワードの入口も無し）／(3) A のまま（1 画面にまとめる）
2. コードの期限: (1) 600 秒（推奨）／(2) 3600 秒のまま
3. 配る前の Sign in with Apple: (1) Program に入るときに足す（推奨）／(2) Google をやめ、Apple も足さない

## 出典（2026-10-22 に確かめた）

- NIST SP 800-63B-4: https://pages.nist.gov/800-63-4/sp800-63b.html ・ 版と日付: https://csrc.nist.gov/pubs/sp/800/63/4/final
- FIDO Alliance（2026-05-07）: https://fidoalliance.org/fido-alliance-reports-accelerating-global-passkey-adoption-on-world-passkey-day-2026/
- Microsoft（2025-05-01）: https://www.microsoft.com/en-us/security/blog/2025/05/01/pushing-passkeys-forward-microsofts-latest-updates-for-simpler-safer-sign-ins/
- Slack: https://slack.com/intl/en-gb/help/articles/212681477
- App Store Review Guidelines（4.8・2.1(a)・5.1.1(v)）: https://developer.apple.com/app-store/review/guidelines/
- Apple の対応表: https://developer.apple.com/help/account/reference/supported-capabilities-ios ・ パスキーと Associated Domains: https://developer.apple.com/documentation/authenticationservices/supporting-passkeys ・ 中継のメール: https://developer.apple.com/help/account/capabilities/configure-private-email-relay-service/
- Supabase: メールのコード https://supabase.com/docs/guides/auth/auth-email-passwordless ・ 制限 https://supabase.com/docs/guides/auth/rate-limits ・ 本番の点検（期限 3600 秒以下） https://supabase.com/docs/guides/deployment/going-into-prod ・ パスキー https://supabase.com/docs/guides/auth/passkeys ・ Swift のパスキー https://supabase.com/docs/reference/swift/auth-signinwithpasskey ・ Apple https://supabase.com/docs/guides/auth/social-login/auth-apple ・ TOTP https://supabase.com/docs/guides/auth/auth-mfa/totp ・ CAPTCHA https://supabase.com/docs/guides/auth/auth-captcha ・ 試験用のコード https://supabase.com/docs/guides/self-hosting/self-hosted-phone-mfa
