#!/usr/bin/env python3
"""js-rich-body-highlighter (MIT) の部位マスクを Swift の定数に変換する (F-3・2026-10-13)。

使い方: python3 -I build_body_paths.py <取得した repo のディレクトリ> <出力 .swift>
- 入力: src/data/muscles/front.ts・back.ts (1 行 1 フィールドの TS。実行はせず文字列として読む)
- 出力: 絶対座標 (viewBox 361.15625×541.86667 の単位、offset 適用済み) の M/L/C/Q/Z だけの文字列。
  H/V → L、S → C、T → Q に直す。A (円弧) は出てきたら止める
- 生成物は手で直さない。素材を取り直したらこのスクリプトを流し直す
"""
import re
import sys

PX2MM = 25.4 / 96
FIELD = re.compile(r"^\s*(id|group|gender|view|d):\s*'([^']*)',?\s*$")
OFFSET = re.compile(r"^\s*offset:\s*\{\s*x:\s*(-?[\d.]+),\s*y:\s*(-?[\d.]+)\s*\},?\s*$")
TOKEN = re.compile(r"[MmLlHhVvCcSsQqTtZzAa]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def entries(path):
    out, cur = [], None
    for line in open(path, encoding="utf-8"):
        if line.strip() == "{":
            cur = {"offset": (0.0, 0.0)}
        elif line.strip().startswith("}") and cur is not None:
            out.append(cur)
            cur = None
        elif cur is not None:
            m = FIELD.match(line)
            if m:
                cur[m.group(1)] = m.group(2)
            m = OFFSET.match(line)
            if m:
                cur["offset"] = (float(m.group(1)) * PX2MM, float(m.group(2)) * PX2MM)
    return out


def absolute(d, ox, oy):
    toks = TOKEN.findall(d)
    i, cmd = 0, None
    x = y = sx = sy = 0.0
    last_c = last_q = None  # 反射用の直前の制御点
    parts = []

    def num():
        nonlocal i
        v = float(toks[i]); i += 1
        return v

    def p(a, b):
        return f"{a + ox:.2f} {b + oy:.2f}"

    while i < len(toks):
        if re.fullmatch(r"[A-Za-z]", toks[i]):
            cmd = toks[i]; i += 1
            if cmd in "Zz":
                parts.append("Z"); x, y = sx, sy; last_c = last_q = None
                continue
        elif cmd is None:
            raise ValueError("先頭が数値")
        rel = cmd.islower()
        c = cmd.upper()
        bx, by = (x, y) if rel else (0.0, 0.0)
        if c == "A":
            raise ValueError("円弧は未対応")
        if c == "M":
            x, y = bx + num(), by + num(); sx, sy = x, y
            parts.append("M " + p(x, y)); last_c = last_q = None
            cmd = "l" if rel else "L"  # M の後に続く座標は L
        elif c == "L":
            x, y = bx + num(), by + num(); parts.append("L " + p(x, y)); last_c = last_q = None
        elif c == "H":
            x = bx + num(); parts.append("L " + p(x, y)); last_c = last_q = None
        elif c == "V":
            y = (y if rel else 0.0) + num(); parts.append("L " + p(x, y)); last_c = last_q = None
        elif c in "CS":
            if c == "C":
                x1, y1 = bx + num(), by + num()
            else:
                x1, y1 = (2 * x - last_c[0], 2 * y - last_c[1]) if last_c else (x, y)
            x2, y2 = bx + num(), by + num()
            x, y = bx + num(), by + num()
            parts.append(f"C {p(x1, y1)} {p(x2, y2)} {p(x, y)}"); last_c = (x2, y2); last_q = None
        elif c in "QT":
            if c == "Q":
                x1, y1 = bx + num(), by + num()
            else:
                x1, y1 = (2 * x - last_q[0], 2 * y - last_q[1]) if last_q else (x, y)
            x, y = bx + num(), by + num()
            parts.append(f"Q {p(x1, y1)} {p(x, y)}"); last_q = (x1, y1); last_c = None
    return " ".join(parts)


def main(src, dst):
    rows = []
    for view in ("front", "back"):
        for e in entries(f"{src}/src/data/muscles/{view}.ts"):
            assert e.get("view") == view, e.get("id")
            rows.append((e["id"], e["group"], e["gender"], view, absolute(e["d"], *e["offset"])))
    with open(dst, "w", encoding="utf-8") as f:
        f.write("// 生成物: docs/body-diagram/build_body_paths.py (手で直さない)\n")
        f.write("// 出典: js-rich-body-highlighter (MIT) src/data/muscles/*.ts。LICENSE は docs/body-diagram/\n\n")
        f.write("enum BodyDiagramPaths {\n")
        f.write("    struct Mask {\n        let id: String\n        let group: String\n        let female: Bool\n        let front: Bool\n        let d: String\n    }\n\n")
        f.write("    static let viewBox = (width: 361.15625, height: 541.86667)\n\n")
        f.write("    static let masks: [Mask] = [\n")
        for id_, group, gender, view, d in rows:
            f.write(f'        Mask(id: "{id_}", group: "{group}", female: {str(gender == "female").lower()}, front: {str(view == "front").lower()},\n')
            f.write(f'             d: "{d}"),\n')
        f.write("    ]\n}\n")
    print(f"{len(rows)} masks -> {dst}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
