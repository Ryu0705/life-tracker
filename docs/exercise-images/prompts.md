# 種目のイメージ画像のプロンプト（全 159 種目）

2026-10-15 作成。経緯と決定は `../exercise-images-design.md`。画風は試作 3 枚（ベンチプレス・ラットプルダウン・レッグプレス）にそろえる。

## 使い方

- 試作の 3 枚を作った ChatGPT の会話で続ける（2026-10-15 本人の予定）。3 枚が会話の中にあるので、画像の添付は要らない。下の「最初に送る文」の「試作の会話で続けるとき」を送り、返事が来たら、種目のプロンプトを 1 つずつ送る（1 回に 1 枚）
- 画風がずれてきたら、新しい会話に切り替える。試作の画像 `~/Downloads/workout_image1.png`〜`workout_image3.png` の 3 枚を添付して、「新しい会話で始めるとき」を送る（2026-10-17 注: ~/Downloads に workout_image1〜3.png はもう無い。**10/18 03:1x から添付は 3 枚: `~/Downloads/exercise-images/refs/ref-101.png`・`ref-302-20261018.png`・`ref-306-20261018.png`（101 ベンチプレス・302 ミリタリープレス・306 サイドレイズ）**。10/17 22:4x〜10/18 03:1x は 101 と作り直した 209 の 2 枚だったが、209 の髪は本人の決定で悪。**03:2x 本人が前・横からの候補もすべて「不自然で編み込み感ある」としたので、101・302・306 も使わない。今は下の「人物の見本を作る文」で、本人が認める人物の見本を作っている途中（決まったらその絵だけを添付する）**。**10/18 08:36 本人「顔も髪も良い」で人物の見本は `~/Downloads/exercise-images/portraits/B4-no-hair-ref.png` に決定。これからは B4 だけを添付し、下の「人物の見本 B4 を添付して作る文（v8）」を送る**。試作の 208・704 は頭頂部に渦と巻き毛の束があり、それが写るため外した。下の「髪の直し（2026-10-17 22:4x）」）
- 2026-10-16 追記: 1 つの会話で約 50 枚作ったところから、顔が若く細くなり、髪が長くぼさぼさになった（実測。経緯は `../exercise-images-design.md`）。これからは、新しい会話で試作 3 枚を添付して始め、20 枚ごとに新しい会話へ切り替える（20 は、ずれ始めた約 50 枚に余裕を見た目安）。種目の英文の末尾には、毎回「毎回の末尾に足す文」を足して送る
- 2026-10-17 追記（本人の指示）: できた絵の崩れが他の絵にも出うるもの（髪型・顔・体つき・肌・画風・背景・赤い筋肉の塗り方のように毎回同じ文から出る見た目、または同じ崩れが 2 枚以上に出たもの）なら、その 1 枚を送り直して先へ進まず、いったん生成を止めて、このファイルの「最初に送る文」「毎回の末尾に足す文」などを直してから続ける。崩れた絵で効き目を確かめてから再開し、直しても続くなら止めて本人に報告する。種目の文だけの問題（器具の持ち方・腕の数・姿勢）は送り直しで直す
- ChatGPT に送るのはコードブロックの中の英文だけ。見出しの下の「注記」「要確認」は本人向けのメモで、送らない。「要確認」の種目は、送る前に自分のやり方と合っているかを見て、違えば英文を直してから送る
- できた画像は、見出しの番号をファイル名にして `~/Downloads/exercise-images/` に保存する（例 `101.png`。フォルダが無ければ作る）
- 試作済み: 101 ベンチプレスと 704 レッグプレスは試作の画像をそのまま使う（`workout_image1.png`→`101.png`、`workout_image3.png`→`704.png` の名前の付け替えは AI が行う）。208 ラットプルダウンは作り直し用のプロンプトを載せた。作り直すかは本人が決める
- 節と件数: 胸 19・背中 20・僧帽筋 5・肩 15・上腕二頭 10・上腕三頭 11・前腕 5・大腿四頭 15・ハムストリング 8・臀部 7・ふくらはぎ 4・体幹 18・有酸素 13・全身 9（計 159）

## 最初に送る文

2 つの違いは最初の段落だけ（見本が「この会話で作った 3 枚」か「添付した 3 枚」か）。決まりの 1〜11 は同じ。2026-10-16 に、決まりの 2 へ顔・髪型・体つきを書き足し、10（体のつながり）を足した。2026-10-17 に、髪型を 11 として独り立ちさせ、具体的に書き直した（下の「毎回の末尾に足す文」の注記）

### 試作の会話で続けるとき

```
From now on I will ask you for a series of exercise illustrations, one per message. Every image must use exactly the same style, the same man, the same background and the same lighting as the three images you made earlier in this conversation (bench press, lat pulldown and leg press). Below I call those three images the references.

Rules for every image:
1. Square 1:1, clean 3D anatomical fitness illustration.
2. One athletic man, the same person as in the references in every image: an adult man of about 30 with a mature face, a strong square jaw and no beard; short dark hair exactly as in rule 11; a heavily muscular build with broad shoulders; smooth light-grey skin with clearly defined muscles, no shirt, black shorts, grey sneakers. No other people.
3. Only the muscles I list after "Red muscles:" are bright red. Every other muscle stays light grey.
4. All equipment is black, as in the references.
5. Draw the equipment exactly as I describe it. Seats, pads, rollers and handles are parts of the machine and touch his body exactly where I say.
6. His whole body and the whole piece of equipment are visible, nothing is cut off, and the scene is centered.
7. Plain very light grey background with soft studio lighting. No scenery and no floor clutter, even for outdoor activities.
8. No text, no labels, no numbers, no logos, no watermark (also nothing on machine screens).
9. Exactly one image per message.
10. Anatomically correct body: exactly two arms and two legs, each attached at the correct shoulder or hip and bending only in natural directions. A hand that holds something is clearly connected to its own arm.
11. Hair, the same in every image and from every angle: a short, neat taper haircut. The sides and the back are clipped very short and close to the head. The top is short (about 3 cm) and combed straight back, so it lies smooth and flat as one soft mass with only fine, thin strand lines. It is neatly combed with a little hair product, so the surface is smooth with a soft sheen and the hair stays together; it never splits into separate thick clumps, scale-like layers or twisted locks. Draw it as a smooth, sculpted hair surface with only subtle, fine lines, like a clean 3D model, not as many separate locks. Never braids, cornrows, plaits, twisted rope-like locks, dreadlocks, curls, a bun, a ponytail, or a spiral or swirl at the crown. Seen from the side or from behind, the short top lies in straight, parallel lines running from the forehead to the back of the head, and the back and the nape are clipped short and smooth, with the same smooth, sleek, slightly glossy surface as the hair in the references. Where the top meets the clipped back, the ends of the top hair fade smoothly into the short back: no ridge, no row of overlapping tufts and no braid-like line across the back of the head. When the back of his head is visible, it shows the same short, smooth, close-clipped hair with no pattern. The camera never looks down onto the top of his head: it stays at or below the height of his head, so his hair is always seen from the front, the side or the back at eye level.

Each of my messages will start with "Next image:" and the exercise name, then describe the equipment, his position, the moment of the movement, the red muscles and the camera view. Please reply to this message with a short "OK" only, and do not make an image yet.
```

### 新しい会話で始めるとき

```
I have attached three reference images (bench press, standing barbell press and dumbbell lateral raise). From now on I will ask you for a series of exercise illustrations, one per message. Every image must use exactly the same style, the same man, the same hair, the same background and the same lighting as these references.

Rules for every image:
1. Square 1:1, clean 3D anatomical fitness illustration.
2. One athletic man, the same person as in the references in every image: an adult man of about 30 with a mature face, a strong square jaw and no beard; short dark hair exactly as in rule 11; a heavily muscular build with broad shoulders; smooth light-grey skin with clearly defined muscles, no shirt, black shorts, grey sneakers. No other people.
3. Only the muscles I list after "Red muscles:" are bright red. Every other muscle stays light grey.
4. All equipment is black, as in the references.
5. Draw the equipment exactly as I describe it. Seats, pads, rollers and handles are parts of the machine and touch his body exactly where I say.
6. His whole body and the whole piece of equipment are visible, nothing is cut off, and the scene is centered.
7. Plain very light grey background with soft studio lighting. No scenery and no floor clutter, even for outdoor activities.
8. No text, no labels, no numbers, no logos, no watermark (also nothing on machine screens).
9. Exactly one image per message.
10. Anatomically correct body: exactly two arms and two legs, each attached at the correct shoulder or hip and bending only in natural directions. A hand that holds something is clearly connected to its own arm.
11. Hair, the same in every image and from every angle: a short, neat taper haircut. The sides and the back are clipped very short and close to the head. The top is short (about 3 cm) and combed straight back, so it lies smooth and flat as one soft mass with only fine, thin strand lines. It is neatly combed with a little hair product, so the surface is smooth with a soft sheen and the hair stays together; it never splits into separate thick clumps, scale-like layers or twisted locks. Draw it as a smooth, sculpted hair surface with only subtle, fine lines, like a clean 3D model, not as many separate locks. Never braids, cornrows, plaits, twisted rope-like locks, dreadlocks, curls, a bun, a ponytail, or a spiral or swirl at the crown. Seen from the side or from behind, the short top lies in straight, parallel lines running from the forehead to the back of the head, and the back and the nape are clipped short and smooth, with the same smooth, sleek, slightly glossy surface as the hair in the references. Where the top meets the clipped back, the ends of the top hair fade smoothly into the short back: no ridge, no row of overlapping tufts and no braid-like line across the back of the head. When the back of his head is visible, it shows the same short, smooth, close-clipped hair with no pattern. The camera never looks down onto the top of his head: it stays at or below the height of his head, so his hair is always seen from the front, the side or the back at eye level.

Each of my messages will start with "Next image:" and the exercise name, then describe the equipment, his position, the moment of the movement, the red muscles and the camera view. Please reply to this message with a short "OK" only, and do not make an image yet.
```

### 人物の見本を作る文（2026-10-18 追記）

本人（原文）「今のままだけど、そもそも人物の完璧な画像があればそれを見本として生成できるのでは？」を受けて、種目の絵とは別に、髪がはっきり写る人物の見本を作る。本人が完璧と認めたものだけを見本にする。最初は 2 通り試す: A 添付なし（今の絵の髪を写さないため）、B 試作 101 を添付して顔・体・画風だけ使わせる（下の 1 行目を足す）。前から決まったら、同じ会話で横・後ろからも頼む。

```
Please make one image: a character reference portrait for a series of 3D anatomical fitness illustrations.
- Square 1:1. Clean 3D anatomical fitness illustration style: smooth light-grey skin, a plain very light grey background, soft studio lighting. No text, no labels.
- One adult man of about 30 with a mature face, a strong square jaw and no beard, heavily muscular, no shirt. Head and shoulders, front three-quarter view, with the head large in the frame so his hair is clearly visible.
- Hair (the most important part): short dark hair in a neat taper haircut. The sides and the back are clipped very short and close to the head; the top is about 3 cm long and combed straight back. The hair must look like real, natural hair: made of thousands of very fine individual hairs, soft and slightly matte, with a natural, even texture. Do not draw it as sculpted clumps, ridges, grooves, scales, ropes, braids, twisted locks or cornrows. No separate locks at all.
```

B のときに先頭に足す文:

```
The attached image shows the style, the face and the body I want. Use it only for the style, the face and the body; do not copy its hair.
```

### 人物の見本を作る文 v2（2026-10-18 03:2x 本人の指示）

本人が髪の描き方の指示文を書いて渡した（本人（原文）「この指示を入れて試しに人物の見本を作ってみて」）。下の英文の「HAIR RENDERING」から最後までが本人の文（「Repetitive parallel rges」は「ridges」の打ち間違いとみて直した）。先頭の 3 行（画風・人物・構図）は AI の文。添付なしの新しい会話で送る。AI が先に自分の言い方で作った A1 は `~/Downloads/exercise-images/portraits/A1-own-wording.png` に残した（比べるため）。

```
Please make one image: a character reference portrait for a series of 3D anatomical fitness illustrations.
- Square 1:1. Clean 3D anatomical fitness illustration style: smooth light-grey skin, a plain very light grey background, soft studio lighting. No text, no labels.
- One adult man of about 30 with a mature face, a strong square jaw and no beard, heavily muscular, no shirt. Head and shoulders, front three-quarter view, with the head large in the frame so his hair is clearly visible.

HAIR RENDERING — CRITICAL REQUIREMENT

The character has short, naturally styled dark hair with a neat taper haircut.

The sides and back are closely cropped, gradually blending into approximately 3 cm of hair on top, naturally brushed backward.

Unlike the stylized 3D anatomical body, the hair must be rendered with photorealistic hair grooming.

The hair consists of tens of thousands of extremely fine, individual human hair strands, densely overlapping to form a natural, continuous hairstyle.

Individual hairs should be extremely thin and barely distinguishable at normal viewing distance.

The hair must have:
- Realistic human hair density and fine texture.
- Soft, natural, slightly matte highlights.
- Subtle variations in individual hair direction.
- Natural transitions between the top, sides, and back.
- Realistic short hair growth patterns.

STRICTLY FORBIDDEN:
- Thick sculpted hair clumps.
- Deep grooves between strands.
- Rope-like or twisted hair.
- Braids or cornrows.
- Repetitive parallel ridges.
- Plastic or clay-like hair surfaces.
- Exaggerated separation between strands.
- Artificially uniform hair patterns.

The hair should look like real human hair photographed under soft studio lighting, while the face and body retain the original clean 3D anatomical illustration style.

The hairstyle must not be constructed from visible hair clumps. Its shape should emerge naturally from the collective flow of thousands of fine, overlapping individual hairs.
```

### 人物の見本の顔を戻す文（2026-10-18 03:3x）

v2 の 1 枚目（`portraits/B1-user-hair-text.png`）に本人（原文）「髪の毛は今までのどの画像よりも良いが、顔が変わってしまっている。」。同じ会話で、306 から髪を外して顔だけ切り出した絵（`portraits/face-306.png`）を添付し、髪はそのまま顔だけ直すよう頼む。306 は 10/16 に顔が試作に近づいたあとの絵。

```
Please edit your last image. Keep his hair exactly as it is now: the same natural, fine, photorealistic short hair with the same shape, length and texture. Do not change the hair at all. Change only his face: make it the same man as in the attached face reference (the same eyes, eyebrows, nose, mouth, square jaw and face shape, about 30 years old). Keep the same clean 3D anatomical illustration style for the face and body, the same pose, light-grey skin and plain light-grey background.
```

### 人物の見本 v3（顔・体・髪を別々の添付から・2026-10-18 03:4x）

B2（`portraits/B2-face-from-306.png`）に本人（原文）「まだ顔違うね。」。前の絵を直す頼み方では、ChatGPT が B1 の顔を引きずる（推測）。そこで新しい絵として頼み、3 枚を順に添付して役割を分ける: 1 枚目 `portraits/face-306.png`（顔だけ）、2 枚目 `refs/ref-306-20261018.png`（体と描き方。306 は 10/16 に顔が試作に近づいた絵）、3 枚目 `portraits/B2-face-from-306.png`（髪だけ）。1・2 枚目の髪は使わないと書く。後ろに本人の髪の指示文（v2 と同じ）を足す。

