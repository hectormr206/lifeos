#!/usr/bin/env bash
# Wait for North's definitive-era row to land, then audit it for gaps/zeros.
R=/home/hectormr/LifeOS/lifeos/axi/scripts/bench/results/model_audit.jsonl
PY=/home/hectormr/LifeOS/lifeos/axi/.venv/bin/python
until $PY -c "
import json,sys
rows=[json.loads(l) for l in open('$R') if l.strip()]
ok=any(x['label']=='north-mini-code' and x.get('tier')=='vram12' and (x.get('recipe') or {}).get('role_configs') and 'toolstress' in (x.get('roles') or {}) for x in rows)
sys.exit(0 if ok else 1)" 2>/dev/null; do sleep 60; done
$PY - <<'PYEOF'
import json
rows=[json.loads(l) for l in open('/home/hectormr/LifeOS/lifeos/axi/scripts/bench/results/model_audit.jsonl') if l.strip()]
r=[x for x in rows if x['label']=='north-mini-code' and x.get('tier')=='vram12' and (x.get('recipe') or {}).get('role_configs')][-1]
roles=r['roles']
q=['brain','extraction','domain','toolcall','vision','codereview','codegen','conversation','recordsqa','narration','longsum','parsejson','agentic','proactive','visionclass','devplan','toolstress']
def hl(d):
    if not isinstance(d,dict) or 'skipped' in d: return None
    for k in ('final','case_pass_rate','overall_accuracy','score','pass_rate','judge_score','numeric_fidelity_rate'):
        v=d.get(k)
        if isinstance(v,(int,float)): return v
print('=== NORTH gap/zero audit ===')
gaps=[rr for rr in q if hl(roles.get(rr)) is None]
zeros=[rr for rr in q if hl(roles.get(rr))==0.0]
print('HUECOS:', gaps or 'ninguno')
print('CEROS :', zeros or 'ninguno')
print('devbench:', (roles.get('devbench') or {}).get('full_pass_rate'), '| ctxprobe:', (roles.get('ctxprobe') or {}).get('ctx_max_current'), '| speed:', (roles.get('speed') or {}).get('decode_p50_toks_s'))
PYEOF
echo "NORTH_GAP_CHECK_DONE"
