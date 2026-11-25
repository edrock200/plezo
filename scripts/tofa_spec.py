#!/usr/bin/env python3
"""Query Tofa's OpenAPI documents (the spec is not committed: its licence is proprietary).

Download them first (see .claude/skills/tofa-backend/SKILL.md):
  curl -sSo /tmp/tofa-api-spec.json https://docs.tofa.tv/api-spec.json          # media server, /api/v1
  curl -sSo /tmp/tofa-cloud-api-spec.json https://docs.tofa.tv/cloud-api-spec.json  # api.tofa.tv sign-in

Usage:
  scripts/tofa_spec.py SPEC paths                 # every method + path + summary
  scripts/tofa_spec.py SPEC op /api/v1/stream/{id}/info ...   # params, body, responses
  scripts/tofa_spec.py SPEC schema PlaybackInfoResponse ...   # fields (* = required)
"""
import json,sys
d=json.load(open(sys.argv[1]))
S=d['components']['schemas']
def ref(r): return r.split('/')[-1]
def short(s,depth=0):
    if not isinstance(s,dict): return str(s)
    if '$ref' in s: return ref(s['$ref'])
    for k in ('oneOf','anyOf','allOf'):
        if k in s: return '|'.join(short(x) for x in s[k])
    t=s.get('type')
    if t=='array': return '['+short(s.get('items',{}))+']'
    if isinstance(t,list): t='/'.join(t)
    if 'enum' in s: return f"{t} enum{s['enum']}"
    return str(t)
def schema(name):
    s=S[name]; out=[]
    for k in ('allOf','oneOf','anyOf'):
        if k in s: out.append(f"  {k}: "+', '.join(short(x) for x in s[k]))
    req=set(s.get('required',[]))
    for p,v in s.get('properties',{}).items():
        out.append(f"  {p}{'*' if p in req else ''}: {short(v)}  {(v.get('description') or '')[:110]}")
    if 'enum' in s: out.append(f"  enum {s['enum']}")
    return f"{name}:\n"+'\n'.join(out)
mode=sys.argv[2]
if mode=='paths':
    for p,ops in d['paths'].items():
        for m,o in ops.items():
            if m in('get','post','put','delete','patch'): print(m.upper(),p,'-',o.get('summary',''))
elif mode=='op':
    for p in sys.argv[3:]:
        for m,o in d['paths'][p].items():
            if m not in('get','post','put','delete','patch'):continue
            print('==',m.upper(),p,':',o.get('summary'));print((o.get('description') or '')[:900])
            for prm in o.get('parameters',[]):
                if '$ref' in prm: prm=d['components']['parameters'][ref(prm['$ref'])]
                print(f"  param {prm['in']} {prm['name']}{'*' if prm.get('required') else ''}: {short(prm.get('schema',{}))} {(prm.get('description') or '')[:120]}")
            rb=o.get('requestBody')
            if rb:
                for ct,c in rb.get('content',{}).items(): print('  body',ct,short(c.get('schema',{})))
            for code,r in o.get('responses',{}).items():
                for ct,c in (r.get('content') or {}).items(): print('  resp',code,ct,short(c.get('schema',{})))
                if not r.get('content'): print('  resp',code,(r.get('description') or '')[:80])
elif mode=='schema':
    for n in sys.argv[3:]: print(schema(n))