```
Please make a new image (do not edit an earlier one): a character reference portrait for a series of 3D anatomical fitness illustrations. I have attached three images, in this order:
- Image 1, a close-up of a face: this is the man's FACE. Copy this face exactly: the same eyes, eyebrows, nose, lips, cheeks, jaw and face shape, and the same smooth, clean 3D illustration rendering of the face. Ignore the hair in this image.
- Image 2, a man doing a dumbbell lateral raise: this is the same man's body and the illustration STYLE of the series: smooth light-grey skin with clearly defined, cleanly drawn muscles, soft studio lighting and a plain very light grey background. Ignore the hair in this image.
- Image 3, a head-and-shoulders portrait: use this ONLY for the HAIR. Copy its hair exactly: the same short taper haircut, the same length and shape, and the same fine, natural, photorealistic hair texture. Do not copy the face, the skin or the lighting of image 3.

The result: square 1:1. Head and shoulders of this man, front three-quarter view, the head large in the frame, the camera at the height of his head. His face and body are exactly as in images 1 and 2: the same man in the same clean 3D anatomical illustration style. Only his hair is rendered photorealistically, exactly as in image 3. No text, no labels.

HAIR RENDERING — CRITICAL REQUIREMENT

The character has short, naturally styled dark hair with a neat taper haircut.

The sides and back are closely cropped, gradually blending into approximately 3 cm of hair on top, naturally brushed backward.

Unlike the stylized 3D anatomical body, the hair must be rendered with photorealistic hair grooming.

The hair consists of tens of thousands of extremely fine, individual human hair strands, densely overlapping to form a natural, continuous hairstyle.

Individual hairs should be extremely thin and barely distinguishable at normal viewing distance.

The hair must have:
- Realistic human hair density and fine texture.
- Soft, natural, slightly matte highlights.
- Subtle variations in individual hair direction.
- Natural transitions between the top, sides, and back.
- Realistic short hair growth patterns.

STRICTLY FORBIDDEN:
- Thick sculpted hair clumps.
- Deep grooves between strands.
- Rope-like or twisted hair.
- Braids or cornrows.
- Repetitive parallel ridges.
- Plastic or clay-like hair surfaces.
- Exaggerated separation between strands.
- Artificially uniform hair patterns.

The hair should look like real human hair photographed under soft studio lighting, while the face and body retain the original clean 3D anatomical illustration style.

The hairstyle must not be constructed from visible hair clumps. Its shape should emerge naturally from the collective flow of thousands of fine, overlapping individual hairs.
```

### 人物の見本 v4（髪の絵は添付しない・2026-10-18 03:4x）

v3 の結果（`portraits/B3-three-refs.png`）は、顔が 3 枚目（B2）とほぼ同じ人になり、306 の顔にならなかった（AI の見立て）。髪の見本の絵を添付すると顔も写る、と見て、髪の絵は外す。添付は 1 枚目 `portraits/face-306.png`（顔）・2 枚目 `refs/ref-306-20261018.png`（体と描き方）の 2 枚だけ。髪は本人の髪の指示文だけで描かせる（B1 は添付なし・この文だけで、今までで一番良い髪になった）。

```
Please make a new image (do not edit an earlier one): a character reference portrait for a series of 3D anatomical fitness illustrations. I have attached two images of the same man, in this order:
- Image 1, a close-up of his face: copy this face exactly: the same eyes, eyebrows, nose, lips, cheeks, jaw and face shape, the same soft, smooth features and the same clean 3D illustration rendering of the face. Do not make his features harsher or more chiseled than in image 1.
- Image 2, the same man doing a dumbbell lateral raise: his body and the illustration STYLE of the series: smooth light-grey skin with clearly defined, cleanly drawn muscles, soft studio lighting and a plain very light grey background.
Ignore the hair in both images: draw his hair only from the hair description below.

The result: square 1:1. Head and shoulders of this man, front three-quarter view, the head large in the frame, the camera at the height of his head. His face and body are exactly as in images 1 and 2: the same man in the same clean 3D anatomical illustration style. Only his hair is rendered photorealistically. No text, no labels.

HAIR RENDERING — CRITICAL REQUIREMENT

The character has short, naturally styled dark hair with a neat taper haircut.

The sides and back are closely cropped, gradually blending into approximately 3 cm of hair on top, naturally brushed backward.

Unlike the stylized 3D anatomical body, the hair must be rendered with photorealistic hair grooming.

The hair consists of tens of thousands of extremely fine, individual human hair strands, densely overlapping to form a natural, continuous hairstyle.

Individual hairs should be extremely thin and barely distinguishable at normal viewing distance.

The hair must have:
- Realistic human hair density and fine texture.
- Soft, natural, slightly matte highlights.
- Subtle variations in individual hair direction.
- Natural transitions between the top, sides, and back.
- Realistic short hair growth patterns.

STRICTLY FORBIDDEN:
- Thick sculpted hair clumps.
- Deep grooves between strands.
- Rope-like or twisted hair.
- Braids or cornrows.
- Repetitive parallel ridges.
- Plastic or clay-like hair surfaces.
- Exaggerated separation between strands.
- Artificially uniform hair patterns.

The hair should look like real human hair photographed under soft studio lighting, while the face and body retain the original clean 3D anatomical illustration style.

The hairstyle must not be constructed from visible hair clumps. Its shape should emerge naturally from the collective flow of thousands of fine, overlapping individual hairs.
```

### 人物の見本 B4 を添付して作る文（v8・2026-10-18 08:3x）

本人回答（08:36・選択肢）「顔も髪も良い」で B4（`portraits/B4-no-hair-ref.png`）を人物の見本に決めた。これからは新しい会話で B4 だけを添付する（101・208・209・302・306 などの種目の絵は添付しない。髪が写るため）。直したこと:
- 1 通目: 添付を「人物の見本 1 枚」に。描き方は文で書く（決まりの 1 に、見本の胸・肩のような筋肉の線を足した）。顔は見本と同じ、とした
- 決まりの 11: 「整髪料でなでつけた滑らかな面・3D の型のように」（v5〜v7）は、本人の髪の指示文（「Plastic or clay-like hair surfaces」を禁じる）と食い違うので外し、本人の指示文を短くまとめたものに替えた。頭頂を見下ろさない（v6）は残した
- 後ろからの視点で足す文・毎回の末尾に足す文も、見本の髪（細い毛の集まり）を指すように替えた。v7 までの文は tools/prompts.json の first_v7・tail_v7・rear_v7 に残した
- まず 4 枚で確かめる: 302（前寄り）・209（斜め後ろ・本人不合格）・252（後ろやや上から）・1014（横・本人不合格）
- 確かめた結果（08:3x〜08:43・`~/Downloads/exercise-images/test-v8/`）: 本人回答（13:0x・選択肢）「4枚とも良い」。髪以外の崩れ: 209 は座面が本体とつながらない別の台、1014 は首に赤（赤は腹筋だけのはず）→ この 2 枚は作り直しのときに作り直す。252 の View は「from slightly above」のままで後ろからの文（頭の高さ）と食い違うが、ChatGPT は頭の高さで描いた
- 13:02 本人決定（原文）「1で良いが、まだ作業には入らないで」→ 159 枚すべてをこの文で作り直す。着手は本人の合図のあと

1 通目:

```
I have attached one reference image: a character reference portrait of the man who appears in every image. From now on I will ask you for a series of exercise illustrations, one per message. Every image must show exactly this man, with the same face and the same hair as in the reference portrait, his whole body drawn in the same clean 3D anatomical illustration style.

Rules for every image:
1. Square 1:1, clean 3D anatomical fitness illustration: smooth light-grey skin with clearly defined, cleanly drawn muscles and fine muscle lines, like the chest and shoulders in the reference portrait.
2. One athletic man, the same person as in the reference portrait in every image: an adult man of about 30 with exactly the face of the reference portrait and no beard; short dark hair exactly as in rule 11; a heavily muscular build with broad shoulders; smooth light-grey skin with clearly defined muscles, no shirt, black shorts, grey sneakers. No other people.
3. Only the muscles I list after "Red muscles:" are bright red. Every other muscle stays light grey.
4. All equipment is black.
5. Draw the equipment exactly as I describe it. Seats, pads, rollers and handles are parts of the machine and touch his body exactly where I say.
6. His whole body and the whole piece of equipment are visible, nothing is cut off, and the scene is centered.
7. Plain very light grey background with soft studio lighting. No scenery and no floor clutter, even for outdoor activities.
8. No text, no labels, no numbers, no logos, no watermark (also nothing on machine screens).
9. Exactly one image per message.
10. Anatomically correct body: exactly two arms and two legs, each attached at the correct shoulder or hip and bending only in natural directions. A hand that holds something is clearly connected to its own arm.
11. Hair, the same in every image and from every angle, exactly as in the reference portrait: short, naturally styled dark hair with a neat taper haircut. The sides and back are closely cropped, gradually blending into about 3 cm of hair on top, naturally brushed backward. Unlike the stylized 3D anatomical body, the hair is rendered with photorealistic hair grooming: tens of thousands of extremely fine, individual hair strands, densely overlapping to form a natural, continuous hairstyle, with soft, natural, slightly matte highlights, subtle variations in hair direction and natural transitions between the top, sides and back. Its shape emerges from the collective flow of thousands of fine hairs, never from visible clumps. Strictly forbidden: thick sculpted hair clumps, deep grooves between strands, rope-like or twisted hair, braids or cornrows, repetitive parallel ridges, plastic or clay-like hair surfaces, exaggerated separation between strands, artificially uniform hair patterns, curls, a bun, a ponytail, or a swirl at the crown. Seen from the side or from behind, the cropped back and nape blend smoothly into the short top, with no ridge or row of tufts. The camera never looks down onto the top of his head: it stays at or below the height of his head. When his head is low or tilted forward (push-ups, planks, bent-over exercises), the camera goes down to the height of his head, and the hair on top still looks exactly like the reference portrait: short, fine, natural hair, never layered clumps or scale-like rows.

Each of my messages will start with "Next image:" and the exercise name, then describe the equipment, his position, the moment of the movement, the red muscles and the camera view. Please reply to this message with a short "OK" only, and do not make an image yet.
```

後ろからの視点で足す文（v8）:

```
The back of his head is visible in this view: draw the same hair as in the reference portrait, now seen from behind: the back and the nape closely cropped, blending gradually into the short top. Seen from behind, the short hair on top lies down neatly, combed backward and downward in one soft, even direction, like a fresh barbershop cut, with only a very subtle, natural crown. The fine hairs run side by side and never cross each other: no net-like or lattice pattern, no big swirl or spiral at the crown, no clumps, no ridges, no braid, no bun and no rope-like texture. The camera is at the height of his head, not above it, so we do not look down onto the top of his head.
```

毎回の末尾に足す文（v8）:

```
Same man as the reference portrait: the same face and the same hair (rule 11: a short taper haircut in photorealistic, fine, natural hair; no clumps, braids, ridges or rope-like texture; the fine hairs on top lie side by side, brushed back in one even direction, and never cross each other, so there is no net-like, lattice or woven pattern; the hair is straight, never curly, wavy or looped, in every pose and at every angle; when he bends his head forward or down, the hair keeps the same short, backward-brushed shape: no centre parting, no hair falling forward or to the sides). Anatomically correct arms and legs. When both arms do the same movement, they are symmetrical: both hands at the same stage of the movement, never one arm bent and the other straight. If he uses a cable tower, it stands exactly where I say (when he faces it, it is directly in front of him, never beside him), and the cable runs in a straight line from the pulley to his hands. Same clean 3D anatomical illustration style, light-grey skin, black equipment and plain light-grey background as in rules 1, 4 and 7.
```

- 10/18 14:4x 末尾の文に「両腕が同じ動きをするときは左右対称（片方だけ曲がらない）」を足した（v8.1）。事実: 斜め前からのマシン 110（2 回）と 112 で、手前の腕だけ胸の横で曲がり反対の腕は伸びる同じ崩れが出た（他の絵にも出うるので規則どおり文を直した）。110 は横寄り、112 は正面寄りの View に変えた送り直しでそろった。直す前の文は tools/prompts.json の tail_v8

- 10/18 15:0x 1 通目の決まり 11 に「頭が低い・前に倒れる姿勢（腕立て・プランク・前かがみ）では、カメラを頭の高さまで下げ、上の髪も見本どおり細い毛（束の重なり・鱗の列にしない）」を足した（v8.2）。事実: 117 の 1 回目（斜め前・低い）と 119（横から・頭が床の近く）で、上の髪が太い束の鱗のような重なりになった（同じ崩れが 2 枚）。117 は横・頭の高さの View に変えた送り直しで直った。119 の View もカメラを床の近く・頭の高さにした。直す前の 1 通目は tools/prompts.json の first_v8

- 10/18 15:3x 後ろからの視点で足す文を直した（v8.3）: 上の髪は後ろ下へ一方向にそろってなでつけ、つむじはごく控えめ、細い毛は並んで交差しない（網目・格子の模様なし、大きな渦なし）。事実: 208・209 の後ろ斜めの絵で、つむじが大きな渦になり上の毛が網目のように交差した（同じ崩れが 2 枚。試しの 209 より強い）。直す前の文は tools/prompts.json の rear_v8

- 10/18 16:4x 末尾の文にケーブルの塔の位置の 1 文を足した（v8.4）: 塔は言ったところに立つ（向かい合うときは真正面・横に置かない）、ケーブルは滑車から手までまっすぐ。事実: 254・313・410 で、向かい合うはずの塔が体の横に描かれた（同じ崩れが 3 枚）。254・313 は横寄りの View の送り直しで直った。直す前の末尾は tools/prompts.json の tail_v81

- 10/18 16:4x 末尾の文の髪の括弧に「上の細い毛は一方向に並び交差しない（網目・格子・編んだ模様なし）」を足した（v8.5）。事実: 前・横からの 704 の 1 回目と 708 で、上の髪に毛が交差する網目（編み込みのような模様）が出た（同じ崩れが 2 枚。702・703・705 にも弱く出ていた）。後ろからの文（v8.3）にだけあった言い方を末尾にも入れた。704 はこの言い方を足した送り直しで網目が消えた。直す前の末尾は tools/prompts.json の tail_v84

- 10/18 17:1x 末尾の文の髪の括弧に「髪はまっすぐ・巻き毛・波打ち・輪っかにしない（どの姿勢・角度でも）」を足した（v8.6）。事実: 805（2 回とも・頭が前に出る前かがみ）と 851（あお向けで頭を後ろに倒す）で、上の髪が巻き毛・輪っかの束になった（同じ崩れが 2 種目・3 枚。v8 になってから初めて。同じ会話の後半）。直す前の末尾は tools/prompts.json の tail_v85

- 10/19 11:0x 末尾の文の髪の括弧に「頭を前・下に曲げても、短く後ろへなでた形のまま（真ん中の分け目なし・前や横に垂れない）」を足した（v8.7）。事実: 頭を深く下げる 1016（ケーブルクランチ）と 1017（アブクランチマシン）で、頭の上に真ん中の分け目ができ、長めの毛が左右に垂れた（同じ崩れが 2 枚）。直す前の末尾は tools/prompts.json の tail_v86

- 10/19 12:5x 臀筋の描き方（本人回答（原文）「短パンの上から赤くする方針で良い。852、856は短パンを切り取ってしまっているから不採用。1111は隠れてしまっているから不採用。」）: 臀筋が赤い種目（852・855・856・1105・1108・1111・1201・1205・1208）の Red muscles の行に「短パンは履いたまま尻を覆う（切り取り・まくり上げ・短くしない）、臀筋の形を黒い短パンの上から明るい赤で塗る」を足した（tools/prompts.json の glute_over_shorts）。1111 は赤に臀筋を足した。12:5x 852 で赤がぼんやりした光になったので「はっきりした筋肉の形と細い線・光や点にしない」を足した

### 毎回の末尾に足す文

2026-10-16 追記。種目の英文（"Next image:" から "View:" まで）の後ろに 1 行空けて足す。1 通目で伝えた人物を、毎回思い出させるため。

2026-10-17 追記: 10/16 の絵で、髪の上が編み込み・お団子・つむじの渦になったものが 14 枚（すべて後ろ・斜め後ろからの視点）、縄を編んだような束になったものが 16 枚（10 枚は後ろ寄り、6 枚は前・横から）あった。本人（原文）「編み込み気持ち悪いね」「ややの16枚も含めて全て作り直し。やり直し分も含めてこのようなことが起きないようプロンプトの修正をして」。直したこと:
- 髪型を決まりの 11 として独り立ちさせ、形を具体的に書いた（横と後ろは短く刈る・上は約 3 cm で後ろへなでつけ、平らで滑らか・細い毛筋だけ）。前の書き方「上は少し長め・後ろへ流す」は量のある髪を、00:3x に足した「softly textured」は質感を誘いかねないので外した（推測）
- してはいけない形を名指しした（編み込み・コーンロウ・縄のようにねじった束・ドレッド・巻き毛・お団子・ポニーテール・つむじの渦）
- 後ろからの視点（View に rear か behind がある種目）には、下の「後ろからの視点で足す文」を種目の英文のすぐ後ろに足す（mkcall.py が自動で足す）
- 推測: 試作 208（ラットプルダウン、後ろから）の後頭部に柔らかいつむじの渦があり、後ろからの絵でそれが強まった形が出たのかもしれない（確かめていない）
- 効いたかは未検証。再開したら、まず 209・213（後ろ・お団子だった）、803（横やや後ろ）、1011（前・縄のような束）で確かめ、出たら止めて報告する

