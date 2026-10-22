"""pg_dump --schema-only の出力を、順序に依らない形にそろえる (戻しの SQL の確かめ用。run.sh --rollback が使う)。

戻しで足し直した列は表の末尾に付き (user_profile.id・exercise.note・exercise.is_archived)、権限の並びも変わりうる。
意味の同じ形かを見たいので、文を単位に並べ替え、CREATE TABLE の中の行も並べ替える。コメントと空行は捨てる。
使い方: python3 -I normalize_schema.py < dump.sql > normalized.txt
"""
import sys


def main() -> None:
    # \restrict・\unrestrict は pg_dump が毎回変える乱数の鍵 (17.6 以降)。形ではないので捨てる
    lines = [l for l in sys.stdin.read().splitlines()
             if l.strip() and not l.startswith("--") and not l.startswith(("\\restrict ", "\\unrestrict "))]
    statements, current = [], []
    for line in lines:
        current.append(line)
        if line.rstrip().endswith(";") and not _inside_body(current):
            statements.append(current)
            current = []
    if current:
        statements.append(current)
    out = []
    for st in statements:
        if st[0].startswith("CREATE TABLE ") and st[-1].strip() == ");":
            inner = sorted(l.strip().rstrip(",") for l in st[1:-1])
            out.append("\n".join([st[0], *("    " + l for l in inner), ");"]))
        else:
            out.append("\n".join(st))
    print("\n\n".join(sorted(out)))


def _inside_body(stmt: list[str]) -> bool:
    """関数の本文 ($...$) の途中なら True (本文の中の ; で文を切らない)"""
    text = "\n".join(stmt)
    for tag in ("$function$", "$$", "$_$"):
        if text.count(tag) % 2 == 1:
            return True
    return False


if __name__ == "__main__":
    main()
