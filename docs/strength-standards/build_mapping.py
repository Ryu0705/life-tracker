"""種目名 → 基準の対応表 (LifeTracker/LifeTracker/Resources/strength_mapping.json) を作る。

入力: mapping-draft.csv (10/6 の調査・10/7〜10/8 の修正) と、換算の下書き (derived-standards-draft.md) を
本人確認 (2026-10-10) で確定した内容 (下の DERIVED / APPROX_RULES / EXCLUDED)。
実行: python3 -I docs/strength-standards/build_mapping.py (repo のルートで)。生成物を手で直さない
"""
import csv, json, sys, os

ROOT = os.getcwd()
CSV = os.path.join(ROOT, 'docs/strength-standards/mapping-draft.csv')
STD = os.path.join(ROOT, 'LifeTracker/LifeTracker/Resources/strength_level_standards.json')
OUT = os.path.join(ROOT, 'LifeTracker/LifeTracker/Resources/strength_mapping.json')

# 静止系 3 件: plank の表 × Endura の比 (段ごと [Beg, Nov, Int, Adv, Elite]。Beginner は Novice の比)
def endura(x, plank):
    r = [round(a / b, 3) for a, b in zip(x, plank)]
    return [r[0]] + r
ENDURA_PLANK = {'male': [60, 120, 180, 300], 'female': [45, 90, 140, 220]}
ENDURA = {
    'デッドハング': {'male': [30, 60, 120, 180], 'female': [20, 45, 90, 150]},
    'ウォールシット': {'male': [45, 90, 150, 240], 'female': [40, 80, 130, 210]},
    'ホローホールド': {'male': [30, 60, 95, 140], 'female': [25, 50, 80, 120]},
}
def static_hold(name):
    return {'slug': 'plank', 'multiplier': {'by_sex': {s: endura(ENDURA[name][s], ENDURA_PLANK[s]) for s in ('male', 'female')}},
            'label': '換算（plank の表 × Endura の比）'}

DERIVED = {
    'アシストチンニング（マシン）': {'slug': 'pull-ups', 'transform': 'assist_to_added', 'label': '換算（pull-ups の加重の表・アシストはマイナス）'},
    'デッドハング': static_hold('デッドハング'),
    'ステップアップ': {'slug': 'dumbbell-lunge', 'label': '換算（dumbbell-lunge の表）'},
    'ウォールシット': static_hold('ウォールシット'),
    'Vシット': {'slug': 'lying-leg-raise', 'label': '換算（lying-leg-raise の表）'},
    'デッドバグ': {'slug': 'bicycle-crunch', 'label': '換算（bicycle-crunch の表）'},
    'バードドッグ': {'slug': 'back-extension', 'label': '換算（back-extension の表）'},
    'ホローホールド': static_hold('ホローホールド'),
    'トーソローテーション（マシン）': {'slug': 'machine-seated-crunch', 'label': '換算（machine-seated-crunch の表）'},
    'ケトルベルスイング': {'slug': 'dumbbell-romanian-deadlift', 'label': '換算（dumbbell-romanian-deadlift の表）'},
    'ターキッシュゲットアップ': {'slug': 'dumbbell-shoulder-press', 'label': '換算（dumbbell-shoulder-press の表）'},
    'ボックスジャンプ': {'slug': 'squat-jump', 'label': '換算（squat-jump の表）'},
    'バックキック（マシン）': {'slug': 'cable-kickback', 'label': '換算（cable-kickback の表）'},
    'ロシアンツイスト': {'slug': 'russian-twist', 'transform': 'weighted_reps_equivalent', 'label': '換算（russian-twist の回数の表・加重は相当回数に）'},
}
APPROX_RULES = {
    'インクラインチェストプレス（マシン）': {'multiplier': {'ratio_of': ['incline-bench-press', 'bench-press']},
                                      'label': '近似（chest-press × incline-bench-press/bench-press の比）'},
    'ケーブルフロントレイズ': {'multiplier': {'ratio_of': ['cable-lateral-raise', 'dumbbell-lateral-raise']},
                         'label': '近似（dumbbell-front-raise × cable/dumbbell のレイズの比）'},
    'ウォーキングランジ': {'slug': 'dumbbell-lunge', 'label': '近似（dumbbell-lunge で代用）'},
}
# 本人 2026-10-10: 強さの対象外 (換算しない・部位の平均に入れない)
EXCLUDED = {'ハンドグリップ', 'バンドプルアパート', 'マウンテンクライマー', 'バトルロープ'}
# 自重の weight_reps (加重 0 → 回数の表、加重あり → 加重の表)
BODYWEIGHT_ADDED = {'ディップス（胸）', 'チンニング（順手懸垂）', 'チンアップ（逆手懸垂）', 'ディップス（三頭）'}

std = json.load(open(STD))['exercises']
rows = list(csv.DictReader(open(CSV)))
out = []
for r in rows:
    name, kind = r['name'], r['metric_kind']
    e = {'name': name, 'muscle_group': r['muscle_group'], 'metric_kind': kind}
    if r['muscle_group'] == 'cardio' or name in EXCLUDED:
        e['match'] = 'excluded'
    elif name in DERIVED:
        e.update({'match': 'derived', **DERIVED[name]})
    elif r['sl_match'] in ('exact', 'approx'):
        e.update({'match': r['sl_match'], 'slug': r['strengthlevel_slug']})
        if r['sl_match'] == 'approx':
            e['label'] = f"近似（{r['strengthlevel_slug']} で代用）"
            e.update(APPROX_RULES.get(name, {}))
        if name in BODYWEIGHT_ADDED:
            e['transform'] = 'bodyweight_added'
    else:
        sys.exit(f'unmapped: {name}')
    out.append(e)

# 検証: slug・比の slug が基準にある / 単位が metric_kind と合う
UNIT = {'weight_reps': 'kg', 'reps_only': 'reps', 'duration': 'seconds'}
TRANSFORM_UNIT = {'bodyweight_added': 'reps', 'assist_to_added': 'reps', 'weighted_reps_equivalent': 'reps'}
errors = []
for e in out:
    if e['match'] == 'excluded':
        continue
    slug = e['slug']
    if slug not in std:
        errors.append(f"{e['name']}: no slug {slug}")
        continue
    want = TRANSFORM_UNIT.get(e.get('transform'), UNIT[e['metric_kind']])
    if std[slug]['unit'] != want:
        errors.append(f"{e['name']}: unit {std[slug]['unit']} != {want}")
    if e.get('transform') in ('bodyweight_added', 'assist_to_added') and 'added_weight_kg' not in std[slug]:
        errors.append(f"{e['name']}: no added_weight_kg in {slug}")
    for s in e.get('multiplier', {}).get('ratio_of', []):
        if s not in std:
            errors.append(f"{e['name']}: no ratio slug {s}")
if errors:
    sys.exit('\n'.join(errors))

doc = {'note': '生成物 (docs/strength-standards/build_mapping.py)。手で直さない。個人用アプリの中だけで使い、公開・再配布しない',
       'exercises': out}
with open(OUT, 'w') as f:
    json.dump(doc, f, ensure_ascii=False, indent=1)
from collections import Counter
print(len(out), Counter(e['match'] for e in out))