髪の直し（2026-10-17 22:4x）。事実: 直した文で新しい会話を始め、試作 3 枚（101・208・704）を添付して作ったところ、209（斜め後ろ）は短く刈り上げた後頭部で良かったが、213（斜め後ろ・懸垂）は頭頂部にくっきりした渦が出た。拡大して比べると、試作 208 の後頭部にも同じ形の渦と巻き毛の束があり、試作 704（横から）も後頭部に渦と縄のような束があった（101 は前からで、後ろへなでつけた平らな髪）。10/16 夜に採用して作り直しの 30 枚に入っていない 206・211 にも巻き毛と渦があった。本人の規則「他の画像にも及ぶ崩れは一旦止まってプロンプトを直す」（10/17 22:2x）に従って止め、次のように直した:
- 添付を、髪が決まりの 11 どおりの 2 枚（101 と作り直した 209）に替えた。文の「三枚」を「二枚」に、「同じ髪」を足した
- 決まりの 11 に、横・後ろから見たときの形を足した（上は額から後頭部へまっすぐ平行な線で平ら、後ろとえり足は短く滑らか、ラットプルダウンの添付のとおり）。後ろからの念押しと末尾の文も、添付の後頭部を指すようにした
- 推測: 文で渦を禁じても、添付の絵の髪が写った（213 の渦が 208 の渦と同じ形のため）。確かめていない
- 「試作の会話で続けるとき」の文は、その会話に 208・704 があるので使わない
- 効いたかは未検証。新しい会話で 213（渦が出た）、803、1011 で確かめる

髪の直し（2026-10-17 23:2x）。事実: 22:4x の直しのあと、後ろ寄りの絵 12 枚のうち、真後ろ・やや上からの 252 は 2 回とも上の髪が太い束の鱗のような重なり（2 回目を境界として採用）、254 は 4 回目で上に縄をよったような太い束の列が出た（ほかの 10 枚は良い）。同じ崩れが 2 枚に出たので、本人の規則で止めて直した:
- 決まりの 11 に、上の髪は少し整髪料でなでつけ、表面が滑らかで少しつやがあり、太い束・鱗のような層・ねじった束に分かれない、を足した。末尾の文と後ろからの念押しにも同じことを短く足した。試作 101 の髪はなでつけて少しつやがある
- 推測: 真後ろから頭頂を見下ろす構図で、短い髪の質感が束として強く描かれる。確かめていない
- 効いたかは未検証。新しい会話で 252・254 を作り直して確かめる

髪の直し（2026-10-17 23:3x）。事実: 23:2x の直しのあと、後ろ・やや上からの 204 で、上の髪と刈り上げた後ろの境目に、束が重なって並ぶ編み込みのような筋が横に出た。直す前の 254（4 回目）にも同じ筋があり、203・1201 にも弱く出ていた。本人の規則で止め、決まりの 11 と後ろからの念押しに「上と刈り上げの境目は滑らかにつながり、筋・重なった束の列・編み込みのような線を作らない」を足した。推測: 後ろやや上から見ると、上の長い毛先が後ろの短い毛に重なる所が束の列として描かれる。確かめていない。効いたかは未検証。新しい会話で 204・205 で確かめる

髪の直し（2026-10-17 23:4x）。事実: 23:3x の直しのあと、新しい会話の 204 は境目が滑らかで良かったが、205（後ろ・やや上）で上の髪が鱗のように重なり、境目に束の列が出た。23:3x の直しは半分しか効かなかった。決まりの 11・後ろからの念押し・末尾の文に「髪は細かな線だけの滑らかな面として描き、ばらばらの束として描かない（きれいな 3D モデルのように）」を足した。205 は上体が水平にならず 2 回失敗したので、視点を「横・やや後ろ」に変えた（803 は横・やや後ろで水平に近く描けた）。推測: ChatGPT は毛束を細かく描くほど束の重なりが編み込みのように見える。確かめていない。新しい会話で 205・210 で確かめ、まだ出たら止めて本人に報告する

髪の直し（2026-10-18 00:2x）。事実: 23:4x の直し（v5）のあと、24 枚中 21 枚は髪が良かったが、後ろ・上からの 311（1 回目）・313 で上の髪が鱗のように重なる束、頭を下げて頭頂がこちらを向く 314 で縄・コーンロウのような列が出た。3 枚とも、カメラが頭の上の面を見下ろす構図だった（前・横・目の高さの後ろからは出ていない）。髪の書き方を 5 回直しても、この構図では出る。v6 として、書き方でなく構図を変えた: 決まりの 11 と後ろからの念押しに「カメラは頭の高さかそれより下で、頭の上の面を見下ろさない」を足し、残りのうち上から・頭を下げる種目（313・314・408・601・602）の View を目の高さ・顔が見える向きに変えた。推測: ChatGPT は頭頂を正面から見ると短い髪を束の模様として描く。確かめていない。313・314 で確かめ、まだ出たら止めて本人に報告する

髪の直し（2026-10-18 03:1x）。本人決定（原文）「Bは不採用。1014も不採用。」で、見本にしていた 209 も髪が悪（上の髪が短い束の重なり）と決まった。見本を、髪が良い 3 枚に替えた: 101（ベンチプレス・試作）・302（ミリタリープレス）・306（サイドレイズ）。どれも前・横からの絵で、なでつけて滑らかな髪。文の「ラットプルダウンの見本どおり」をすべて「見本と同じ滑らかでつやのある髪」に替えた。後ろからの見本は無くなるので、後ろからの絵の効き目は未検証。新しい会話で 209・312（後ろ）・1014（前・横）を作り直して確かめる

```
Same man as the references: about 30, a mature face with a strong square jaw, heavily muscular. Hair exactly as in the references and rule 11: a short neat taper haircut, the sides and back clipped very short, the short top combed straight back with a little product, smooth, flat and slightly shiny, drawn as a smooth sculpted surface with only subtle fine lines, never split into thick clumps; no braids, no rope-like twists, no curls, no bun, no crown swirl. Anatomically correct arms and legs. Same style, light-grey skin and plain light-grey background as the references.
```

### 後ろからの視点で足す文

2026-10-17 追記。View の行に rear か behind がある種目だけ、種目の英文（View の行）のすぐ後ろに改行して足し、そのあと 1 行空けて「毎回の末尾に足す文」を足す。後頭部が見える絵で、編み込み・お団子・渦が出やすかったため。

```
The back of his head is visible in this view: draw it with the same smooth, sleek, slightly glossy hair as in the references, now seen from behind: the back and the nape clipped very short and smooth, and the short top lying flat in straight, parallel lines from front to back as one smooth, slightly shiny mass without thick clumps; where the top meets the clipped back, the hair fades smoothly with no ridge or row of overlapping tufts. Draw the hair as a smooth, sculpted surface with only subtle, fine lines, not as separate locks. The back of the head shows no swirl, no braid, no bun and no rope-like texture. The camera is at the height of his head, not above it, so we do not look down onto the top of his head.
```

## 胸

### 101 ベンチプレス
試作済み: `workout_image1.png` を `101.png` としてそのまま使う。作り直すときだけ、このプロンプトを送る。
```
Next image: Barbell bench press.
Equipment: a flat bench (completely horizontal, no incline, no rack) and a straight barbell loaded with black plates.
Position: lying face up on the bench, feet flat on the floor, overhand grip slightly wider than shoulder width.
Moment: the bar is pressed straight up above the chest, arms almost fully extended.
Red muscles: chest (pectoralis major).
View: three-quarter side view from slightly above, so the chest, the whole bench and the whole barbell are visible.
```

### 102 インクラインベンチプレス
```
Next image: Incline barbell bench press.
Equipment: an incline bench whose backrest is raised 30-45 degrees (the head end clearly higher than the seat), and a straight barbell loaded with black plates.
Position: lying back on the inclined backrest, head higher than the hips, feet flat on the floor, overhand grip slightly wider than shoulder width.
Moment: halfway up, pressing the bar from the upper chest (just below the collarbones) toward a point above his shoulders.
Red muscles: chest (pectoralis major), especially the upper chest near the collarbones (clavicular head).
View: side view, slightly from the front, so the 30-45 degree angle of the bench is easy to see.
```

### 103 デクラインベンチプレス
```
Next image: Decline barbell bench press.
Equipment: a decline bench tilted head-down by 15-30 degrees (the head end is lower than the hip end), with padded leg rollers at the high end, and a straight barbell loaded with black plates.
Position: lying face up with the head lower than the hips, knees bent over the high end of the bench, lower legs hooked under the padded rollers, overhand grip slightly wider than shoulder width.
Moment: pressing the bar up from the lower chest, arms almost fully extended.
Red muscles: chest (pectoralis major), especially the lower part.
View: side view so the head-down tilt of the bench is easy to see.
```

### 104 スミスマシンベンチプレス
```
Next image: Smith machine bench press.
Equipment: a Smith machine: a tall rectangular black frame with two vertical steel guide rails; the barbell is fixed to the rails, so it can only slide straight up and down; black plates on the bar ends. A flat horizontal bench stands inside the frame, under the bar.
Position: lying face up on the flat bench, feet flat on the floor, overhand grip slightly wider than shoulder width.
Moment: pressing the bar up along the rails, arms almost straight.
Red muscles: chest (pectoralis major).
View: three-quarter side view so the vertical guide rails, the bar fixed to them and the bench are all clearly visible.
```

### 105 ダンベルプレス
```
Next image: Flat dumbbell bench press.
Equipment: a flat horizontal bench and one dumbbell in each hand (no barbell).
Position: lying face up on the bench, feet flat on the floor.
Moment: pressing both dumbbells up above the chest, palms facing toward his feet, arms almost straight, the dumbbells close to each other at the top.
Red muscles: chest (pectoralis major).
View: three-quarter side view from slightly above.
```

### 106 インクラインダンベルプレス
```
Next image: Incline dumbbell press.
Equipment: an adjustable bench with the backrest raised 30-45 degrees (the head end clearly higher than the seat), and one dumbbell in each hand.
Position: lying back on the inclined backrest, head higher than the hips, feet flat on the floor.
Moment: halfway up, pressing the dumbbells from the sides of the upper chest toward a point above his shoulders, palms facing toward his feet.
Red muscles: chest (pectoralis major), especially the upper chest near the collarbones (clavicular head).
View: side view, slightly from the front, so the bench angle is easy to see.
```

### 107 デクラインダンベルプレス
```
Next image: Decline dumbbell press.
Equipment: a decline bench tilted head-down by 15-30 degrees (the head end is lower than the hip end), with padded leg rollers at the high end, and one dumbbell in each hand.
Position: lying face up with the head lower than the hips, lower legs hooked under the padded rollers.
Moment: pressing the dumbbells up from the lower chest, arms almost straight, palms facing toward his feet.
Red muscles: chest (pectoralis major), especially the lower part.
View: side view so the head-down tilt of the bench is easy to see.
```

### 108 ダンベルフライ
```
Next image: Flat dumbbell fly.
Equipment: a flat horizontal bench and one dumbbell in each hand.
Position: lying face up on the bench, feet flat on the floor.
Moment: the stretched bottom of a fly: both arms opened wide out to the sides in a big arc, elbows only slightly bent, dumbbells at about chest height, palms facing up. This is not a press: the arms stay almost straight, as if hugging a big tree.
Red muscles: chest (pectoralis major).
View: three-quarter view from above, from the foot end, so both open arms and the chest are visible.
```

### 109 インクラインダンベルフライ
```
Next image: Incline dumbbell fly.
Equipment: an adjustable bench with the backrest raised 30-45 degrees (the head end clearly higher than the seat), and one dumbbell in each hand.
Position: lying back on the inclined backrest, feet flat on the floor.
Moment: the stretched bottom of a fly: both arms opened wide to the sides in an arc, elbows only slightly bent, dumbbells at upper-chest height, palms facing up. Not a press.
Red muscles: chest (pectoralis major), especially the upper chest near the collarbones (clavicular head).
View: three-quarter front-side view so both open arms and the bench angle are visible.
```

### 110 チェストプレス（マシン）
```
Next image: Seated chest press machine.
Equipment: a seated chest press machine: a padded seat and an upright backrest built into the machine frame, two handles at chest height on lever arms in front of him, and a weight stack at the back of the machine.
Position: sitting upright with his back against the backrest, feet flat on the floor, gripping the handles beside his chest.
Moment: pushing the handles straight forward at chest height, arms almost straight.
Red muscles: chest (pectoralis major).
View: side view, slightly from the front, so both straight arms pushing forward, the chest and the whole machine are visible.
```

### 111 インクラインチェストプレス（マシン）
```
Next image: Seated incline chest press machine.
Equipment: an incline chest press machine: a seat with the backrest reclined slightly back, and two handles on lever arms that start at shoulder height and travel upward and forward at about 30-45 degrees (not horizontally); a weight stack on the machine.
Position: sitting with his back against the reclined backrest, feet flat on the floor, hands on the handles beside his shoulders.
Moment: pressing the handles upward and forward, arms halfway extended, the hands rising above shoulder height.
Red muscles: chest (pectoralis major), especially the upper chest near the collarbones (clavicular head).
View: side view, slightly from the front, so the upward pressing angle is easy to see.
```

### 112 ペックフライ（マシン）
```
Next image: Seated chest fly machine.
Equipment: a chest fly machine: a seat with a tall upright backrest, two long swinging arms on his left and right at shoulder height with vertical handles at their ends, and a weight stack behind the backrest.
Position: sitting upright with his back against the backrest, feet flat on the floor, arms out to the sides holding the handles, elbows only slightly bent.
Moment: swinging both arms forward in an arc until the handles nearly meet in front of his chest.
Red muscles: chest (pectoralis major).
View: front view, slightly from one side, so both arms meeting in front of the chest and both machine arms are visible.
```

### 113 ケーブルクロスオーバー
```
Next image: Cable crossover (high to low).
Equipment: a cable crossover station: two tall cable towers, one on his left and one on his right, joined by a top frame; each tower has its pulley set high above head height, with a cable to a single D-handle.
Position: standing in the middle between the towers, one foot slightly in front of the other, torso leaning slightly forward, one handle in each hand.
Moment: pulling both handles down and inward in an arc, elbows slightly bent, the hands meeting in front of the lower chest.
Red muscles: chest (pectoralis major).
View: three-quarter front view, with both towers and both cables visible.
```

### 114 ローケーブルフライ
```
Next image: Low cable fly (low to high).
Equipment: a cable crossover station with two towers, one on his left and one on his right, but both pulleys are set LOW, near the floor at ankle height; each cable ends in a D-handle.
Position: standing upright in the middle between the towers, feet shoulder-width apart, one handle in each hand.
Moment: lifting both handles from low at his sides upward and inward in an arc, elbows slightly bent, palms facing up, the hands meeting in front of the upper chest at shoulder height. The cables run up diagonally from the floor-level pulleys.
Red muscles: chest (pectoralis major), especially the upper chest near the collarbones (clavicular head).
View: three-quarter front view, with both towers and both low cables visible.
```

### 115 ディップス（胸）
注記: 胸と三頭の両方に効く種目。この項は体を前に倒した姿勢にして胸を赤くする（509 ディップス（三頭）は体を立てて三頭を赤くする）。
```
Next image: Chest dips.
Equipment: a dip station: two parallel horizontal bars about shoulder width apart at waist height, on a black stand.
Position: supporting his body on the bars with his hands, knees bent and ankles crossed behind him, feet off the floor.
Moment: halfway down, elbows bent about 90 degrees and flaring slightly outward, torso leaning clearly forward by about 30 degrees (chest over the hands).
Red muscles: chest (pectoralis major), especially the lower part.
View: three-quarter front-side view so the forward lean and the chest are visible.
```

### 116 ダンベルプルオーバー
注記: 胸と背中（広背筋）の両方に効く種目。muscle_group（胸）に合わせて胸を赤くする（217 ケーブルプルオーバーは背中）。
```
Next image: Dumbbell pullover.
Equipment: a flat horizontal bench and one dumbbell held with both hands: palms pressed against the underside of the top plate, thumbs around the handle.
Position: lying face up along the bench with his head at one end, feet flat on the floor.
Moment: the dumbbell has been lowered in an arc behind his head, arms almost straight with the elbows slightly bent, upper arms beside his ears, ribcage stretched.
Red muscles: chest (pectoralis major).
View: side view so the long arc of the arms behind the head and the chest are visible.
```

