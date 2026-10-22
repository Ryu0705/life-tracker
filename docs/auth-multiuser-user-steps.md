# サインインと複数人化 本人に頼む操作の手順（U1〜U9）

計画 `auth-multiuser-implementation-plan.md` §0-4 の U1〜U9 を、操作の順に書いた（2026-10-21 下書き・10-22 U7〜U9 を追加・AI）。値（クライアント ID・接続文字列・パスワード）はこのファイルにも会話にも書かない。画面の名前は Supabase・Google Cloud の版で変わることがあるので、見つからなければ近い名前のものを探す（【要確認】は AI が画面で確かめていない所）。

| # | いつまでに | 何のため |
|---|---|---|
| U1 | 段階 3 の前 | バックアップの手段を決める |
| U2・U3 | シミュレータで本物のサインインを確かめる前（計画 §2-8 の 3） | メールのサインイン・再設定・Google を動かす |
| U4 | 段階 3 の最初 | 本番のバックアップ |
| U5・U6 | 段階 3（本番に流す日） | 0013・0014 を流す |
| U7 | シミュレータでコードの流れを確かめる前（10-22 追加） | メールをリンクから 6 桁のコードに替える |
| U8 | 1〜3 はいつでも・4 は段階 3 の 0014 の後（10-22 追加） | 誰にでも確認のコードが届くように、送るための Gmail を Supabase に入れる |
| U9 | パスワードレスのアプリを本物の認証で確かめる前（10-22 追加） | サインインのメールを 6 桁のコードにし、期限を 10 分にする |

---

## U1. Supabase のプランを確かめる

1. Supabase のダッシュボード → 左下の組織（Organization）→ Billing
2. プランが **Free** か **Pro** 以上かを AI に伝える
   - Free なら、毎日の自動バックアップは無い。バックアップは U4 の `pg_dump` だけになる

## U2. Google Cloud で OAuth のクライアントを作る

1. https://console.cloud.google.com/ → 上のプロジェクトの選択 → 新しいプロジェクト（名前の例: `life-tracker`）
2. 「Google Auth Platform」（古い画面では「API とサービス」→「OAuth 同意画面」）
   - アプリの名前・サポートのメール（本人の Gmail）を入れる
   - 対象（Audience）は **外部**・公開の状態は **テスト** のまま
   - テストユーザーに本人の Gmail を足す
3. 「クライアント」→「クライアントを作成」→ 種類 **iOS**
   - Bundle ID: Xcode の LifeTracker の target → Signing & Capabilities の Bundle Identifier（repo に書かないので、Xcode で見る）
   - 作ると「クライアント ID」と「iOS の URL スキーム」（`com.googleusercontent.apps.` で始まる、逆順の ID）が出る
4. もう一度「クライアントを作成」→ 種類 **ウェブ アプリケーション**（名前の例: `life-tracker-supabase`）
   - Supabase がトークンを確かめるのに使う。リダイレクト URI は、ID トークンの方式（アプリの方式）では使わない【要確認: Supabase のダッシュボードが Web の Client Secret も求めるなら、ここで出たシークレットを U3 で入れる】
5. iOS のクライアント ID と URL スキームを、Mac の `~/dev/life-tracker/LifeTracker/LifeTracker.xcconfig`（repo に入らないファイル）の末尾の 2 行に入れる（今は `unset` の印）
   ```
   GOOGLE_IOS_CLIENT_ID = （iOS のクライアント ID）
   GOOGLE_REVERSED_CLIENT_ID = （iOS の URL スキーム）
   ```
   - 値の中の `//` は無いはず。あればコメント扱いになるので AI に言う
6. 終わったら「U2 済み」と AI に伝える（値は伝えない）

## U3. Supabase のダッシュボードの設定

【2026-10-23 注記】U3 は 10-21 に済み。その後 10-22 にサインインをメールのコードと Google だけにしたので、下のパスワードの長さ・文字種・再設定の確かめは使わなくなった（サーバーの設定は残る）。Email OTP expiration は U9 で 600 秒にした。今の設定の一覧は設計 `auth-multiuser-design.md` §8。

Authentication の中で次を変える。

