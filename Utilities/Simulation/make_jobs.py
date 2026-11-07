import json, random, re, sys
src = open(sys.argv[4], encoding='utf-8').read()
cat = src[src.index('const CATALOG := ['):]
cat = cat[:cat.index('\n]\n')]
entries = []
for m in re.finditer(r'\{"id": "(\w+)", "v": (\{.*?\}), "tier": "(\w+)"', cat):
    v = json.loads(m.group(2).replace('true','true'))
    entries.append({"id": m.group(1), "v": v})
entries = [e for e in entries if e["id"] != "best_move"]
n = int(sys.argv[1]); out = sys.argv[2]; seed0 = int(sys.argv[3])
rnd = random.Random(seed0)
def loadout():
    k = rnd.randint(1, 8); ids = set(); lo = []
    while len(lo) < k:
        e = rnd.choice(entries)
        if e["id"] in ids: continue
        ids.add(e["id"]); lo.append(e)
    return lo
jobs = []
for i in range(n):
    jobs.append({"id": "loadout", "phase": "loadout2", "mode": "loadout", "holder": "", "powerups": [],
                 "depth": 3 if rnd.random() < 0.1 else 6, "seed": seed0 + i,
                 "loadout_w": loadout(), "loadout_b": loadout()})
json.dump(jobs, open(out, 'w'))
print(len(entries), "variants,", len(jobs), "jobs")