### 117 プッシュアップ
```
Next image: Push-up.
Equipment: none, on the floor.
Position: hands on the floor slightly wider than his shoulders, under the chest, body in a straight line from head to heels, on his toes.
Moment: halfway down, elbows bent about 90 degrees and angled about 45 degrees away from the body.
Red muscles: chest (pectoralis major).
View: low side view, slightly from the front, the camera at the height of his head, so the bent arms, the straight body and the chest are visible.
```

### 118 ワイドプッシュアップ
```
Next image: Wide push-up.
Equipment: none, on the floor.
Position: hands on the floor much wider than his shoulders (about one and a half times shoulder width), fingers pointing forward and slightly outward, body straight from head to heels, on his toes.
Moment: halfway down, elbows bent and pointing out to the sides.
Red muscles: chest (pectoralis major).
View: low three-quarter side view, the camera at the height of his head, so the wide hand position, the elbows pointing out and the chest are visible.
```

### 119 デクラインプッシュアップ
```
Next image: Decline push-up.
Equipment: a black flat bench about knee height.
Position: feet raised on the bench behind him, hands on the floor slightly wider than his shoulders, body in a straight line sloping down from the feet to the head.
Moment: halfway down, elbows bent about 90 degrees, head lower than the feet.
Red muscles: chest (pectoralis major), especially the upper chest near the collarbones (clavicular head).
View: low side view, the camera close to the floor at the height of his head, so the raised feet, the downward slope of the body and his face in profile are visible.
```

## 背中

### 201 デッドリフト
注記: 臀部とハムストリングも大きく働くが、muscle_group（背中）に合わせて脊柱起立筋だけを赤くする。3 つとも赤くするなら Red muscles の行を `lower back (erector spinae), glutes (gluteus maximus) and hamstrings (biceps femoris, semitendinosus and semimembranosus).` に替える。
```
Next image: Conventional barbell deadlift.
Equipment: a straight barbell loaded with large black plates, lifted from the floor.
Position: feet about hip-width apart, hands just outside the knees with an overhand grip, arms straight, back flat.
Moment: mid-lift: the bar has just passed the knees, the hips and shoulders rising together, torso leaning forward about 45 degrees.
Red muscles: lower back (erector spinae, the long muscles along both sides of the spine).
View: three-quarter rear-side view so the back and the whole barbell are visible.
```

### 202 ラックプル
注記: 床から引くデッドリフトより上の範囲だけを引くため、背中のうち脊柱起立筋と僧帽筋を赤くする（臀部も働く）。
```
Next image: Rack pull.
Equipment: a power rack (four black upright posts) with its safety bars set at knee height; a straight barbell loaded with black plates rests on the safety bars, not on the floor.
Position: standing close to the bar, feet hip-width apart, overhand grip just outside the thighs, arms straight, back flat.
Moment: he has just lifted the bar off the safety bars; the bar is just above the knees and the hips are moving forward toward lockout.
Red muscles: lower back (erector spinae) and upper back (trapezius).
View: three-quarter rear-side view so the back, the rack posts and the safety bars are visible.
```

### 203 ベントオーバーロー
```
Next image: Barbell bent-over row.
Equipment: a straight barbell loaded with black plates.
Position: standing with the knees slightly bent, hinged forward at the hips so the torso leans about 45 degrees, back flat, overhand grip slightly wider than shoulder width.
Moment: pulling the bar up to the belly button, elbows driven back past the torso.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids and middle trapezius).
View: three-quarter rear-side view, the camera at the height of his head (not above him), so the back is visible.
```

### 204 Tバーロー
```
Next image: T-bar row (landmine style).
Equipment: a straight barbell with one end fixed in a small black pivot on the floor; black plates are loaded only on the free end; a close-grip V-shaped handle is hooked under the bar just behind the plates.
Position: standing over the bar with one foot on each side of it, knees bent, hinged forward about 45 degrees, back flat, both hands on the V-handle with palms facing each other.
Moment: pulling the plate end of the bar up toward his chest, elbows driven back close to the body.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids and middle trapezius).
View: three-quarter rear-side view so the back and the whole bar, from the floor pivot to the plates, are visible.
```

### 205 ペンドレイロー
```
Next image: Pendlay row.
Equipment: a straight barbell loaded with large black plates.
Position: torso bent forward until it is parallel to the floor (horizontal), back flat, knees bent, overhand grip slightly wider than shoulder width. Every rep starts with the bar resting on the floor.
Moment: the bar has just been pulled explosively from the floor and touches his lower chest, while the torso stays horizontal, as flat as a table top. His upper arms are pulled up past his back with the elbows bent about 90 degrees and pointing up toward the ceiling. The arms are not straight and the bar is not near his thighs.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids and middle trapezius).
View: exact side view, the camera at the height of his back, so the horizontal back, the bent arms and the bar under the chest are visible. His head and his hips are at the same height, like a table top; this must look different from a normal bent-over row.
```

### 206 ワンハンドダンベルロー
注記（2026-10-16）: 元の文では、3 回とも左右の手の役割が指示と逆になった。2・3 回目はダンベルを持つ腕が背中の途中から出た（1 回目はダンベルをベンチに置いたまま）。カメラに近い側・遠い側と、腕が右肩から出ることを書き足した。
```
Next image: One-arm dumbbell row.
Equipment: a flat horizontal bench and one dumbbell.
Position: his left knee and left hand rest on the bench; his right foot is on the floor beside the bench; torso nearly parallel to the floor, back flat. The dumbbell is in his right hand, and his left hand holds nothing.
Moment: rowing the dumbbell up to beside his right lower ribs; his right arm comes from his right shoulder, and the right elbow is pulled up and back close to his side.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids) on the right, working side.
View: three-quarter rear view from his right side, so his right side (the rowing arm and the working side of the back) is nearest the camera, and his left knee and left hand on the bench are farther away.
```

### 207 ダンベルベントオーバーロー
```
Next image: Dumbbell bent-over row (both arms).
Equipment: two dumbbells, one in each hand. No bench.
Position: standing, knees slightly bent, hinged forward at the hips about 45 degrees, back flat, palms facing each other.
Moment: rowing both dumbbells up to the sides of the waist at the same time, elbows driven back.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids and middle trapezius).
View: three-quarter rear-side view, the camera at the height of his head (not above him), so the back is visible.
```

### 208 ラットプルダウン
注記: 試作（`workout_image2.png`）は膝を押さえるパッドが太ももの上でなく腰の横に描かれた。作り直すときはこのプロンプトを送る（作り直すかは本人が決める）。
```
Next image: Lat pulldown (wide overhand grip).
Equipment: a lat pulldown machine built as one unit: a padded seat attached to the machine frame, and directly above the seat two padded thigh rollers attached to the same frame; a high pulley above him with a cable to a long straight bar with slightly bent ends; a weight stack in the frame. Do not draw a separate bench: the seat and the thigh rollers are parts of the machine.
Position: sitting on the machine's seat facing the weight stack, feet flat on the floor, knees bent 90 degrees, the thigh rollers pressing down on the tops of his thighs just above the knees (not beside his hips). Wide overhand grip, hands much wider than the shoulders.
Moment: the bar has been pulled down in front of his face to the upper chest, elbows pointing down and slightly back, chest up, torso leaning back slightly.
Red muscles: lats (latissimus dorsi, the wide back muscles).
View: three-quarter rear view so the back is visible, with the whole machine, the seat and the thigh rollers visible and centered.
```

### 209 ラットプルダウン（パラレルグリップ）
注記: アタッチメントの幅はジムで違う。肩幅のパラレルグリップで描く（狭い V 字のハンドルを使うなら Equipment の行を直す）。
```
Next image: Lat pulldown with a parallel (neutral) grip.
Equipment: a lat pulldown machine built as one unit (a padded seat and two padded thigh rollers attached to the frame, a high pulley, a weight stack). Instead of a long straight bar, the cable holds a parallel-grip handle: a bar with two parallel handles about shoulder width apart, so the palms face each other. Do not draw a separate bench or stool: the seat and the thigh rollers are parts of the machine frame.
Position: sitting on the machine's seat, the thigh rollers pressing down on the tops of his thighs just above the knees, palms facing each other on the handles.
Moment: pulling the handle down to the upper chest, elbows close to the body and pointing down in front of the torso, chest up.
Red muscles: lats (latissimus dorsi).
View: three-quarter rear-side view so the back and the palms-facing grip are both visible.
```

### 210 ビハインドネックプルダウン
```
Next image: Behind-the-neck lat pulldown.
Equipment: a lat pulldown machine built as one unit (a padded seat and two padded thigh rollers attached to the frame, a high pulley, a long straight bar, a weight stack).
Position: sitting on the machine's seat, the thigh rollers on the tops of his thighs just above the knees, torso upright (not leaning back), head tilted slightly forward, wide overhand grip.
Moment: the bar has been pulled down behind his head to the back of the neck, elbows pointing straight down.
Red muscles: lats (latissimus dorsi).
View: rear view, slightly from the side, so the bar behind the neck and the back are visible.
```

### 211 シーテッドロー（ケーブル）
```
Next image: Seated cable row.
Equipment: a low-pulley seated row station: a long low padded seat attached to the machine, two angled foot plates in front of the seat, a low pulley at foot level with a cable to a close-grip V-shaped handle, and a weight stack.
Position: sitting upright on the seat, feet on the foot plates, knees slightly bent, palms facing each other on the V-handle.
Moment: the handle has been pulled to his belly, elbows driven back past the torso, chest up, shoulder blades squeezed together.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids and middle trapezius).
View: three-quarter rear-side view so the back and the cable are visible.
```

### 212 マシンロー
注記: マシンの形はジムで違う。胸パッド付きで、レバーの先のハンドルを引く型で描く（ケーブルの 211 と見分けるため）。
```
Next image: Seated machine row (chest-supported).
Equipment: a seated row machine: a padded seat and a vertical chest pad attached to the machine in front of him, two handles on lever arms in front of the chest pad, and a weight stack. No cable.
Position: sitting upright, chest pressed against the chest pad, feet flat on the floor, arms reaching forward to the handles.
Moment: pulling both handles back toward his torso, elbows driven back past the body, shoulder blades squeezed together.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids and middle trapezius).
View: three-quarter rear view so the back, the chest pad and the lever arms are visible.
```

### 213 チンニング（順手懸垂）
```
Next image: Pull-up (overhand grip).
Equipment: a straight horizontal bar high on a black pull-up station.
Position: hanging from the bar with an overhand grip, palms facing forward (away from him), hands wider than his shoulders, knees slightly bent and ankles crossed.
Moment: pulled up, chin just above the bar, elbows pointing down and slightly back.
Red muscles: lats (latissimus dorsi).
View: three-quarter rear view so the back is visible.
```

### 214 チンアップ（逆手懸垂）
```
Next image: Chin-up (underhand grip).
Equipment: a straight horizontal bar high on a black pull-up station.
Position: hanging from the bar with an underhand grip, palms facing toward his face, hands about shoulder width apart, knees slightly bent and ankles crossed.
Moment: pulled up, chin just above the bar, elbows pointing down in front of the body.
Red muscles: lats (latissimus dorsi).
View: three-quarter rear-side view so the back and the underhand grip are both visible.
```

### 215 アシストチンニング（マシン）
```
Next image: Assisted pull-up machine.
Equipment: an assisted pull-up machine: a tall black frame with pull-up handles at the top, a padded knee platform in the middle that a weight stack pushes upward to help him, and two steps at the sides.
Position: kneeling with both knees on the padded platform, holding the top handles with a wide overhand grip.
Moment: pulled up, chin near the handles; the knee platform has risen with him.
Red muscles: lats (latissimus dorsi).
View: three-quarter rear view so the back, the knee platform and the whole machine are visible.
```

### 216 ストレートアームプルダウン
```
Next image: Straight-arm cable pulldown.
Equipment: a single cable tower with the pulley set high above his head, and a short straight bar on the cable.
Position: standing facing the tower about one step away, hinged slightly forward at the hips, overhand grip about shoulder width, arms straight with the elbows almost locked.
Moment: pushing the bar down in an arc from eye level toward the thighs while the arms stay straight; the bar is now at hip height.
Red muscles: lats (latissimus dorsi).
View: three-quarter rear-side view so the back and the straight arms are visible.
```

### 217 ケーブルプルオーバー
本人回答（10/19・選択肢）「立って高い滑車から引く版」→ 立つ版で書いた。216 と見分けるため、ロープ・前傾 45 度・手は顔の前（腕を頭の上から下ろし始めたところ）にした。
```
Next image: Standing cable pullover with a rope.
Equipment: a single cable tower with the pulley set high above his head, and a rope attachment with two ends.
Position: standing facing the tower about two steps away, hinged forward at the hips about 45 degrees, back flat, knees slightly bent, one rope end in each hand, arms straight and reaching up and forward toward the pulley.
Moment: the start of the pull: the straight arms are sweeping down in a wide arc from above his head; the hands are now in front of his face, the rope stretched up to the high pulley in front of him. The arms stay straight.
Red muscles: lats (latissimus dorsi).
View: side view so the long straight arms, the hinged torso and the cable running up to the high pulley are visible.
```

### 218 ハイパーエクステンション（マシン）
本人回答（10/19・選択肢）「45度の台（推奨）」→ このまま。（元の注記） 45° の台（足首を固定して上体を起こす）で描いた。座って背もたれを後ろへ押す、重りの付いたマシンのことなら別の絵になる。220 との違いも合わせて確かめる。
```
Next image: 45-degree hyperextension (back extension bench).
Equipment: a 45-degree hyperextension bench: a black frame slanted at 45 degrees with a padded hip support at the upper front, ankle rollers at the lower back, and a foot platform.
Position: facing down, the front of his hips on the pad, heels hooked under the ankle rollers, arms crossed over the chest.
Moment: raising the torso until his body is one straight line from head to heels, along the 45-degree angle of the bench.
Red muscles: lower back (erector spinae).
View: three-quarter rear-side view so the lower back and the angle of the bench are visible.
```

### 219 インバーテッドロー（斜め懸垂）
```
Next image: Inverted row.
Equipment: a straight barbell fixed at about waist height in a black power rack.
Position: hanging under the bar face up, overhand grip slightly wider than shoulder width, heels on the floor, body straight from head to heels like a plank.
Moment: pulling his chest up to the bar, elbows driven back and down.
Red muscles: lats (latissimus dorsi) and middle back (rhomboids and middle trapezius).
View: low side view from slightly behind and below, so the back muscles are visible.
```

### 220 バックエクステンション
要確認: 器具を使わない床の版（うつ伏せで上体を起こす）で描いた。218 と同じ 45° の台で、重りを持たずに行う種目のことなら 218 と同じ絵になる。
```
Next image: Floor back extension (lying face down).
Equipment: none, lying on the floor.
Position: lying face down on the floor, legs straight and together, fingertips lightly touching the sides of his head.
Moment: lifting the chest and upper body off the floor by arching the back; the legs stay on the floor.
Red muscles: lower back (erector spinae).
View: low three-quarter rear-side view, the camera close to the floor at the height of his head, so the lower back is visible.
```

## 僧帽筋

### 251 バーベルシュラッグ
```
Next image: Barbell shrug.
Equipment: a straight barbell loaded with black plates.
Position: standing upright, feet hip-width apart, holding the bar in front of his thighs with straight arms, overhand grip about shoulder width.
Moment: shoulders lifted straight up toward the ears as high as possible; the arms stay straight and the elbows do not bend.
Red muscles: upper traps (upper trapezius, between the neck and the shoulders).
View: three-quarter rear view, the camera at the height of his head (not above him), so the traps are visible.
```

### 252 ダンベルシュラッグ
```
Next image: Dumbbell shrug.
Equipment: one dumbbell in each hand.
Position: standing upright, arms straight down at his sides, palms facing his thighs.
Moment: shoulders lifted straight up toward the ears; the arms stay straight.
Red muscles: upper traps (upper trapezius).
View: three-quarter rear view from slightly above so the traps are visible.
```