| 場所【要確認: 版で名前が違う】 | 設定 |
|---|---|
| Sign In / Providers → Email | **Confirm email を ON**。Minimum password length を **12**、Password requirements は **「Letters and digits」（英字と数字）を選ぶ**（アプリの画面の検査と同じ。これより強い選択肢にすると、画面の案内とサーバーの理由がずれる）。**Email OTP expiration は 3600 秒のまま**（アプリが再設定を見分ける印の 1 時間と同じ） |
| Sign In / Providers → Google | **有効**。Client IDs に **Web のクライアント ID と iOS のクライアント ID をコンマで区切って 2 つ**。**Skip nonce check は OFF のまま**（アプリは nonce を渡す） |
| Sign In / Providers（ユーザー登録の設定） | **Allow new users to sign up を OFF**（新規登録を閉じる。開くのはこのトグル 1 つ）→ **2026-10-22 本人「今すぐ開ける」で ON にした（12:1x 本人「ONにした」）** |
| 同じ画面 | **Allow manual linking は OFF**・**Allow anonymous sign-ins は OFF** |
| URL Configuration → Redirect URLs | **`lifetracker://auth-callback`** を足す（Site URL は変えない） |

- 終わったら「U3 済み」と AI に伝える。AI はシミュレータで、本物の認証とメモリ上のデータでサインイン・再設定・Google を確かめる（本番のデータには触れない。計画 §2-8 の 3）
- パスワードの再設定を試すときは、シミュレータにパスワードを入れるのは本人（会話に書かない）

## U4. 本番のバックアップ（段階 3 の最初）

本人のターミナルで流す（Claude Code の `!` は使わない。会話に残るため）。

1. ダッシュボード → 上の「Connect」→ **Session pooler** の接続文字列を写す
2. 写した文字列の `:[YOUR-PASSWORD]` の部分を消す（`postgresql://postgres.xxxx@...` の形にする。パスワードは聞かれたときに入れる）
3. 次を流す（`<接続文字列>` を 2 の文字列に。日付は流す日に）
   ```
   mkdir -p ~/Backups/life-tracker
   pg_dump "<接続文字列>" --schema=public --schema=private -Fc -f ~/Backups/life-tracker/2026-10-XX-before-0013.dump
   ```
   - `pg_dump` は 17 以上（この Mac の 18.0 でよい。AI が docker の 17 で戻せることを確かめた）
   - `auth` は取らない（パスワードのハッシュを手元に置かない）
4. 終わったら、ファイルの場所だけを AI に伝える。AI がそれを docker に戻してリハーサルする（計画 §3-1）

## U5・U6. 本番に流す日（段階 3・本人の OK の後）

1. **U6**: Mac に iPhone をつなぎ、Xcode で新しいビルドを iPhone に入れて、サインインの画面が出るところまで見る
   - 入れてから 0014 を流すまで、トレーニングタブとプロフィール・体重・週の目標の保存は使えない（予定・睡眠は動く）。トレーニングの記録中には流さない
   - サインインの画面が出た時点で、ホーム画面のウィジェットは「アプリでサインインしてください」になる（正常。サインインすると戻る）
2. AI が「今から流します」と言ったら、**MCP の確認の画面をすぐ承認する**（**U5**。0013 と 0014 で 2 回出る。遅れると `cancelled` で何も流れない）
3. 0014 の後、アプリを起動し直して、メールに届く 6 桁のコード（か Google）でサインインする → 全タブとウィジェットを見る（2026-10-23 直した。前はパスワード）
4. （2026-10-23 やめた: 前はメールのリンクを実機で開く確かめだったが、10-22 にサインインをコードにしたのでリンクは無い）

## U7. メールのテンプレートをコードに替える（2026-10-22 追加）

本人の決定（10-22）で、確認メールと再設定のメールはリンクをやめて 6 桁のコードにする。アプリはコードを画面で受ける。ダッシュボードの Authentication → **Emails**（Email Templates）で次の 2 つを替える【要確認: 画面の名前は版で違う】。

1. **Confirm signup**（新規登録の確認）
   - 件名: `LifeTracker の確認コード`
   - 本文（今の本文を消して、これに置き換える。`{{ .ConfirmationURL }}` は残さない）:
     ```html
     <h2>メールアドレスの確認</h2>
     <p>LifeTracker の確認コード: <strong>{{ .Token }}</strong></p>
     <p>アプリの画面にこのコードを入れてください。心当たりが無ければ、このメールは無視してください。</p>
     ```
