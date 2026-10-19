#!/usr/bin/env python3
"""本人が ChatGPT で作った種目の画像を、アプリのアセットと Swift の対応表にする (2026-10-15)。

使い方: python3 -I docs/exercise-images/build_assets.py <画像のフォルダ>   (repo のどこから流してもよい)
- 入力: <画像のフォルダ>/<sort_order>.png (jpg も可)。番号は 0004 の seed の sort_order。seed に無い番号は警告して飛ばす
- 出力: LifeTracker/LifeTracker/Assets.xcassets/Exercises/Exercise<番号>.imageset (840px 四方の JPEG・品質 85) と
  LifeTracker/LifeTracker/Sources/Views/Workout/ExerciseImageNames.swift (種目名 → アセット名。画像がある種目だけ)
- Exercises フォルダは毎回作り直す。生成物は手で直さない。画像を足したり差し替えたりしたら流し直す
"""
import json
import re
import shutil
import sys
from pathlib import Path

from PIL import Image

SIZE = 840
QUALITY = 85
REPO = Path(__file__).resolve().parents[2]
SEED = REPO / "supabase/migrations/0004_exercise_seed.sql"
ASSETS = REPO / "LifeTracker/LifeTracker/Assets.xcassets/Exercises"
SWIFT = REPO / "LifeTracker/LifeTracker/Sources/Views/Workout/ExerciseImageNames.swift"
ROW = re.compile(r"^\('([^']+)',\s*'[a-z_]+',\s*'[a-z]+',\s*'[a-z_]+',\s*(\d+)\)", re.M)
INFO = {"info": {"author": "xcode", "version": 1}}


def main(src):
    names = {int(order): name for name, order in ROW.findall(SEED.read_text(encoding="utf-8"))}
    assert len(names) == 159, len(names)
    files = {}
    for path in sorted(Path(src).expanduser().iterdir()):
        if path.suffix.lower() not in (".png", ".jpg", ".jpeg"):
            continue
        if not path.stem.isdigit() or int(path.stem) not in names:
            print(f"警告: seed に無い番号なので飛ばす: {path.name}")
            continue
        if int(path.stem) in files:
            print(f"警告: 同じ番号が 2 つある。先の {files[int(path.stem)].name} を使う: {path.name}")
            continue
        files[int(path.stem)] = path

    if ASSETS.exists():
        shutil.rmtree(ASSETS)
    ASSETS.mkdir(parents=True)
    (ASSETS / "Contents.json").write_text(json.dumps(INFO, indent=2) + "\n", encoding="utf-8")
    total = 0
    for order, path in sorted(files.items()):
        image = Image.open(path).convert("RGB")
        w, h = image.size
        if w != h:
            print(f"警告: 正方形でないので中央を切り出す: {path.name} {w}x{h}")
            side = min(w, h)
            image = image.crop(((w - side) // 2, (h - side) // 2, (w + side) // 2, (h + side) // 2))
        name = f"Exercise{order}"
        folder = ASSETS / f"{name}.imageset"
        folder.mkdir()
        out = folder / f"{name}.jpg"
        image.resize((SIZE, SIZE), Image.LANCZOS).save(out, "JPEG", quality=QUALITY, optimize=True)
        contents = {"images": [{"filename": out.name, "idiom": "universal"}], **INFO}
        (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
        total += out.stat().st_size

    with open(SWIFT, "w", encoding="utf-8") as f:
        f.write("// 生成物: docs/exercise-images/build_assets.py (手で直さない)\n")
        f.write("// 画像は本人が ChatGPT で生成 (docs/exercise-images/SOURCE.md)。番号は 0004 の seed の sort_order\n\n")
        f.write("enum ExerciseImageNames {\n")
        f.write("    /// 種目名 → アセット名。画像がある種目だけ\n")
        f.write("    static let byName: [String: String] = [\n")
        for order in sorted(files):
            f.write(f'        "{names[order]}": "Exercise{order}",\n')
        f.write("    ]\n}\n")

    missing = sorted(set(names) - set(files))
    average = total / len(files) if files else 0
    print(f"{len(files)} 枚 -> {ASSETS.relative_to(REPO)} (合計 {total / 1e6:.2f}MB・1 枚 {average / 1e3:.0f}KB・159 枚なら約 {average * 159 / 1e6:.1f}MB)")
    print(f"画像の無い種目: {len(missing)}")


if __name__ == "__main__":
    main(sys.argv[1])