### 253 スミスマシンシュラッグ
```
Next image: Smith machine shrug.
Equipment: a Smith machine: a tall black frame with two vertical guide rails; the barbell is fixed to the rails and slides only straight up and down; black plates on the bar ends.
Position: standing upright inside the frame, holding the bar in front of his thighs with straight arms, overhand grip about shoulder width.
Moment: shoulders lifted straight up toward the ears, the bar rising a little along the rails.
Red muscles: upper traps (upper trapezius).
View: three-quarter rear-side view so the traps and the vertical rails are visible.
```

### 254 ケーブルシュラッグ
```
Next image: Cable shrug.
Equipment: a single cable tower with the pulley at the bottom, near the floor, and a straight bar on the cable.
Position: standing upright directly in front of the tower and facing it, close to it, so the tower is in front of him and not beside him; holding the bar in front of his thighs with straight arms, overhand grip. The cable runs from the middle of the bar straight down to the low pulley right in front of his feet.
Moment: shoulders lifted straight up toward the ears; the cable runs down to the low pulley.
Red muscles: upper traps (upper trapezius).
View: side view, slightly from behind, the camera at the height of his head, so the lifted shoulders and traps, the tower in front of him and the cable running down to the low pulley are visible.
```

### 255 アップライトロー
注記: 肩（三角筋の中部）にも効くが、muscle_group（僧帽筋）に合わせて僧帽筋を赤くする。
```
Next image: Barbell upright row.
Equipment: a straight barbell loaded with black plates.
Position: standing upright, overhand grip about shoulder width, the bar starting in front of the thighs.
Moment: the bar has been pulled straight up close to the body to chest height, elbows raised high out to the sides, above the hands.
Red muscles: traps (upper trapezius).
View: three-quarter front view so the traps and the raised elbows are visible.
```

## 肩

### 301 ショルダープレス（バーベル）
注記: 302 ミリタリープレス（立って行う）と見分けるため、ベンチに座る形で描く（立って行うなら直す）。
```
Next image: Seated barbell shoulder press.
Equipment: an upright shoulder press bench with a vertical backrest, and a straight barbell loaded with black plates.
Position: sitting upright with his back against the backrest, feet flat on the floor, overhand grip slightly wider than shoulder width.
Moment: halfway up, pressing the bar overhead from the front of the shoulders; the bar is in front of his face.
Red muscles: shoulders (deltoids), especially the front and side parts (anterior and lateral deltoid).
View: three-quarter front view so the shoulders are visible.
```

### 302 ミリタリープレス
```
Next image: Standing military press.
Equipment: a straight barbell loaded with black plates. No bench.
Position: standing upright with the feet close together, legs straight, body rigid, overhand grip slightly wider than shoulder width.
Moment: the bar has been pressed from the collarbones straight overhead, arms almost locked out, the bar above the top of his head.
Red muscles: shoulders (deltoids), especially the front part (anterior deltoid).
View: three-quarter front-side view so the shoulders and the standing posture are visible.
```

### 303 ショルダープレス（ダンベル）
```
Next image: Seated dumbbell shoulder press.
Equipment: an upright bench with a vertical backrest, and one dumbbell in each hand.
Position: sitting upright with his back against the backrest, feet flat on the floor.
Moment: halfway up, pressing both dumbbells overhead from shoulder height, palms facing forward, elbows out to the sides.
Red muscles: shoulders (deltoids), especially the front and side parts (anterior and lateral deltoid).
View: three-quarter front view so the shoulders are visible.
```

### 304 ショルダープレス（マシン）
```
Next image: Seated shoulder press machine.
Equipment: a shoulder press machine: a seat and an upright backrest built into the frame, two handles at shoulder height on lever arms that move straight up, and a weight stack behind.
Position: sitting upright with his back against the backrest, feet flat on the floor, hands on the handles beside his shoulders.
Moment: pressing the handles up overhead, arms halfway extended.
Red muscles: shoulders (deltoids), especially the front and side parts (anterior and lateral deltoid).
View: three-quarter front view so the shoulders and the whole machine are visible.
```

### 305 アーノルドプレス
```
Next image: Arnold press.
Equipment: an upright bench with a vertical backrest, and one dumbbell in each hand.
Position: sitting upright with his back against the backrest. Each rep starts with the dumbbells in front of his face at chin height, palms facing him, elbows in front of the body.
Moment: the middle of the press: the dumbbells are at forehead height and rising, the palms are turning outward (now facing each other, halfway to facing forward), and the elbows are swinging out to the sides.
Red muscles: shoulders (deltoids), especially the front and side parts (anterior and lateral deltoid).
View: three-quarter front view so the shoulders and the turning palms are visible.
```

### 306 サイドレイズ
```
Next image: Dumbbell lateral raise.
Equipment: one dumbbell in each hand.
Position: standing upright, feet hip-width apart.
Moment: both arms raised out to the sides to shoulder height, elbows slightly bent, palms facing down; the body makes a T shape.
Red muscles: side delts (lateral deltoid).
View: front view, slightly from one side, so the sides of the shoulders are visible.
```

### 307 ケーブルサイドレイズ
```
Next image: One-arm cable lateral raise.
Equipment: a single cable tower with the pulley at the bottom, near the floor, and a D-handle on the cable.
Position: standing sideways to the tower with his left side toward it, holding the D-handle in his right hand; the cable crosses in front of his body.
Moment: raising the right arm out to the side to shoulder height, elbow slightly bent.
Red muscles: side delt (lateral deltoid) of the right shoulder.
View: front view so the raised arm, the cable and the tower are visible.
```

### 308 マシンサイドレイズ
```
Next image: Machine lateral raise.
Equipment: a lateral raise machine: a seat in the middle, two padded lever arms on his left and right whose pads rest against the outside of his upper arms, and a weight stack behind.
Position: sitting upright, the outside of each upper arm against a pad, elbows bent, holding the handles.
Moment: raising both pads out to the sides with his upper arms until the upper arms are at shoulder height.
Red muscles: side delts (lateral deltoid).
View: front view so the shoulders and both lever arms are visible.
```

### 309 フロントレイズ
```
Next image: Dumbbell front raise.
Equipment: one dumbbell in each hand.
Position: standing upright, feet hip-width apart, the dumbbells starting in front of the thighs.
Moment: both arms raised straight forward to shoulder height, elbows slightly bent, palms facing down.
Red muscles: front delts (anterior deltoid).
View: three-quarter front-side view so the raised arms and the front of the shoulders are visible.
```

### 310 ケーブルフロントレイズ
```
Next image: Cable front raise.
Equipment: a single cable tower with the pulley at the bottom, near the floor, and a short straight bar on the cable.
Position: standing with his back to the tower, the tower directly behind him and not beside him; the low pulley is on the floor behind his heels, and the cable runs from it forward between his legs up to the bar; holding the bar with an overhand grip in front of his thighs.
Moment: raising the bar straight forward to shoulder height with almost straight arms.
Red muscles: front delts (anterior deltoid).
View: three-quarter front-side view so the raised arms and the cable are visible.
```

### 311 リアレイズ
```
Next image: Bent-over dumbbell rear delt raise.
Equipment: one dumbbell in each hand. No bench.
Position: standing, knees slightly bent, hinged forward at the hips until the torso is almost parallel to the floor, back flat.
Moment: both arms raised out to the sides to shoulder level, elbows slightly bent, palms facing down.
Red muscles: rear delts (posterior deltoid).
View: three-quarter rear-side view, the camera at the height of his head (not above him), so the back of the shoulders is visible.
```

### 312 リアデルトフライ（マシン）
```
Next image: Reverse fly machine for the rear delts.
Equipment: a chest fly machine used in reverse: a seat with a tall upright pad, two long swinging arms with vertical handles at shoulder height, and a weight stack.
Position: sitting facing the machine with his chest against the upright pad, arms straight in front of him at shoulder height holding the handles.
Moment: pulling both arms back and outward in an arc until they are in line with his shoulders, elbows slightly bent.
Red muscles: rear delts (posterior deltoid).
View: three-quarter rear view so the back of the shoulders is visible.
```

### 313 フェイスプル
```
Next image: Cable face pull.
Equipment: a single cable tower with the pulley set at face height, and a rope attachment with two ends.
Position: standing directly in front of the tower and facing it, feet hip-width apart, one end of the rope in each hand; the cable runs from the pulley in front of him to the rope at his face, never behind his head.
Moment: pulling the rope toward his face, the hands splitting apart to either side of his head at ear level, elbows high and out to the sides.
Red muscles: rear delts (posterior deltoid).
View: side view, slightly from behind, at eye level, so the back of the shoulders, the high elbows, and the tower and the cable in front of his face are visible.
```

### 314 パイクプッシュアップ
```
Next image: Pike push-up.
Equipment: none, on the floor.
Position: hands on the floor about shoulder width, hips raised high so the body forms an upside-down V, legs straight, on his toes.
Moment: elbows bending, lowering the top of his head toward the floor between his hands.
Red muscles: shoulders (deltoids), especially the front part (anterior deltoid).
View: exact side view at floor level, the camera at the height of his head, so the upside-down V shape, the shoulders and the side of his head (ear and face in profile) are visible; never the top of his head. His head is still clearly above the floor.
```

### 315 バンドプルアパート
```
Next image: Resistance band pull-apart.
Equipment: one flat black resistance band.
Position: standing upright, holding the band with both hands in front of him at shoulder height, arms straight, hands about shoulder width apart.
Moment: pulling the band apart until his arms are out to the sides in a T shape and the band touches his chest.
Red muscles: rear delts (posterior deltoid).
View: three-quarter rear view so the back of the shoulders and the stretched band are visible.
```

## 上腕二頭

### 401 バーベルカール
```
Next image: Barbell curl.
Equipment: a straight barbell loaded with black plates.
Position: standing upright, underhand grip about shoulder width (palms facing forward), elbows fixed at his sides.
Moment: halfway up, forearms horizontal, elbows bent 90 degrees.
Red muscles: biceps (biceps brachii).
View: three-quarter front view so the front of the upper arms is visible.
```

### 402 EZバーカール
```
Next image: EZ-bar curl.
Equipment: an EZ curl bar: a short bar with a zigzag W-shaped bend in the middle, loaded with small black plates.
Position: standing upright, hands on the angled parts of the bend (palms tilted inward, not flat), elbows fixed at his sides.
Moment: halfway up, forearms horizontal.
Red muscles: biceps (biceps brachii).
View: three-quarter front view so the zigzag shape of the bar and the front of the upper arms are clearly visible.
```

### 403 ドラッグカール
```
Next image: Barbell drag curl.
Equipment: a straight barbell loaded with black plates.
Position: standing upright, underhand grip about shoulder width.
Moment: the bar is dragged up along the front of his body, touching it, and is now at the bottom of the ribcage; the elbows move backward behind his torso instead of staying at his sides.
Red muscles: biceps (biceps brachii).
View: side view so the elbows behind the torso and the bar against the body are visible.
```

### 404 ダンベルカール
```
Next image: Dumbbell curl.
Equipment: one dumbbell in each hand.
Position: standing upright, elbows at his sides, palms facing forward (underhand).
Moment: the right arm curled up with the dumbbell near the shoulder, the left arm hanging straight down; the elbows stay at his sides. (In this exercise the arms alternate on purpose.)
Red muscles: biceps (biceps brachii).
View: three-quarter front view so the front of the upper arms is visible.
```

### 405 ハンマーカール
注記: ハンマーカールは上腕二頭筋に加えて、上腕筋と前腕の腕橈骨筋に強く効く。この 3 つを赤くする（muscle_group は上腕二頭）。
```
Next image: Dumbbell hammer curl.
Equipment: one dumbbell in each hand.
Position: standing upright, elbows at his sides, palms facing each other with the thumbs up, the dumbbells held vertically like hammers.
Moment: both arms curled halfway up, forearms horizontal, thumbs still pointing up.
Red muscles: biceps (biceps brachii), brachialis (under the biceps, on the outer upper arm) and brachioradialis (the top of the forearm near the elbow).
View: three-quarter front-side view so the thumbs-up grip and the outer arm are visible.
```

### 406 インクラインダンベルカール
```
Next image: Incline dumbbell curl.
Equipment: an adjustable bench with the backrest reclined to about 45-60 degrees, and one dumbbell in each hand.
Position: sitting and leaning back against the reclined backrest, arms hanging straight down behind the line of the torso, palms facing forward.
Moment: curling both dumbbells up while the upper arms stay hanging straight down; the forearms are halfway up.
Red muscles: biceps (biceps brachii).
View: side view so the reclined backrest and the arms hanging behind the torso are visible.
```

### 407 コンセントレーションカール
```
Next image: Concentration curl.
Equipment: a flat horizontal bench and one dumbbell.
Position: sitting on the end of the bench, legs wide apart, leaning forward, the back of the right upper arm braced against the inside of the right thigh, the left hand on the left knee.
Moment: curling the dumbbell up toward the right shoulder.
Red muscles: biceps (biceps brachii) of the right arm.
View: three-quarter front view so the working arm is visible.
```

### 408 スパイダーカール
```
Next image: Dumbbell spider curl.
Equipment: an adjustable bench set at about 45 degrees, and one dumbbell in each hand.
Position: lying face down on the inclined bench, chest against the backrest, head just above its top end, toes on the floor behind; arms hanging straight down toward the floor in front of the bench, palms facing forward.
Moment: curling both dumbbells up while the upper arms stay vertical.
Red muscles: biceps (biceps brachii).
View: side view at the height of his head so the face-down position, the vertical upper arms and the side of his face are visible.
```

### 409 プリーチャーカール（マシン）
```
Next image: Preacher curl machine.
Equipment: a preacher curl machine: a seat and, in front of his chest, an angled padded arm rest (preacher pad) sloping down away from him; two handles on a lever arm at the far end of the pad; a weight stack.
Position: sitting upright, the backs of his upper arms resting flat on the angled pad, underhand grip on the handles.
Moment: curling the handles up toward his shoulders, forearms halfway up.
Red muscles: biceps (biceps brachii).
View: three-quarter front-side view so the arms on the pad are visible.
```

### 410 ケーブルカール
```
Next image: Cable curl.
Equipment: a single cable tower with the pulley at the bottom, near the floor, and a short straight bar on the cable.
Position: standing upright facing the tower about one step away, underhand grip about shoulder width, elbows fixed at his sides.
Moment: halfway up, forearms horizontal, the cable running down to the low pulley.
Red muscles: biceps (biceps brachii).
View: exact side view (profile): his body faces the right side of the image and the tower stands at the right, directly in front of him, so the curling arms, the tower and the cable from the low pulley to the bar are visible.
```

## 上腕三頭

### 501 トライセプスプレスダウン
```
Next image: Cable triceps pressdown with a bar.
Equipment: a single cable tower with the pulley set high above his head, and a short straight bar on the cable.
Position: standing upright facing the tower, close to it, overhand grip, elbows tucked at his sides.
Moment: pushing the bar down until the arms are almost straight, the bar in front of the thighs; the upper arms stay still.
Red muscles: triceps (triceps brachii, the back of the upper arm).
View: three-quarter rear-side view so the back of the upper arms is visible.
```

### 502 ロープトライセプスプレスダウン
```
Next image: Rope triceps pressdown.
Equipment: a single cable tower with the pulley set high above his head, and a rope attachment with two ends.
Position: standing upright facing the tower, one end of the rope in each hand, palms facing each other, elbows tucked at his sides.
Moment: the arms pushed down almost straight, the rope ends spread apart beside the outside of his thighs.
Red muscles: triceps (triceps brachii).
View: three-quarter rear-side view so the back of the upper arms and the split rope are visible.
```

### 503 ケーブルオーバーヘッドエクステンション
```
Next image: Cable overhead triceps extension.
Equipment: a single cable tower with the pulley set at head height, and a rope attachment.
Position: standing with his back to the tower, one foot in front of the other, leaning slightly forward, holding the rope ends behind his head, elbows bent and pointing forward beside his head.
Moment: extending the arms forward and up until they are almost straight in front of his forehead; the upper arms stay beside his head.
Red muscles: triceps (triceps brachii).
View: side view so the back of the upper arms and the cable coming from behind are visible.
```

### 504 ライイングトライセプスエクステンション
```
Next image: Lying barbell triceps extension.
Equipment: a flat horizontal bench and a short straight barbell with small black plates.
Position: lying face up on the bench, feet flat on the floor, narrow overhand grip (hands about 20 cm apart), upper arms vertical and kept still.
Moment: bending only the elbows, lowering the bar toward his forehead, elbows pointing up at the ceiling.
Red muscles: triceps (triceps brachii).
View: side view so the bent elbows and the back of the upper arms are visible.
```

