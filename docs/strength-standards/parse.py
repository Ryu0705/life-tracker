import re,json,html,datetime,collections
P='pages/'
slugs=open('slugs.txt').read().split()
def cells(tab):
    return [html.unescape(' '.join(re.sub(r'<[^>]+>',' ',c).split())) for c in re.findall(r'<t[hd][^>]*>(.*?)</t[hd]>',tab,re.S)]
def conv(v,unit):
    raw=v
    if unit=='kg': v=re.sub(r'\s*kg$','',v); v=re.sub(r'^\+','',v)
    if unit=='seconds': v=re.sub(r'\s*s$','',v)
    if re.fullmatch(r'-?\d+(\.\d+)?',v): return float(v) if '.' in v else int(v)
    return raw
out={"source":"strengthlevel.com","fetched_at":datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).isoformat(timespec='seconds'),"levels":["beginner","novice","intermediate","advanced","elite"],"exercises":{},"failed":[]}
odd=collections.Counter()
for s in slugs:
    h=open(P+s+'.html').read()
    tabs=[cells(t) for t in re.findall(r'<table[^>]*>(.*?)</table>',h,re.S)]
    summ=[t for t in tabs if t[:1]==['Strength Level'] and t[1]!='Bodyweight Ratio']
    bw=[t for t in tabs if t[:6]==['BW','Beg.','Nov.','Int.','Adv.','Elite']]
    ag=[t for t in tabs if t[:6]==['Age','Beg.','Nov.','Int.','Adv.','Elite']]
    dual = len(bw)==4 and len(ag)==4
    if not dual and (len(bw)!=2 or len(summ)<2):
        out['failed'].append({"slug":s,"reason":f"table shape unexpected: bw={len(bw)} summary={len(summ)} title={re.search(r'<title>(.*?)</title>',h).group(1)}"});continue
    hdr=summ[0][1]; unit={'Weight':'kg','Reps':'reps','Time':'seconds'}.get(hdr,hdr)
    notes=[]
    if summ[1][1]!=hdr: notes.append(f"female summary header {summ[1][1]}")
    e={"unit":unit}
    def build(bwt,agt,u):
        d={}
        for key,t in (('bodyweight',bwt),('age',agt)):
            if t is None: continue
            body=t[6:]; rows=[]
            for j in range(0,len(body)-len(body)%6,6):
                r=body[j:j+6]; vals=[conv(x,u) for x in r[1:]]
                for x in vals:
                    if isinstance(x,str): odd[x]+=1
                rows.append({"bw" if key=='bodyweight' else "age":conv(r[0],'kg'),"values":vals})
            d[key]=rows
        return d
    if dual:
        # page order per sex: reps-BW, reps-Age, weighted-BW, weighted-Age
        e['male']=build(bw[0],ag[0],'reps'); e['female']=build(bw[2],ag[2],'reps')
        e['added_weight_kg']={'male':build(bw[1],ag[1],'kg'),'female':build(bw[3],ag[3],'kg')}
        notes.append("page also has '1RM Weight' tables (added weight via belt, negative = assistance); stored in added_weight_kg with '+'/' kg' removed, sign kept")
    for i,sex in enumerate([] if dual else ['male','female']):
        d={}
        for key,t in (('bodyweight',bw[i]),('age',ag[i] if len(ag)>i else None)):
            if t is None: continue
            body=t[6:]; rows=[]
            for j in range(0,len(body)-len(body)%6,6):
                r=body[j:j+6]; vals=[conv(x,unit) for x in r[1:]]
                for x in vals:
                    if isinstance(x,str): odd[x]+=1
                rows.append({"bw" if key=='bodyweight' else "age":conv(r[0],'kg'),"values":vals})
            if len(body)%6: notes.append(f"{sex} {key} trailing cells")
            d[key]=rows
        e[sex]=d
    if any(isinstance(x,str) for sx in ('male','female') for k in e[sx] for r in e[sx][k] for x in r['values']):
        notes.append("non-numeric cells (e.g. '< 1') kept as page text")
    if unit=='seconds': notes.append("page cells shown as 'N s'; suffix removed")
    e["note"]="; ".join(notes)
    out['exercises'][s]=e
json.dump(out,open('strength_level_standards.json','w'),ensure_ascii=False,indent=1)
print(len(out['exercises']),'ok',len(out['failed']),'failed',out['failed'])
print(collections.Counter(e['unit'] for e in out['exercises'].values()))
print(odd)
print({k:e['note'] for k,e in out['exercises'].items() if e['note'] and 'non-numeric' not in e['note'] and e['unit']!='seconds'})
