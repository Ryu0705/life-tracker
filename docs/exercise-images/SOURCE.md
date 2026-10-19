# 種目のイメージ画像の出どころ

- 画像（`LifeTracker/LifeTracker/Assets.xcassets/Exercises/`）は、本人が ChatGPT（OpenAI の画像生成）で作ったもの。AI が作った画像で、人が描いたものではない。2026-10-15 から生成
- プロンプト: `prompts.md`（画風は試作 3 枚にそろえる）。経緯と決定: `../exercise-images-design.md`
- 権利: OpenAI の利用規約の「Ownership of content」に、出力（Output）の権利は利用者のもので OpenAI の権利は利用者に譲る、とある（2026-10-15 に検索結果の要約で確認。https://openai.com/policies/row-terms-of-use/ のページ本体は 403 で開けていない）。同じような出力がほかの利用者にも出うる
- 部位の図（一覧の絵の右下）は画像とは別物で、強さの人体図と同じ js-rich-body-highlighter（MIT）の素材から、アプリがその場で描く（`../body-diagram/`）

## 取り込み方
1. 画像を `~/Downloads/exercise-images/<sort_order>.png` に置く（番号は `supabase/migrations/0004_exercise_seed.sql` の sort_order。`prompts.md` の見出しの番号と同じ）
2. `python3 -I docs/exercise-images/build_assets.py ~/Downloads/exercise-images`
   - `Assets.xcassets/Exercises/Exercise<番号>.imageset`（840px 四方の JPEG・品質 85）と、生成物 `Sources/Views/Workout/ExerciseImageNames.swift`（種目名 → アセット名）を作り直す
   - 2026-10-15 の 3 枚で 1 枚 約 76KB（159 枚で約 12MB の見込み）
3. 単体テスト `ExerciseImageTests` で、対応表のすべての画像がアプリに入っていることを確かめる

試作の 3 枚: 101 ベンチプレス = workout_image1.png、208 ラットプルダウン = workout_image2.png（作り直すかは本人が決めるまで仮）、704 レッグプレス = workout_image3.png