### 505 ナローグリップベンチプレス
```
Next image: Close-grip bench press.
Equipment: a flat horizontal bench and a straight barbell loaded with black plates.
Position: lying face up on the bench, feet flat on the floor, hands about shoulder width apart (clearly narrower than a normal bench press), elbows tucked close to the body.
Moment: pressing the bar up from the lower chest, arms halfway extended.
Red muscles: triceps (triceps brachii).
View: side view so the back of the upper arms and the narrow grip are visible.
```

### 506 オーバーヘッドトライセプスエクステンション
```
Next image: Seated overhead dumbbell triceps extension.
Equipment: an upright bench with a short backrest, and one dumbbell held with both hands: palms against the underside of the top plate.
Position: sitting upright, the dumbbell behind his head, elbows bent and pointing up at the ceiling close to his head.
Moment: extending the arms until they are almost straight overhead; the upper arms stay beside his ears.
Red muscles: triceps (triceps brachii).
View: three-quarter rear-side view so the back of the upper arms is visible.
```

### 507 キックバック
```
Next image: Dumbbell triceps kickback.
Equipment: a flat horizontal bench and one dumbbell.
Position: left knee and left hand on the bench, torso parallel to the floor, the right upper arm held close to the side of the body and parallel to the floor.
Moment: extending the right forearm backward until the whole arm is straight and parallel to the floor; the upper arm stays still.
Red muscles: triceps (triceps brachii) of the right arm.
View: side view from his right so the straight working arm is visible.
```

### 508 トライセプスマシン
要確認: ジムにより、肘を前の斜めのパッドに置いて前へ伸ばす型と、座って体の横のハンドルを下へ押す型（シーテッドディップ）がある。前者で書いた。
```
Next image: Seated triceps extension machine.
Equipment: a seated triceps extension machine: a seat, an angled padded arm rest in front of his chest, two handles on a lever arm at the far end of the pad, and a weight stack.
Position: sitting upright, elbows and the backs of the upper arms resting on the angled pad, hands holding the handles near his shoulders.
Moment: pushing the handles forward and down by straightening the elbows; the arms are almost straight along the pad.
Red muscles: triceps (triceps brachii).
View: side view so the back of the upper arms and the pad are visible.
```

### 509 ディップス（三頭）
注記: 115 と同じ器具。体を立てて肘を体の横に引きつける姿勢にして三頭を赤くする。
```
Next image: Triceps dips.
Equipment: a dip station: two parallel horizontal bars about shoulder width apart at waist height, on a black stand.
Position: supporting his body on the bars, torso upright (vertical, not leaning forward), legs hanging straight down with the knees slightly bent, feet off the floor.
Moment: halfway down, elbows bent about 90 degrees and pointing straight back, close to the body.
Red muscles: triceps (triceps brachii).
View: three-quarter rear-side view so the back of the upper arms and the upright torso are visible.
```

### 510 ベンチディップス
```
Next image: Bench dips.
Equipment: one flat horizontal bench.
Position: hands on the edge of the bench behind him, fingers pointing forward, legs stretched out in front with the heels on the floor, hips just in front of the bench edge.
Moment: lowering the hips by bending the elbows to about 90 degrees, elbows pointing straight back.
Red muscles: triceps (triceps brachii).
View: side view so the bent elbows and the back of the upper arms are visible.
```

### 511 ナロープッシュアップ
```
Next image: Close-grip push-up.
Equipment: none, on the floor.
Position: hands close together under the chest, thumbs and index fingers nearly touching, body straight from head to heels, on his toes.
Moment: halfway down, elbows bent and kept close to the ribs, pointing back.
Red muscles: triceps (triceps brachii).
View: low three-quarter side view, the camera at the height of his head, so the narrow hands, the back of the upper arms and his face in profile are visible; never the top of his head.
```

## 前腕

### 601 リストカール
```
Next image: Dumbbell wrist curl.
Equipment: a flat horizontal bench and one dumbbell in each hand.
Position: sitting on the end of the bench, leaning forward, forearms resting on his thighs with the palms facing up, wrists hanging just past the knees.
Moment: curling the wrists up so the dumbbells rise toward him; only the wrists move.
Red muscles: inner forearms (forearm flexors: flexor carpi radialis and flexor carpi ulnaris).
View: three-quarter front view at the height of the bench, so the inner forearms and his face are visible; we do not look down onto the top of his head.
```

### 602 リバースリストカール
```
Next image: Dumbbell reverse wrist curl.
Equipment: a flat horizontal bench and one dumbbell in each hand.
Position: sitting on the end of the bench, leaning forward, forearms resting on his thighs with the palms facing down, wrists hanging just past the knees.
Moment: lifting the backs of the hands up by bending the wrists upward; only the wrists move.
Red muscles: outer forearms (forearm extensors: extensor carpi radialis and extensor carpi ulnaris).
View: three-quarter front view at the height of the bench, so the tops of the forearms and his face are visible; we do not look down onto the top of his head.
```

### 603 リバースカール
```
Next image: Barbell reverse curl.
Equipment: a straight barbell loaded with small black plates.
Position: standing upright, overhand grip about shoulder width (palms facing down and back), elbows at his sides.
Moment: curling the bar halfway up, forearms horizontal, palms facing down.
Red muscles: the top of the forearms (brachioradialis and the forearm extensors).
View: three-quarter front-side view so the tops of the forearms are visible.
```

### 604 デッドハング
```
Next image: Dead hang.
Equipment: a straight horizontal bar high on a black pull-up station.
Position: hanging from the bar with straight arms, overhand grip about shoulder width, body relaxed and straight, feet off the floor.
Moment: holding the hang still.
Red muscles: forearms (forearm flexors, the grip muscles).
View: three-quarter front view so the forearms and the hands on the bar are visible.
```

### 605 ハンドグリップ
```
Next image: Hand gripper squeeze.
Equipment: one hand gripper: two black handles joined by a coiled spring at one end.
Position: standing upright, the right elbow bent and the right hand raised in front of his chest, holding the gripper so it is clearly visible.
Moment: squeezing the gripper closed until the two handles nearly touch.
Red muscles: inner forearm of the right arm (forearm flexors: flexor carpi radialis, flexor carpi ulnaris and flexor digitorum).
View: three-quarter front view; the gripper is small, so keep the hand and the gripper clearly visible.
```

## 大腿四頭

### 701 バーベルスクワット
```
Next image: Barbell back squat.
Equipment: a straight barbell loaded with black plates, resting across his upper back behind the neck. No rack.
Position: feet about shoulder width, toes slightly out, hands gripping the bar wider than his shoulders.
Moment: the bottom of the squat: thighs parallel to the floor, knees forward over the toes, back flat, torso leaning slightly forward.
Red muscles: quads (quadriceps femoris, the front of the thighs).
View: three-quarter front-side view so the front of the thighs is visible.
```

### 702 フロントスクワット
```
Next image: Barbell front squat.
Equipment: a straight barbell loaded with black plates, resting on the front of his shoulders close to the throat (not on his back). No rack.
Position: elbows raised high and pointing forward, fingertips under the bar, feet about shoulder width.
Moment: the bottom of the squat: thighs parallel to the floor or lower, torso very upright.
Red muscles: quads (quadriceps femoris).
View: three-quarter front-side view so the bar on the front of the shoulders and the thighs are visible.
```

### 703 スミスマシンスクワット
```
Next image: Smith machine squat.
Equipment: a Smith machine: a tall black frame with two vertical guide rails; the barbell is fixed to the rails and slides only straight up and down; black plates on the bar ends.
Position: standing inside the frame, the bar across his upper back behind the neck, feet about shoulder width and slightly in front of the bar.
Moment: the bottom of the squat: thighs parallel to the floor, torso upright.
Red muscles: quads (quadriceps femoris).
View: three-quarter front-side view so the thighs and the vertical rails are visible.
```

### 704 レッグプレス
試作済み: `workout_image3.png` を `704.png` としてそのまま使う。作り直すときだけ、このプロンプトを送る。
```
Next image: 45-degree leg press.
Equipment: a 45-degree leg press machine: a low reclined seat and backrest at the bottom, a large foot platform on a sled that slides on diagonal rails at 45 degrees above him, black plates on the sled's side holders, and side handles by the seat.
Position: lying back on the seat, both feet flat on the platform about shoulder width apart, hands on the side handles.
Moment: pushing the platform up, knees slightly bent, not locked.
Red muscles: quads (quadriceps femoris).
View: side view, slightly from the front, so the whole machine and the thighs are visible.
```

### 705 ハックスクワット
```
Next image: Hack squat machine.
Equipment: a hack squat machine: a back pad with two shoulder pads on a sled that slides on rails angled at about 45 degrees, and a large angled foot platform at the bottom; black plates on the sled.
Position: standing on the foot platform with his back against the back pad, the shoulder pads resting on top of his shoulders, hands on the handles beside the shoulder pads. He is standing, not sitting: his body moves together with the sled.
Moment: squatting down until the thighs are parallel to the platform.
Red muscles: quads (quadriceps femoris).
View: side view so the angled rails, the shoulder pads and the thighs are visible.
```

### 706 レッグエクステンション
```
Next image: Leg extension machine.
Equipment: a leg extension machine: a padded seat and an upright backrest, a padded roller across the front of his lower shins just above the ankles, side handles, and a weight stack.
Position: sitting upright, the backs of the knees at the front edge of the seat, holding the side handles.
Moment: legs extended almost straight forward, lifting the roller.
Red muscles: quads (quadriceps femoris).
View: three-quarter front-side view so the front of the thighs and the roller are visible.
```

### 707 ブルガリアンスクワット
```
Next image: Bulgarian split squat with dumbbells.
Equipment: a flat horizontal bench and one dumbbell in each hand.
Position: standing in front of the bench, the right foot flat on the floor a long step ahead, the top of the left foot resting on the bench behind him, dumbbells hanging at his sides.
Moment: lowered down: the right thigh nearly parallel to the floor, the left knee close to the floor, torso upright.
Red muscles: quads (quadriceps femoris) of the front (right) leg.
View: side view from his right so the front thigh and the rear foot on the bench are visible.
```

### 708 ダンベルランジ
注記: 静止画では 709 と見分けにくい。708 は前へ 1 歩踏み出してから元の位置に戻る形、709 は前へ歩いて進み続ける形で描く。
```
Next image: Dumbbell forward lunge.
Equipment: one dumbbell in each hand.
Position: he has taken one big step forward from standing with the right foot and will push back to the starting position; the left foot stays where it was, on the ball of the foot.
Moment: the bottom of the lunge: both knees bent about 90 degrees, the left knee just above the floor, torso upright, dumbbells hanging at his sides.
Red muscles: quads (quadriceps femoris), mainly of the front (right) leg.
View: side view so both bent legs are visible.
```

### 709 ウォーキングランジ
```
Next image: Walking lunge with dumbbells.
Equipment: one dumbbell in each hand.
Position: walking forward across the floor with long lunge steps, one step after another.
Moment: the bottom of a long forward step: the left foot has just landed far ahead, both knees bent, the right knee near the floor, the right heel lifted, his weight moving forward onto the front foot, torso upright, dumbbells hanging at his sides. It should read as walking forward, not as standing in place.
Red muscles: quads (quadriceps femoris), mainly of the front (left) leg.
View: three-quarter front-side view so the forward direction of the walk is clear.
```

### 710 ゴブレットスクワット
```
Next image: Dumbbell goblet squat.
Equipment: one dumbbell held vertically in front of his chest, both hands cupping its top end (like holding a goblet).
Position: feet slightly wider than shoulder width, toes slightly out.
Moment: the bottom of a deep squat: thighs below parallel, torso upright, elbows inside the knees.
Red muscles: quads (quadriceps femoris).
View: three-quarter front view so the dumbbell at the chest and the thighs are visible.
```

### 711 ステップアップ
```
Next image: Dumbbell step-up.
Equipment: a sturdy black box about knee height, and one dumbbell in each hand.
Position: standing in front of the box, the right foot flat on top of the box, dumbbells hanging at his sides.
Moment: pushing up through the right leg: the right knee is straightening and the left foot has just left the floor.
Red muscles: quads (quadriceps femoris) of the right (stepping) leg.
View: side view so the box and the stepping leg are visible.
```

### 712 自重スクワット
```
Next image: Bodyweight squat.
Equipment: none.
Position: feet about shoulder width, toes slightly out, arms stretched straight forward at shoulder height for balance.
Moment: the bottom of the squat: thighs parallel to the floor, back flat, torso upright.
Red muscles: quads (quadriceps femoris).
View: three-quarter front-side view so the front of the thighs is visible.
```

### 713 シシースクワット
```
Next image: Bodyweight sissy squat.
Equipment: one black vertical post for balance.
Position: standing on the balls of his feet with the heels raised, holding the post lightly with one hand.
Moment: knees pushed far forward and bent deeply while the hips stay straight: the torso and thighs form one straight line leaning far back, the head behind the heels.
Red muscles: quads (quadriceps femoris).
View: side view so the backward-leaning straight line from the knees to the head is visible.
```

### 714 ジャンピングスクワット
```
Next image: Jump squat.
Equipment: none.
Position: he has exploded upward from a squat.
Moment: in the air at the top of the jump: body straight, feet clearly off the floor with the toes pointed down, arms swung down and slightly back; a soft shadow on the floor below him.
Red muscles: quads (quadriceps femoris).
View: three-quarter front view so the thighs and the gap under the feet are visible.
```

### 715 ウォールシット
```
Next image: Wall sit.
Equipment: a plain flat vertical wall panel behind him (draw it as a simple black panel standing on the floor, no room around it).
Position: back flat against the panel as if sitting on an invisible chair, feet flat on the floor in front of him.
Moment: holding still: thighs parallel to the floor, knees bent 90 degrees, shins vertical, arms crossed over the chest.
Red muscles: quads (quadriceps femoris).
View: side view, slightly from the front, so the thighs are visible.
```

## ハムストリング

### 801 レッグカール（ライイング）
```
Next image: Lying leg curl machine.
Equipment: a lying leg curl machine: a padded bench he lies face down on, a padded roller resting on the back of his lower legs just above the heels, handles at the front, and a weight stack.
Position: lying face down on the bench, knees just past the end of the pad, holding the front handles.
Moment: curling the heels up toward the buttocks, knees bent about 90 degrees, the roller lifted.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus, the back of the thighs).
View: three-quarter rear-side view so the back of the thighs is visible.
```

### 802 レッグカール（シーテッド）
```
Next image: Seated leg curl machine.
Equipment: a seated leg curl machine: a padded seat and backrest, a padded thigh pad pressing down on the tops of his thighs just above the knees, a padded roller behind his lower legs just above the ankles, side handles, and a weight stack.
Position: sitting upright, legs starting straight out in front of him, the thigh pad on top of the thighs.
Moment: pushing the roller down and back, knees bent about 90 degrees, feet now under the front of the seat.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus).
View: side view, slightly from below, so the back of the thighs is visible.
```

### 803 ルーマニアンデッドリフト
```
Next image: Barbell Romanian deadlift.
Equipment: a straight barbell loaded with black plates. The lift starts from standing, not from the floor.
Position: feet hip-width apart, overhand grip just outside the thighs, knees slightly bent and kept at the same angle, back flat.
Moment: hinging at the hips and pushing the hips back; the bar has slid down along the thighs to just below the knees; the plates stay clearly above the floor.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus).
View: side view, slightly from behind, so the back of the thighs is visible.
```

### 804 スティフレッグデッドリフト
```
Next image: Barbell stiff-leg deadlift.
Equipment: a straight barbell loaded with black plates.
Position: feet hip-width apart, overhand grip, legs nearly straight (knees almost locked, clearly straighter than in a Romanian deadlift).
Moment: bent forward at the hips with the legs still almost straight; the bar is lowered to mid-shin, close to the floor. This must look clearly different from a Romanian deadlift: the legs are straight, the torso almost parallel to the floor, the plates only a few centimetres above the floor.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus).
View: side view, slightly from behind, so the back of the thighs is visible.
```