2. **Reset password**（パスワードの再設定）
   - 件名: `LifeTracker のパスワード再設定コード`
   - 本文:
     ```html
     <h2>パスワードの再設定</h2>
     <p>LifeTracker の再設定コード: <strong>{{ .Token }}</strong></p>
     <p>アプリの画面にこのコードを入れてください。1 時間で使えなくなります。心当たりが無ければ、このメールは無視してください。</p>
     ```
3. Sign In / Providers → Email の **Email OTP Length を 6**、**Email OTP expiration は 3600 秒**のままにする（アプリは 6 桁を受ける）【要確認: 既定の長さ】
4. 終わったら「U7 済み」と AI に伝える。メールにリンク（`supabase.co` の URL）が入らなくなる

## U8. メールを送るための Gmail を Supabase に入れる（2026-10-22 追加）

本人の決定（10-22）で、誰でも登録できるようにする。標準のメール送信は Supabase のチームのメンバーにしか送らないので、送るためだけの Gmail を新しく作って、その SMTP で送る（後でドメインを買って Resend などに替えるときは、4 の設定を書き換えるだけ。アプリとテンプレートは変わらない）。Gmail のアドレスとアプリ パスワードは、このファイルにも会話にも書かない。

1. Google のアカウントを新しく作る（本人がいつも使う Gmail は使わない。送り手として登録する全員にアドレスが見えるため。名前の例: `LifeTracker`）
2. その新しいアカウントで https://myaccount.google.com/security → **2 段階認証プロセスを ON**
3. https://myaccount.google.com/apppasswords → アプリ名（例: `supabase`）を入れて作る → 出てきた 16 文字（空白を除く）を控える【要確認: 画面の名前は版で違う】
4. **段階 3 の 0014 の後に**、Supabase のダッシュボード → Authentication → Emails → **SMTP Settings**（Enable custom SMTP を ON）【要確認: 場所は版で違う】
   | 欄 | 入れるもの |
   |---|---|
   | Sender email | 1 で作った Gmail のアドレス（Gmail は、サインインしたアカウント以外の送り手を使わせない） |
   | Sender name | `LifeTracker` |
   | Host | `smtp.gmail.com` |
   | Port | `587` |
   | Username | 1 で作った Gmail のアドレス |
   | Password | 3 の 16 文字 |
   - 保存すると、全部のアドレスに送るようになり、はじめは 1 時間 30 通に制限される（Authentication → Rate Limits で変えられる。今はそのまま）
5. 終わったら「U8 済み」と AI に伝える。確かめは、新しい Gmail のアドレスでアプリから新規登録し、そのアドレスに 6 桁のコードが届くかを見る（チームのメンバーでないアドレスに届けば、誰にでも届く）。確かめに作ったアカウントは、後でダッシュボードの Users で消せる

## U9. サインインのメールをコードにし、期限を 10 分にする（2026-10-22 追加）

本人の決定（10-22）で、サインインはメールの 6 桁のコードと Google だけになる（パスワードは使わない）。はじめての人は確認のメール（Confirm signup・U7 でコードにした）、登録済みの人はサインインのメール（Magic Link）でコードが届く。ダッシュボードの Authentication → **Emails**（Email Templates）で次を替える【要確認: 画面の名前は版で違う】。

1. **Magic Link**（サインイン）
   - 件名: `LifeTracker のサインインコード`
   - 本文（今の本文を消して、これに置き換える。`{{ .ConfirmationURL }}` は残さない）:
     ```html
     <h2>サインイン</h2>
     <p>LifeTracker のサインインコード: <strong>{{ .Token }}</strong></p>
     <p>アプリの画面にこのコードを入れてください。有効期限は 10 分です。心当たりが無ければ、このメールは無視してください。</p>
     ```
2. **Confirm signup**（U7 で替えた本文）の 2 行目を次に替える（期限を書き足す）:
   ```html
   <p>アプリの画面にこのコードを入れてください。有効期限は 10 分です。心当たりが無ければ、このメールは無視してください。</p>
   ```
3. **Reset password** は、アプリから使わなくなる（パスワードを使わないため）。そのままでよい
4. Sign in with Apple は後（Program に入るとき）。今は何もしない
5. Sign In / Providers → Email の **Email OTP expiration を 600 秒**にする（今は 3600 秒。確認のコードにも効く見込み）。**Email OTP Length は 6 のまま**
6. 終わったら「U9 済み」と AI に伝える
   - **2026-10-22 本人「U9済み」**。文言は本人が「有効期限は 10 分です。」に直した（上の 2 つの本文はその文言にそろえた）

