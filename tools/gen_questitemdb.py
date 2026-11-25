from questitemdb_decode import *
import collections
Q, I = 'Quest-', 'Item-'
def norm(v):
    """CBOR from Lua tables: list => 1-based, dict keeps int keys. returns dict {luaIndex: value} or scalar"""
    if isinstance(v, list): return {i+1: x for i, x in enumerate(v)}
    if isinstance(v, dict): return {(k.decode() if isinstance(k, bytes) else k): x for k, x in v.items()}
    return v
def arr(v):
    v = norm(v)
    if not isinstance(v, dict): return []
    return [v[k] for k in sorted(k for k in v if isinstance(k, int))]
def s(v): return v.decode('utf-8', 'replace') if isinstance(v, bytes) else v
qids, iids = ids(Q), ids(I)
quests = {}
for q in qids:
    r = norm(row(Q, q) or {})
    def F(f):
        if f in r and not isinstance(r[f], (dict, list)): return r[f]
        return field(Q, q, f)
    quests[q] = r, F
items = {}
for i in iids:
    r = norm(row(I, i) or {})
    items[i] = r
print('quests', len(quests), 'items', len(items))
roles = collections.defaultdict(dict)   # item -> {quest: roleletters}
def add(item, q, role):
    if not isinstance(item, int) or item <= 0: return
    d = roles[item]; d[q] = ''.join(sorted(set(d.get(q, '') + role)))
qinfo = {}
for q, (r, F) in quests.items():
    obj = norm(F(10)) if F(10) else {}
    for e in arr(obj.get(3)): add(arr(e)[0] if arr(e) else None, q, 'o')
    for e in arr(obj.get(6)):            # spell objectives {spell,text,item}
        a = arr(e)
        if len(a) >= 3: add(a[2], q, 'o')
    src = F(11)
    if isinstance(src, int): add(src, q, 's')
    for x in arr(F(21)): add(x, q, 'r')
    st = norm(F(2)) if F(2) else {}
    for x in arr(st.get(3)): add(x, q, 't')
for i, r in items.items():
    sq = r.get(5)
    if isinstance(sq, int) and sq > 0: add(i, sq, 't')
# rewards only for Quest-class items (keys, letters ... used later); hint only
for i, r in items.items():
    if r.get(12) == 12:
        rw = field(I, i, 6) if 6 not in r else r[6]
        for q in arr(rw): add(i, q, 'w')
roles = {i: d for i, d in roles.items() if d and any(q in quests for q in d)}
# quest graph
def qf(q):
    r, F = quests[q]
    return r, F
nxt, pre_single, pre_group = {}, {}, {}
for q, (r, F) in quests.items():
    n = F(22)
    if isinstance(n, int) and n > 0 and n in quests: nxt[q] = n
    pre_single[q] = [x for x in arr(F(13)) if isinstance(x, int)]
    pre_group[q] = [x for x in arr(F(12)) if isinstance(x, int)]
followers = collections.defaultdict(set)
for q in quests:
    if q in nxt: followers[q].add(nxt[q])
    ps = pre_single[q]
    if len(ps) == 1 and ps[0] in quests: followers[ps[0]].add(q)
    for p in pre_group[q]:
        if p in quests and len(pre_group[q]) <= 3: followers[p].add(q)
for q in list(followers):
    b = quests[q][1](27)
# breadcrumbs are optional: do not treat a breadcrumb as a follower
bc = {q: quests[q][1](27) for q in quests}
for q in followers:
    followers[q] = {f for f in followers[q] if not (isinstance(bc.get(f), int) and bc[f] > 0)}
need = set()
for d in roles.values(): need |= set(d)
stack = list(need)
while stack:
    q = stack.pop()
    for f in followers.get(q, ()):
        if f not in need: need.add(f); stack.append(f)
need = {q for q in need if q in quests}
def lua_str(v):
    return '"' + v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ') + '"'
def num(v): return str(int(v)) if isinstance(v, (int, float)) else 'nil'
out = []
out.append('-- AltStash QuestItemDB: item -> quest lookup with quest chain data. GENERATED, do not edit by hand.')
out.append('-- Source: QuestieDB %s (Forever flavor, baked data, build commit %s), https://github.com/Questie/QuestieDB' % ('1.1.6', meta.get('X-BUILD-COMMIT')))
out.append('-- Data license: see README (QuestieDB / Questie data, copied under the GPLv3 terms the Questie team allows).')
out.append('-- I[itemID] = "questID:roles,..." roles: o objective, s provided at accept (sourceItem), r required source item,')
out.append('--            t starts the quest, w quest reward (hint only).')
out.append('-- Q[questID] = { name, next, races, classes, flags, pre, preGroup, exclusiveTo, followers, breadcrumbFor }')
out.append('--   flags: 1 repeatable. pre/preGroup/exclusiveTo/followers are id lists or nil.')
out.append('local ADDON, AS = ...')
out.append('AS = AS or {}')
out.append('local D = { source = "QuestieDB 1.1.6 (Forever)", commit = %s, built = %s }' % (lua_str(meta.get('X-BUILD-COMMIT','?')), lua_str('2026-11-25')))
out.append('local I = {')
for i in sorted(roles):
    parts = ','.join('%d:%s' % (q, roles[i][q]) for q in sorted(roles[i]))
    out.append('[%d]="%s",' % (i, parts))
out.append('}')
out.append('local Q = {')
def lst(v): 
    v = [x for x in v if isinstance(x, int)]
    return '{' + ','.join(str(x) for x in v) + '}' if v else 'nil'
for q in sorted(need):
    r, F = quests[q]
    name = s(F(1)) or ''
    races, classes = F(6), F(7)
    sf = F(24)
    flags = 1 if isinstance(sf, int) and (sf & 1) else 0
    excl = [x for x in arr(F(16)) if isinstance(x, int)]
    fol = sorted(f for f in followers.get(q, ()) if f in need)
    b = bc.get(q) if isinstance(bc.get(q), int) and bc.get(q) > 0 else None
    out.append('[%d]={%s,%s,%s,%s,%s,%s,%s,%s,%s,%s},' % (q, lua_str(name), num(nxt.get(q)), num(races) if races else 'nil', num(classes) if classes else 'nil',
        str(flags) if flags else 'nil', lst(pre_single[q]), lst(pre_group[q]), lst(excl), lst(fol), num(b)))
out.append('}')
out.append('D.I, D.Q = I, Q')
out.append('AS.QuestItemDB = D')
open('/workspace/AltStash/QuestItemDB.lua', 'w', encoding='utf-8').write('\n'.join(out) + '\n')
nclass12 = sum(1 for i in roles if items.get(i, {}).get(12) == 12)
print('items', len(roles), 'quest-class', nclass12, 'quests', len(need))
for i in [8051, 8066, 8072, 8073, 8074, 8087, 7209, 7295, 5060, 7231, 7294, 7306, 7309, 7970, 7968]:
    print(i, s(items.get(i, {}).get(1)), 'class', items.get(i, {}).get(12), roles.get(i))