### 805 グッドモーニング
```
Next image: Barbell good morning.
Equipment: a straight barbell loaded with black plates, resting across his upper back behind the neck (as in a back squat). No rack.
Position: feet hip-width apart, hands holding the bar on his back, knees slightly bent.
Moment: hinged forward at the hips until the torso is almost parallel to the floor, back flat, hips pushed back.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus).
View: exact side view, the camera at the height of his back, so the horizontal torso (head at the same height as the hips), the hips pushed back and the back of the thighs are visible.
```

### 806 ダンベルルーマニアンデッドリフト
```
Next image: Dumbbell Romanian deadlift.
Equipment: one dumbbell in each hand (no barbell).
Position: feet hip-width apart, dumbbells in front of the thighs with the palms facing his body, knees slightly bent, back flat.
Moment: hinging at the hips and pushing the hips back; the dumbbells have slid down along the front of the legs to just below the knees.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus).
View: side view, slightly from behind, so the back of the thighs is visible.
```

### 807 ノルディックハムストリングカール
```
Next image: Nordic hamstring curl.
Equipment: a thin black kneeling pad and a low black padded bar fixed to the floor that holds his heels down (no partner).
Position: kneeling upright on the pad, the backs of his ankles hooked under the fixed padded bar, body straight from the knees to the head, hands in front of the chest ready to catch himself.
Moment: slowly falling forward: the straight body leans about 45 degrees forward from the knees.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus).
View: side view so the back of the thighs and the forward lean are visible.
```

### 808 グルートハムレイズ
```
Next image: Glute-ham raise.
Equipment: a glute-ham developer: a long black frame with a rounded padded thigh pad, and at the back end a foot plate with padded rollers behind the ankles.
Position: face down, the fronts of his thighs on the rounded pad, the balls of his feet against the foot plate, ankles locked under the rollers.
Moment: curling up from a horizontal body: the knees bending and the straight torso rising toward upright, about halfway.
Red muscles: hamstrings (biceps femoris, semitendinosus and semimembranosus).
View: side view so the back of the thighs and the whole apparatus are visible.
```

## 臀部

### 851 ヒップスラスト
```
Next image: Barbell hip thrust.
Equipment: a flat horizontal bench and a straight barbell loaded with black plates, with a thick black pad around the middle of the bar.
Position: his upper back (shoulder blades) resting on the long side of the bench, knees bent, feet flat on the floor, the padded bar across the crease of his hips, hands holding the bar.
Moment: hips driven up to full extension: the body is flat from the shoulders to the knees like a table top, shins vertical.
Red muscles: glutes (gluteus maximus).
View: side view, slightly from the front, so the glutes are visible.
```

### 852 ヒップスラスト（マシン）
注記: マシンの形はジムで違う。背中を預けるパッド・腰の上のパッド・足の台がある型で描く。
```
Next image: Hip thrust machine.
Equipment: a hip thrust machine: an angled back pad that supports his shoulder blades, a padded lever (or a padded belt) across the front of his hips connected to the machine's weight, and a foot platform.
Position: shoulder blades on the back pad, feet flat on the platform, knees bent, the hip pad on the crease of his hips, hands on the handles.
Moment: hips pushed up to full extension, body flat from the shoulders to the knees, shins vertical.
Red muscles: glutes (gluteus maximus). The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view, slightly from the front, so the glutes are visible.
```

### 853 ヒップアブダクション（マシン）
```
Next image: Hip abduction machine.
Equipment: a hip abduction machine: a seat with a reclined backrest and two padded leg arms; the pads touch the OUTSIDE of his knees and thighs; a weight stack.
Position: sitting with his back against the backrest, the outer sides of his knees against the pads, holding the side handles.
Moment: pushing both knees apart, outward, until the legs are wide open.
Red muscles: the outer upper glutes on the sides of the hips (gluteus medius and gluteus minimus).
View: three-quarter front view, slightly from one side, so the side of the hips is visible.
```

### 854 ヒップアダクション（マシン）
注記: muscle_group は臀部だが、主に効くのは内もも（内転筋群）。内転筋を赤くする。
```
Next image: Hip adduction machine.
Equipment: a hip adduction machine: a seat with a reclined backrest and two padded leg arms; the pads touch the INSIDE of his knees and thighs; a weight stack.
Position: sitting with his back against the backrest, legs spread wide apart, the inner sides of his knees against the pads, holding the side handles.
Moment: squeezing both knees together, inward, halfway closed.
Red muscles: inner thighs (adductor magnus, adductor longus and adductor brevis).
View: front view so the inner thighs are visible.
```

### 855 バックキック（マシン）
要確認: マシンの形がジムで大きく違う（台に前腕と胸を預けて足の裏で板を押す型・立って膝の裏のパッドを後ろへ押す型など）。前者で書いた。
```
Next image: Glute kickback machine.
Equipment: a glute kickback machine: a padded chest and forearm support at waist height with handles, and behind him a footplate on a lever arm connected to a weight stack.
Position: leaning forward with his forearms and chest on the support, the left foot standing on the machine's platform, the sole of the right foot against the footplate.
Moment: kicking the right leg back and up, pushing the footplate until the right thigh is in line with the torso.
Red muscles: glutes (gluteus maximus), especially on the right (kicking) side. The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view, slightly from behind, so the glutes are visible.
```

### 856 ケーブルキックバック
```
Next image: Cable glute kickback.
Equipment: a single cable tower with the pulley at the bottom, near the floor, and an ankle strap on the cable.
Position: standing facing the tower, holding the frame with both hands, leaning slightly forward, the strap around his right ankle.
Moment: kicking the right leg straight back and up behind him, knee almost straight; the left leg stays standing.
Red muscles: glutes (gluteus maximus), especially on the right (kicking) side. The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view, slightly from behind, so the glutes are visible.
```

### 857 グルートブリッジ
```
Next image: Glute bridge.
Equipment: none, lying on the floor (no bench: his shoulders stay on the floor).
Position: lying on his back, knees bent, feet flat on the floor near the buttocks, arms on the floor at his sides.
Moment: hips lifted so the body is a straight line from the shoulders to the knees.
Red muscles: glutes (gluteus maximus).
View: side view so the lifted hips and the glutes are visible.
```

## ふくらはぎ

### 901 スタンディングカーフレイズ
```
Next image: Standing calf raise machine.
Equipment: a standing calf raise machine: two padded shoulder pads on a lever above him, a raised foot block at the bottom, and a weight stack.
Position: standing upright under the machine, the shoulder pads on top of his shoulders, the balls of his feet on the edge of the block, heels hanging off, legs straight.
Moment: rising high onto his toes, heels lifted well above the block.
Red muscles: calves (gastrocnemius and soleus).
View: three-quarter rear-side view so the calves are visible.
```

### 902 シーテッドカーフレイズ
```
Next image: Seated calf raise machine.
Equipment: a seated calf raise machine: a seat, a padded lever resting on top of his lower thighs just above the knees, and a foot plate in front.
Position: sitting with the knees bent 90 degrees, the balls of his feet on the edge of the foot plate, heels hanging off.
Moment: heels lifted as high as possible, raising the padded lever.
Red muscles: calves (soleus and gastrocnemius).
View: side view, slightly from behind, so the calves are visible.
```

### 903 レッグプレスカーフレイズ
```
Next image: Calf raise on the 45-degree leg press.
Equipment: a 45-degree leg press machine: a low reclined seat, a large foot platform on a sled on diagonal rails at 45 degrees, black plates on the sled.
Position: lying back on the seat, legs almost straight, only the balls of his feet on the lower edge of the platform, heels hanging off.
Moment: pushing the platform by pointing his toes (ankles extended); the knees stay almost straight and do not bend.
Red muscles: calves (gastrocnemius and soleus).
View: side view so the feet on the edge of the platform and the calves are visible.
```

### 904 ダンベルカーフレイズ
```
Next image: Dumbbell calf raise.
Equipment: a low black step block and one dumbbell in each hand.
Position: standing upright, the balls of both feet on the edge of the block, heels hanging off, dumbbells at his sides.
Moment: rising high onto his toes, heels lifted.
Red muscles: calves (gastrocnemius and soleus).
View: three-quarter rear-side view so the calves are visible.
```

## 体幹

### 1001 クランチ
```
Next image: Crunch.
Equipment: none, lying on the floor.
Position: lying on his back, knees bent, feet flat on the floor, fingertips lightly touching the sides of his head.
Moment: curling only the shoulders and upper back off the floor; the lower back stays on the floor.
Red muscles: abs (rectus abdominis).
View: three-quarter side view from slightly above so the abs are visible.
```

### 1002 シットアップ
```
Next image: Sit-up.
Equipment: none, on the floor.
Position: lying on his back, knees bent, feet flat on the floor, arms crossed over the chest.
Moment: the whole back has left the floor and the torso is halfway up, at about 45 degrees (much higher than a crunch).
Red muscles: abs (rectus abdominis).
View: side view, slightly from the front, so the abs are visible.
```

### 1003 バイシクルクランチ
```
Next image: Bicycle crunch.
Equipment: none, lying on the floor.
Position: lying on his back, hands behind his head, shoulders off the floor, both legs off the floor.
Moment: twisting so the right elbow comes toward the left knee, which is pulled in toward the chest, while the right leg extends straight out just above the floor.
Red muscles: abs (rectus abdominis) and obliques (external obliques, the sides of the waist).
View: three-quarter front view from slightly above so the abs and the twist are visible.
```

### 1004 レッグレイズ
```
Next image: Lying leg raise.
Equipment: none, lying on the floor.
Position: lying on his back, arms on the floor at his sides with the palms down, legs straight and together.
Moment: raising the straight legs until they are about 60 degrees off the floor; the lower back stays on the floor.
Red muscles: abs (rectus abdominis), especially the lower part.
View: side view so the raised straight legs and the abs are visible.
```

### 1005 ハンギングレッグレイズ
```
Next image: Hanging leg raise.
Equipment: a straight horizontal bar high on a black pull-up station.
Position: hanging from the bar with straight arms, overhand grip about shoulder width.
Moment: both legs straight and together, raised in front until they are parallel to the floor (an L shape).
Red muscles: abs (rectus abdominis).
View: three-quarter front-side view so the abs and the L shape are visible.
```

### 1006 ハンギングニーレイズ
```
Next image: Hanging knee raise.
Equipment: a straight horizontal bar high on a black pull-up station.
Position: hanging from the bar with straight arms, overhand grip about shoulder width.
Moment: knees bent and pulled up toward the chest, thighs above parallel to the floor (legs bent, not straight).
Red muscles: abs (rectus abdominis).
View: three-quarter front-side view so the abs and the bent legs are visible. Square 1:1 image with the whole pull-up station, his hands on the bar and his feet inside the frame.
```

### 1007 Vシット
```
Next image: V-sit (V-up).
Equipment: none, on the floor.
Position: balancing on his buttocks.
Moment: the top of the movement: legs straight and raised, torso leaning back, arms reaching straight forward beside the shins; the body forms a sharp V, with both the feet and the shoulders off the floor.
Red muscles: abs (rectus abdominis).
View: side view so the V shape is visible.
```

### 1008 デッドバグ
```
Next image: Dead bug. He wears his loose black athletic shorts, clearly visible, like a fitness textbook illustration.
Equipment: none, lying on the floor.
Position: lying on his back, lower back pressed into the floor. In the starting position both arms point straight up at the ceiling and the hips and knees are bent 90 degrees (shins parallel to the floor).
Moment: the right arm reaching back overhead just above the floor and the left leg extended straight just above the floor, while the left arm and the right leg stay in the starting position.
Red muscles: abs (rectus abdominis) and obliques (external and internal obliques).
View: low three-quarter side view, the camera at the height of his head, so the opposite arm and leg are clearly visible.
```

### 1009 バードドッグ
注記: 体幹の種目だが、主に働くのは背中側の脊柱起立筋と腹。両方を赤くする。
```
Next image: Bird dog.
Equipment: none, on the floor.
Position: on hands and knees, hands under the shoulders, knees under the hips, back flat like a table top.
Moment: the right arm extended straight forward at shoulder height and the left leg extended straight back at hip height, both parallel to the floor; the back stays flat.
Red muscles: lower back (erector spinae) and abs (rectus abdominis and obliques).
View: side view at body height so both the back and the belly are visible.
```

### 1010 アブローラー
```
Next image: Ab wheel rollout.
Equipment: an ab wheel: a small single wheel with a handle on each side.
Position: kneeling on the floor, holding the handles of the ab wheel with both hands.
Moment: rolled far forward: arms extended straight in front of his head, body almost straight from the knees to the hands and close to the floor.
Red muscles: abs (rectus abdominis).
View: side view so the long extended body and the wheel are visible.
```

### 1011 プランク
```
Next image: Forearm plank.
Equipment: none, on the floor.
Position: forearms on the floor, elbows under the shoulders, on his toes, body in one straight line from head to heels.
Moment: holding still.
Red muscles: abs (rectus abdominis) and obliques (external and internal obliques).
View: low side view, slightly from the front, so the abs are visible.
```

### 1012 サイドプランク
```
Next image: Side plank.
Equipment: none, on the floor.
Position: lying on his left side, propped up on the left forearm with the elbow under the shoulder, feet stacked, his front facing the viewer.
Moment: hips lifted so the body is one straight line from head to feet; the right hand on the right hip.
Red muscles: obliques (external and internal obliques, the sides of the waist).
View: front view so the side of the waist is visible.
```

### 1013 ホローホールド
```
Next image: Hollow body hold.
Equipment: none, lying on the floor.
Position: lying on his back, lower back pressed into the floor, arms stretched straight overhead beside his ears, legs straight and together.
Moment: holding still with the shoulders and the legs lifted about 15 cm off the floor; the body forms a long, shallow banana-shaped curve, low to the floor (not a V).
Red muscles: abs (rectus abdominis).
View: side view so the shallow curve is visible.
```

### 1014 マウンテンクライマー
```
Next image: Mountain climber.
Equipment: none, on the floor.
Position: a high plank on straight arms, hands under the shoulders, body straight.
Moment: the right knee driven forward toward the chest while the left leg is extended straight back, as if running in place.
Red muscles: abs (rectus abdominis) only. The neck, chest and shoulders stay light grey.
View: low three-quarter side view, the camera at the height of his head, so the driven knee, the abs and his face in profile are visible.
```

### 1015 ロシアンツイスト
```
Next image: Russian twist with a dumbbell.
Equipment: one dumbbell held with both hands.
Position: sitting on the floor, knees bent, feet lifted just off the floor, torso leaning back about 45 degrees, back straight.
Moment: rotating the torso to his right, the dumbbell beside the right hip.
Red muscles: obliques (external and internal obliques) and abs (rectus abdominis).
View: three-quarter front view so the twist and the sides of the waist are visible.
```

### 1016 ケーブルクランチ
```
Next image: Kneeling cable crunch.
Equipment: a single cable tower with the pulley set high above his head, and a rope attachment.
Position: kneeling on the floor facing the tower, holding the rope ends beside his ears.
Moment: crunching down by rounding the spine, the elbows moving toward the knees; the hips stay still above the knees.
Red muscles: abs (rectus abdominis).
View: side view so the rounded spine and the abs are visible.
```

### 1017 アブドミナルクランチ（マシン）
注記: マシンの形はジムで違う。肩の上のハンドルを握って前へ丸まる型で描く。
```
Next image: Seated abdominal crunch machine.
Equipment: a seated ab crunch machine: a seat, a backrest, handles (or pads) above his shoulders on a lever arm, padded rollers in front of the lower shins, and a weight stack.
Position: sitting upright, holding the handles above his shoulders, feet hooked under the rollers.
Moment: curling the torso forward and down, rounding the spine, chest moving toward the thighs.
Red muscles: abs (rectus abdominis).
View: side view, slightly from the front, so the abs are visible.
```

### 1018 トーソローテーション（マシン）
要確認: 座って上体をひねる型（胸の前のパッドを抱える）と、座面ごと下半身を回す型がある。前者で書いた。
```
Next image: Seated torso rotation machine.
Equipment: a rotary torso machine: a seat, a padded chest support in front of him with arm pads, a foot rest, and a weight stack.
Position: sitting upright, chest against the front pad, arms hooked around the arm pads, feet on the foot rest.
Moment: rotating the upper body to one side against the resistance while the hips stay facing forward.
Red muscles: obliques (external and internal obliques).
View: three-quarter front view so the twist and the sides of the waist are visible.
```

## 有酸素

