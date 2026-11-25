import base64, zlib, cbor2, re, json, sys
toc = '/workspace/questiedb-src/qdb/QuestieDB/QuestieDB_Forever.toc'
meta = {}
for line in open(toc, encoding='utf-8'):
    if line.startswith('## X-'):
        k, _, v = line[3:].rstrip('\n').partition(': ')
        meta[k] = v
def stored(key):
    v = meta.get(key)
    if v is None: return None
    m = re.match(r'^~(\d+)~$', v)
    if m: v = ''.join(meta[f'{key}-{i}'] for i in range(1, int(m.group(1)) + 1))
    return v
def ids(prefix):
    raw = base64.b64decode(stored(f'X-{prefix}IDS'))
    for f in (lambda b: zlib.decompress(b), lambda b: zlib.decompress(b, -15)):
        try: return cbor2.loads(f(raw))
        except Exception: pass
    raise SystemExit('cannot decompress IDS')
def row(prefix, i):
    s = stored(f'X-{prefix}{i}-S')
    return cbor2.loads(base64.b64decode(s)) if s else None
def field(prefix, i, f):
    s = stored(f'X-{prefix}{i}-{f}')
    return cbor2.loads(base64.b64decode(s)) if s else None
if __name__ == '__main__':
    q = ids('Quest-'); it = ids('Item-')
    print(len(q), len(it), q[:5])
    print(row('Quest-', q[1]), field('Quest-', q[1], 10), field('Quest-', q[1], 2))