### 1101 トレッドミル（ランニング）
```
Next image: Running on a treadmill.
Equipment: a treadmill: a long running belt on a low deck, two side handrails, and a front console with a blank screen.
Position: on the belt, facing the console.
Moment: mid-stride running: one knee driven forward, the other leg pushing off behind, arms swinging with the elbows bent about 90 degrees, both feet briefly off the belt.
Red muscles: quads (quadriceps femoris), hamstrings (biceps femoris, semitendinosus and semimembranosus) and calves (gastrocnemius and soleus).
View: side view so the whole treadmill and the running stride are visible.
```

### 1102 トレッドミル（ウォーキング）
```
Next image: Walking on a treadmill.
Equipment: a treadmill: a long belt on a low deck, two side handrails, and a front console with a blank screen.
Position: on the belt, facing the console, body upright.
Moment: a relaxed walking step: the front heel touching the belt, the rear foot pushing off from the toes, arms swinging naturally; one foot is always on the belt (walking, not running).
Red muscles: quads (quadriceps femoris), hamstrings (biceps femoris, semitendinosus and semimembranosus) and calves (gastrocnemius and soleus).
View: side view so the whole treadmill and the walking step are visible.
```

### 1103 エアロバイク
注記: 「エアロバイク」は製品名（商標）として使われている呼び名なので、英文では一般名（upright stationary exercise bike）にする。
```
Next image: Upright stationary exercise bike.
Equipment: an upright stationary bike on a fixed base: a saddle, handlebars at the front, a heavy flywheel cover at the front bottom, pedals, and a console with a blank screen.
Position: sitting upright on the saddle, hands on the handlebars.
Moment: pedaling: one leg extended near the bottom of the stroke, the other knee bent at the top.
Red muscles: quads (quadriceps femoris), hamstrings (biceps femoris, semitendinosus and semimembranosus) and calves (gastrocnemius and soleus).
View: side view so the whole bike and the legs are visible.
```

### 1104 リカンベントバイク
```
Next image: Recumbent stationary bike.
Equipment: a recumbent bike: a low wide seat with a reclined backrest, pedals out in front at about seat height, side handles under the seat, and a console with a blank screen.
Position: sitting back in the seat, leaning against the backrest, legs reaching forward to the pedals, hands on the side handles.
Moment: pedaling: one leg almost straight forward, the other knee bent.
Red muscles: quads (quadriceps femoris), hamstrings (biceps femoris, semitendinosus and semimembranosus) and calves (gastrocnemius and soleus).
View: side view so the reclined seat and the pedals in front are visible.
```

### 1105 クロストレーナー
```
Next image: Elliptical cross trainer.
Equipment: an elliptical cross trainer: two large foot pedals that move in an oval path, two tall moving handlebars that swing back and forth, a flywheel housing, and a console with a blank screen.
Position: standing upright on the two pedals, holding the moving handlebars.
Moment: mid-stride: the right foot forward and the left foot back, the left handle pushed forward and the right handle pulled back; his feet stay on the pedals.
Red muscles: quads (quadriceps femoris), glutes (gluteus maximus) and hamstrings (biceps femoris, semitendinosus and semimembranosus). The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view, slightly from the front, so the whole machine and the legs are visible.
```

### 1106 ローイングマシン
```
Next image: Indoor rowing machine.
Equipment: an indoor rowing machine: a long low rail with a sliding seat, two foot plates with straps, a flywheel housing at the very front, and a handle on a chain coming out of the flywheel housing.
Position: sitting on the sliding seat, feet strapped onto the foot plates, holding the handle with both hands.
Moment: the finish of the stroke: legs straight, torso leaning slightly back, the handle pulled to the lower ribs, elbows behind the body.
Red muscles: quads (quadriceps femoris), lats (latissimus dorsi) and middle back (rhomboids).
View: three-quarter rear-side view so the back, the legs and the whole machine are visible.
```

### 1107 アサルトバイク
注記: 「アサルトバイク」は製品名に由来する呼び名なので、英文では一般名（air bike / fan bike）にする。
```
Next image: Air bike (fan bike).
Equipment: an air bike: a large fan wheel at the front inside a round black mesh cover, two long moving handlebars linked to the pedals, a saddle, and a console with a blank screen.
Position: sitting on the saddle, holding the moving handlebars.
Moment: pedaling hard while pushing the right handle forward and pulling the left handle back.
Red muscles: quads (quadriceps femoris), glutes (gluteus maximus) and shoulders (deltoids).
View: side view, slightly from the front, so the fan, the handlebars and the legs are visible.
```

### 1108 ステアクライマー
注記: 回る階段の型で描く（左右のペダルを踏む型なら Equipment の行を直す）。
```
Next image: Stair climber machine with revolving steps.
Equipment: a stair climber with a revolving staircase: a set of wide steps that keep moving downward like an escalator, two side handrails, and a console with a blank screen.
Position: standing upright on the steps, hands lightly on the handrails.
Moment: climbing: the right foot planted on a higher step with the knee bent, the left leg pushing off from a lower step.
Red muscles: glutes (gluteus maximus), quads (quadriceps femoris) and calves (gastrocnemius and soleus). The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view, slightly from behind, so the steps, the glutes and the legs are visible.
```

### 1109 ランニング（屋外）
```
Next image: Running outdoors, shown without any scenery.
Equipment: none. Do not draw a road, a track or any scenery: only the plain background.
Position: running forward.
Moment: mid-stride with both feet off the ground: the front knee raised, the rear leg extended behind, arms swinging with the elbows bent about 90 degrees.
Red muscles: quads (quadriceps femoris), hamstrings (biceps femoris, semitendinosus and semimembranosus) and calves (gastrocnemius and soleus).
View: side view so the whole running stride is visible.
```

### 1110 ウォーキング（屋外）
```
Next image: Brisk walking outdoors, shown without any scenery.
Equipment: none. Do not draw a road, a path or any scenery: only the plain background.
Position: walking forward with an upright posture.
Moment: a long walking step: the front heel touching the ground, the rear foot pushing off from the toes, arms swinging with the elbows slightly bent.
Red muscles: quads (quadriceps femoris), hamstrings (biceps femoris, semitendinosus and semimembranosus) and calves (gastrocnemius and soleus).
View: side view so the whole walking step is visible.
```

### 1111 サイクリング（屋外）
```
Next image: Road cycling, shown without any scenery.
Equipment: a road bicycle with a black frame, two wheels and drop handlebars. Do not draw a road or any scenery: the bike stands on the plain background.
Position: sitting on the saddle, leaning forward, hands on the handlebars.
Moment: pedaling: one leg extended near the bottom of the stroke, the other knee bent near the top.
Red muscles: glutes (gluteus maximus), quads (quadriceps femoris), hamstrings (biceps femoris, semitendinosus and semimembranosus) and calves (gastrocnemius and soleus). The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view so the whole bicycle and the legs are visible.
```

### 1112 水泳
注記: 泳ぎ方はクロールで描く。水と靴は描かない。
```
Next image: Front crawl swimming pose, without water.
Equipment: none. Do not draw water, a pool or splashes: he floats in the swimming pose in front of the plain background. Barefoot in this image only (no sneakers); black shorts as usual.
Position: horizontal, face down, body long and straight.
Moment: the right arm reaching far forward, the left arm recovering above the body with the elbow high, legs straight with a small flutter kick.
Red muscles: lats (latissimus dorsi), shoulders (deltoids) and triceps (triceps brachii).
View: low three-quarter side view, the camera at the height of his head, so the back and the shoulders are visible.
```

### 1113 縄跳び
```
Next image: Jump rope.
Equipment: a black jump rope with two handles.
Position: standing upright, elbows close to his sides, hands at hip height turning the rope with the wrists.
Moment: a small hop on the balls of his feet, both feet just off the floor, the rope passing under his feet.
Red muscles: calves (gastrocnemius and soleus) and quads (quadriceps femoris).
View: three-quarter front view so the whole rope and the calves are visible.
```

## 全身

### 1201 パワークリーン
注記: 床から引き上げて爆発的に伸び上がる瞬間で描く（肩で受ける瞬間は 702 フロントスクワットと見分けにくいため）。
```
Next image: Barbell power clean.
Equipment: a straight barbell loaded with large black plates.
Position: overhand grip about shoulder width, feet hip-width apart.
Moment: the explosive second pull: he has pulled the bar from the floor and is fully extending, up on the balls of his feet, knees and hips straight, shoulders shrugged up, elbows starting to bend and lift out to the sides; the bar is at belly height, close to the body, moving up.
Red muscles: glutes (gluteus maximus), hamstrings (biceps femoris, semitendinosus and semimembranosus) and upper traps (upper trapezius). The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: three-quarter rear-side view so the glutes, the hamstrings and the traps are visible.
```

### 1202 クリーン&ジャーク
注記: 2 つの動作（クリーン → ジャーク）がある。1201・1203 と見分けるため、ジャークで頭上に差し上げた瞬間で描く。
```
Next image: Clean and jerk, the split jerk.
Equipment: a straight barbell loaded with large black plates.
Position: overhand grip about shoulder width.
Moment: the catch of a split jerk: the bar locked out overhead on straight arms, the feet split far apart front and back (right foot forward, left foot back on the toes), both knees slightly bent, torso upright.
Red muscles: shoulders (deltoids), triceps (triceps brachii) and quads (quadriceps femoris).
View: side view, slightly from the front, so the split feet and the bar overhead are visible.
```

### 1203 スナッチ
注記: 頭上で受けてしゃがんだ瞬間で描く（幅の広い握りが 1202 との見分けどころ）。
```
Next image: Barbell snatch, the catch.
Equipment: a straight barbell loaded with large black plates.
Position: a very wide overhand grip, hands far wider than the shoulders.
Moment: the catch in a deep overhead squat: the bar locked out overhead on straight arms, hips below the knees, torso upright, feet flat and a little wider than the shoulders.
Red muscles: quads (quadriceps femoris), glutes (gluteus maximus) and shoulders (deltoids).
View: three-quarter front-side view so the wide grip and the deep squat are visible.
```

### 1204 スラスター
```
Next image: Barbell thruster.
Equipment: a straight barbell loaded with black plates.
Position: the bar starts on the front of his shoulders, feet about shoulder width and side by side (not split).
Moment: driving up out of the bottom of a front squat and pressing the bar overhead in one movement: the legs almost straight, the bar leaving the shoulders at forehead height, the elbows extending. The bar is NOT locked out overhead yet: the elbows are still clearly bent. Only the quads, the glutes and the shoulders are red; the calves stay grey.
Red muscles: quads (quadriceps femoris), glutes (gluteus maximus) and shoulders (deltoids).
View: three-quarter front-side view so the legs and the rising bar are visible.
```

### 1205 ケトルベルスイング
```
Next image: Two-handed kettlebell swing.
Equipment: one black kettlebell held by its handle with both hands.
Position: feet wider than the shoulders.
Moment: the top of the swing: standing tall with the hips fully extended, arms straight, the kettlebell floating at chest height in front of him.
Red muscles: glutes (gluteus maximus) and hamstrings (biceps femoris, semitendinosus and semimembranosus). The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view, slightly from behind, so the glutes and the hamstrings are visible.
```

### 1206 ターキッシュゲットアップ
注記: 何段階もある動作。見分けやすい途中の段階（片手を床につき、腰を浮かせ、反対の腕でケトルベルを真上に支える）で描く。
```
Next image: Kettlebell Turkish get-up, high bridge stage.
Equipment: one black kettlebell.
Position: he started lying on his back and is getting up while holding the kettlebell straight above him the whole time.
Moment: the high bridge stage: the left hand on the floor, the left leg straight on the floor, the right knee bent with the right foot planted, hips lifted high, the right arm locked straight up holding the kettlebell above the shoulder, eyes looking up at the kettlebell.
Red muscles: shoulders (deltoids), abs and obliques (rectus abdominis, external and internal obliques) and glutes (gluteus maximus).
View: three-quarter front view so the raised arm, the bridge and the kettlebell are visible.
```

### 1207 バーピー
注記: 何段階もある動作。最後に頭上へ跳ぶ瞬間で描く（714 ジャンピングスクワットとは、腕を頭上に伸ばす点で分ける）。
```
Next image: Burpee, the final jump.
Equipment: none.
Position: he has just come up from a push-up plank and a squat.
Moment: jumping straight up at the end of the rep: both feet off the floor, body straight, arms stretched straight up overhead with the hands clapping above his head.
Red muscles: quads (quadriceps femoris), chest (pectoralis major) and shoulders (deltoids).
View: three-quarter front view so the thighs, the chest and the raised arms are visible.
```

### 1208 ボックスジャンプ
```
Next image: Box jump.
Equipment: a sturdy black plyo box about thigh height.
Position: he has jumped from the floor in front of the box.
Moment: landing softly on top of the box: both feet flat on the box, knees and hips bent in a half squat, arms swung forward.
Red muscles: quads (quadriceps femoris), glutes (gluteus maximus) and calves (gastrocnemius and soleus). The glutes are under his black shorts: he keeps the shorts on, fully covering his buttocks (do not cut away, lift, roll up or shorten the shorts), and the shape of the glute muscles is painted in bright red directly on top of the black shorts, as if the red muscles show through the fabric: a clearly shaped glute muscle with fine fibre lines, like the other red muscles, never a soft glow or a blurry red spot.
View: side view so the whole box and his body are visible.
```

### 1209 バトルロープ
```
Next image: Battle rope alternating waves.
Equipment: one long, thick black rope looped around a black anchor post on the floor several steps in front of him; he holds one end of the rope in each hand.
Position: an athletic half-squat stance, feet about shoulder width, torso upright and leaning slightly forward.
Moment: making alternating waves: the right hand up at shoulder height and the left hand down at hip height, waves traveling along both halves of the rope. (In this exercise the arms alternate on purpose.)
Red muscles: shoulders (deltoids), arms (biceps brachii and triceps brachii) and abs (rectus abdominis).
View: three-quarter front-side view, with the whole length of the rope and the anchor visible.
```

## 確かめ方

1 枚できるごとに、次の 5 点を見る。

- 器具の形: Equipment の行のとおりか（ベンチの角度、スミスマシンの縦のレール、パッドやローラーが体のどこに当たるか、グリップの向き、ケーブルのプーリーの高さ）
- 赤い筋肉の場所: Red muscles に書いた筋肉だけが赤いか（ほかが赤くなっていないか、左右・表と裏を取り違えていないか）
- 画風: 試作と同じ人物（顔の年かっこう・髪型）・灰色の肌・黒の短パン・灰色の靴・黒い器具・無地の薄い灰色の背景か。全身と器具が切れていないか。文字やロゴが入っていないか
- 体のつながり（2026-10-16 追記）: 腕と脚が 2 本ずつで、肩と股関節の正しい位置から出ているか。器具を持つ手がどの腕につながっているか。小さな一覧では見落とすので、元の大きさで見る（206 で、ダンベルを持つ腕が背中の途中から出た絵を見落とした）
- 髪（2026-10-17 追記）: 頭を拡大して見る。編み込み・縄を編んだような束・お団子・つむじの渦・巻き毛が少しでも出ていたら送り直す（10/16、AI は生成中に「髪の上にやや質感」と気づきながら小さなずれとして採用し、本人に「気持ち悪い」と言われて 30 枚を作り直すことになった）

出来が悪いときは、同じ会話で、そのプロンプトの末尾に直してほしい点を英語で足して送り直す。例:

```
Fix: the thigh rollers must press down on the tops of his thighs, not beside his hips.
```

```
Fix: only the chest is red; the shoulders and the arms must stay light grey.
```

髪を直すとき（2026-10-17 追記）。「Fix:」だけだと前の画像を上げ直すよう求められて失敗することがあるので、新しい画像として頼む:

```
Please make a new image (do not edit an earlier one). Same exercise as the last one, with one fix: his hair. Draw it exactly like the smooth, sleek hair in the standing press and lateral raise references: a short, neat taper haircut, the sides and the back clipped very short and close to the head, and the short top (about 3 cm) combed straight back, smooth and flat, with only fine, thin strand lines. No thick clumps or scale-like layers, no braids, no rope-like twisted locks, no curls, no bun and no swirl at the crown, also on the back of his head. Keep everything else the same.
```

何度か直しても画風がずれたままなら、新しい会話に切り替えて「最初に送る文」の「新しい会話で始めるとき」からやり直す。
