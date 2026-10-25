"""Disposable PostgreSQL integration tests. Requires psql/createdb/dropdb.
Usage: python3 tests/database/test_nfc.py /absolute/local/socket 55437 [--swift-integration]
Never connects over TCP or uses a hosted database. Creates/drops only its own DB.
"""
import concurrent.futures
import json
import pathlib
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOST = sys.argv[1]
assert HOST.startswith('/'), 'A local Unix socket directory is required'
PORT = sys.argv[2]
DB = 'gearlink_nfc_test_' + uuid.uuid4().hex[:12]
BASE = ['psql', '-X', '-h', HOST, '-p', PORT, '-d', DB, '-Atq', '-v', 'ON_ERROR_STOP=1']
COUNT = 0

def uid(): return str(uuid.uuid4())
def quote(v): return "'" + str(v).replace("'", "''") + "'"
def sql(s, actor=None, error=None, role='authenticated'):
    global COUNT
    prefix = f"set role {role}; set request.jwt.claim.sub={quote(actor)};" if actor else ''
    p = subprocess.run(BASE, input=prefix+s, text=True, capture_output=True, timeout=15)
    if error:
        assert p.returncode and error in p.stderr, (error, p.stdout, p.stderr)
        COUNT += 1
        return
    assert p.returncode == 0, p.stderr
    return p.stdout.strip()
def check(value):
    global COUNT
    assert value
    COUNT += 1
def rpc(name, values, actor=None, error=None):
    args = ','.join('null' if v is None else quote(json.dumps(v) if isinstance(v, dict) else v) for v in values)
    out = sql(f'select public.{name}({args});', actor or ADMIN, error)
    return json.loads(out) if out else None

ADMIN, COACH, OTHER = uid(), uid(), uid()
ORG, OTHER_ORG = uid(), uid()
ATHLETE, SECOND, FOREIGN, INACTIVE = uid(), uid(), uid(), uid()
LEGACY = uid()
DETAILS = dict(category='Helmet', size='L', color='Blue', condition='good', purchase_price=125.50)

def register(physical='000102ABCDEF', token='0123456789ABCDEF', **kw):
    return rpc('begin_equipment_registration', [ORG, uid(), 'GL-'+physical[-6:].upper()+'-'+token, physical, 'mifare', DETAILS], **kw)
def confirm(s, **kw):
    return rpc('confirm_equipment_registration', [s['equipment']['id'], s['tag']['id'], s['tag']['physical_uid'], s['equipment']['gearlink_id']], **kw)
def assign(s, athlete=ATHLETE, req=None, **kw):
    return rpc('assign_equipment', [s['equipment']['id'], athlete, req or uid()], **kw)
def events(e): return int(sql(f"select count(*) from equipment_events where equipment_id={quote(e)}"))
def race(statements):
    def run(s):
        return subprocess.run(BASE, input=f"set role authenticated; set request.jwt.claim.sub={quote(ADMIN)}; begin; set local lock_timeout='5s'; {s}; select pg_sleep(0.15); commit;", text=True, capture_output=True, timeout=10)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        return list(pool.map(run, statements))
def call(name, values): return 'select public.'+name+'('+','.join(quote(json.dumps(v) if isinstance(v,dict) else v) for v in values)+')'

subprocess.run(['createdb','-h',HOST,'-p',PORT,DB], check=True)
try:
    # Cluster roles may already exist; this database's schemas are always fresh.
    bootstrap = (ROOT/'tests/database/bootstrap.sql').read_text()
    bootstrap = bootstrap.replace('create role anon nologin;', "do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;")
    bootstrap = bootstrap.replace('create role authenticated nologin;', "do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;")
    sql(bootstrap)
    migrations = sorted((ROOT/'supabase/migrations').glob('*.sql'))
    for file in migrations[:-1]: sql(file.read_text())
    sql(f"""
      insert into auth.users values ({quote(ADMIN)}),({quote(COACH)}),({quote(OTHER)});
      insert into organizations(id,name) values ({quote(ORG)},'Test'),({quote(OTHER_ORG)},'Other');
      insert into organization_members(organization_id,user_id,role) values
        ({quote(ORG)},{quote(ADMIN)},'admin'),({quote(ORG)},{quote(COACH)},'coach'),({quote(OTHER_ORG)},{quote(OTHER)},'admin');
      insert into athletes(id,organization_id,first_name,last_name,active) values
        ({quote(ATHLETE)},{quote(ORG)},'A','One',true),({quote(SECOND)},{quote(ORG)},'B','Two',true),
        ({quote(FOREIGN)},{quote(OTHER_ORG)},'C','Three',true),({quote(INACTIVE)},{quote(ORG)},'D','Four',false);
      insert into equipment(id,organization_id,name,category) values ({quote(LEGACY)},{quote(ORG)},'Legacy','Helmet');
      insert into equipment_tags(organization_id,equipment_id,uid) values ({quote(ORG)},{quote(LEGACY)},'00:11:22:33');
    """)
    # Preflight must abort atomically, preserving problematic source records.
    duplicate = uid()
    sql(f"insert into equipment(id,organization_id,name,category) values ({quote(duplicate)},{quote(ORG)},'Duplicate','Helmet'); insert into equipment_tags(organization_id,equipment_id,uid) values ({quote(ORG)},{quote(duplicate)},'00112233');")
    sql(migrations[-1].read_text(), error='GL_PREFLIGHT_DUPLICATE_ACTIVE_UID')
    check(sql("select count(*) from information_schema.columns where table_name='equipment' and column_name='gearlink_id'") == '0')
    sql(f'delete from equipment_tags where equipment_id={quote(duplicate)}; delete from equipment where id={quote(duplicate)};')
    sql(f"update equipment_tags set uid='NOTHEX' where equipment_id={quote(LEGACY)}")
    sql(migrations[-1].read_text(), error='GL_INVALID_UID')
    sql(f"update equipment_tags set uid='00:11:22:33' where equipment_id={quote(LEGACY)}")
    sql(migrations[-1].read_text())
    check(sql(f'select gearlink_id is null and status=\'available\' from equipment where id={quote(LEGACY)}') == 't')
    s = register(); e=s['equipment']['id']; tag=s['tag']['id']; gl=s['equipment']['gearlink_id']
    check(s['equipment']['status']=='pending_registration' and s['tag']['physical_uid']=='000102ABCDEF')
    resumed=rpc('begin_equipment_registration',[ORG,uid(),'GL-ABCDEF-AAAAAAAAAAAAAAAA','00:01:02:ab:cd:ef','mifare',DETAILS])
    check(resumed['equipment']['id']==e and resumed['equipment']['gearlink_id']==gl and events(e)==1)
    register('001122ABCDEF',error='GL_GEARLINK_ID_COLLISION')
    register('001122AABBCC', actor=OTHER,error='GL_NOT_AUTHORIZED')
    rpc('begin_equipment_registration',[OTHER_ORG,uid(),gl,'000102ABCDEF','mifare',DETAILS],actor=OTHER,error='GL_TAG_UNAVAILABLE')
    rpc('begin_equipment_registration',[ORG,uid(),'GL-ABCDEF-0123456789ABCDEF','ABCDEFZ','mifare',DETAILS],error='GL_INVALID_UID')
    rpc('begin_equipment_registration',[ORG,uid(),'GL-AABBCC-0123456789ABCDEF','00AABBCC','mifare',dict(DETAILS,size='')],error='GL_REQUIRED_EQUIPMENT_FIELDS')
    assign(s,error='GL_EQUIPMENT_UNAVAILABLE')
    rpc('confirm_equipment_registration',[e,tag,'FFFFFFABCDEF',gl],error='GL_IDENTITY_CONFLICT')
    rpc('record_equipment_write_failure',[e,tag,'000102ABCDEF',gl]); n=events(e)
    rpc('record_equipment_write_failure',[e,tag,'000102ABCDEF',gl]); check(events(e)==n)
    confirm(s,actor=OTHER,error='GL_NOT_AUTHORIZED')
    rpc('update_equipment_details',[e,s['equipment']['updated_at'],DETAILS],actor=OTHER,error='GL_NOT_AUTHORIZED')
    rpc('retire_equipment',[e],actor=OTHER,error='GL_NOT_AUTHORIZED')
    s=confirm(s); check(s['equipment']['status']=='available' and s['tag']['write_verified_at'])
    n=events(e); confirm(s); rpc('record_equipment_write_failure',[e,tag,'000102ABCDEF',gl]); check(events(e)==n)
    check(rpc('lookup_equipment_tag',[ORG,'000102ABCDEF',gl])['resolution']=='registered')
    rpc('lookup_equipment_tag',[ORG,'000102ABCDEF',None],error='GL_TAG_CONTENT_MISMATCH')
    rpc('lookup_equipment_tag',[OTHER_ORG,'000102ABCDEF',gl],actor=OTHER,error='GL_TAG_UNAVAILABLE_OR_CONFLICT')
    check(rpc('lookup_equipment_tag',[ORG,'112233445566',None])=={'resolution':'unregistered'})
    rpc('lookup_equipment_tag',[ORG,'00112233',None],error='GL_LEGACY_TAG_REQUIRES_MIGRATION')
    for table in ('equipment','equipment_tags','equipment_assignments','equipment_events'):
        sql(f'delete from public.{table};',actor=ADMIN,error='permission denied')
        check(sql(f'select count(*) from public.{table}',actor=OTHER)=='0')
    sql(f"update equipment set gearlink_id='GL-ABCDEF-FFFFFFFFFFFFFFFF' where id={quote(e)}",error='GL_IMMUTABLE_IDENTITY')
    sql('select public.retire_equipment(null)',actor=ADMIN,error='permission denied',role='anon')
    assign(s,FOREIGN,error='GL_ATHLETE_UNAVAILABLE'); assign(s,INACTIVE,error='GL_ATHLETE_UNAVAILABLE')
    assign(s,actor=OTHER,error='GL_NOT_AUTHORIZED')
    req=uid(); a=assign(s,req=req); n=events(e)
    check(assign(s,req=req)==a and events(e)==n)
    assign(s,SECOND,req=req,error='GL_REQUEST_CONFLICT')
    assign(s,error='GL_EQUIPMENT_UNAVAILABLE')
    rpc('retire_equipment',[e],error='GL_RETURN_BEFORE_RETIREMENT')
    rpc('replace_equipment_tag',[e,tag,'001122445566','mifare'],error='GL_RETURN_BEFORE_TAG_REPLACEMENT')
    rpc('transfer_equipment',[e,ATHLETE,a['assignment_id'],uid()],error='GL_ALREADY_ASSIGNED_TO_ATHLETE')
    rpc('transfer_equipment',[e,FOREIGN,a['assignment_id'],uid()],error='GL_ATHLETE_UNAVAILABLE')
    check(sql(f'select count(*) from equipment_assignments where equipment_id={quote(e)} and returned_at is null')=='1')
    rpc('return_equipment_checked',[a['assignment_id'],uid()],actor=OTHER,error='GL_NOT_AUTHORIZED')
    transfer_req=uid(); b=rpc('transfer_equipment',[e,SECOND,a['assignment_id'],transfer_req]); n=events(e)
    check(rpc('transfer_equipment',[e,SECOND,a['assignment_id'],transfer_req])==b and events(e)==n)
    rpc('return_equipment_checked',[a['assignment_id'],uid()],error='GL_STALE_ASSIGNMENT')
    ret_req=uid(); returned=rpc('return_equipment_checked',[b['assignment_id'],ret_req]); n=events(e)
    check(rpc('return_equipment_checked',[b['assignment_id'],ret_req])==returned and events(e)==n)
    check(sql(f'select count(*) from equipment_assignments where equipment_id={quote(e)} and returned_at is not null')=='2')
    rpc('replace_equipment_tag',[e,tag,'001122445566','mifare'],actor=COACH,error='GL_NOT_AUTHORIZED')
    replacement=rpc('replace_equipment_tag',[e,tag,'001122445566','mifare']); check(replacement['equipment']['gearlink_id']==gl and replacement['equipment']['original_tag_uid']=='000102ABCDEF')
    check(rpc('replace_equipment_tag',[e,tag,'001122445566','mifare'])==replacement)
    rpc('lookup_equipment_tag',[ORG,'000102ABCDEF',gl],error='GL_TAG_UNAVAILABLE_OR_CONFLICT')
    assign(replacement,error='GL_EQUIPMENT_UNAVAILABLE'); s=confirm(replacement)
    before=s['equipment']['updated_at']
    edited=rpc('update_equipment_details',[e,before,dict(DETAILS,condition='needs_repair')]); check(edited['equipment']['status']=='maintenance')
    rpc('update_equipment_details',[e,before,DETAILS],error='GL_STALE_EQUIPMENT')
    assign(edited,error='GL_EQUIPMENT_UNAVAILABLE')
    rpc('retire_equipment',[e],actor=COACH,error='GL_NOT_AUTHORIZED')
    retired=rpc('retire_equipment',[e]); check(retired['equipment']['status']=='retired' and retired['tag'] is None)
    n=events(e); rpc('retire_equipment',[e]); check(events(e)==n)
    # Existing RPC signatures continue to operate for untouched legacy equipment.
    legacy_a=sql(f'select checkout_equipment({quote(LEGACY)},{quote(ATHLETE)})',actor=COACH)
    sql(f'select return_equipment({quote(legacy_a)})',actor=COACH)
    sql(f'select return_equipment({quote(legacy_a)})',actor=COACH)
    check(sql(f'select status from equipment where id={quote(LEGACY)}')=='available')
    # A condition change while issued must keep the returned item out of availability.
    damaged=confirm(register('001122998877')); da=assign(damaged)
    latest=json.loads(sql(f"select to_jsonb(e) from equipment e where id={quote(damaged['equipment']['id'])}"))
    rpc('update_equipment_details',[latest['id'],latest['updated_at'],dict(DETAILS,condition='needs_repair')])
    rpc('return_equipment_checked',[da['assignment_id'],uid()])
    check(sql(f"select status from equipment where id={quote(latest['id'])}")=='maintenance')
    # Concurrent registration converges even with different proposed IDs.
    rs=race([call('begin_equipment_registration',[ORG,uid(),'GL-778899-'+token,'001122778899','mifare',DETAILS]) for token in ('1111111111111111','2222222222222222')])
    check(all(p.returncode==0 for p in rs))
    check(sql("select count(*) from equipment where original_tag_uid='001122778899'")=='1')
    c=confirm(register('001122334455')); ce=c['equipment']['id']
    rs=race([call('assign_equipment',[ce,ath,uid()]) for ath in (ATHLETE,SECOND)])
    check(sum(p.returncode==0 for p in rs)==1 and any('GL_EQUIPMENT_UNAVAILABLE' in p.stderr for p in rs))
    ca=sql(f'select id from equipment_assignments where equipment_id={quote(ce)} and returned_at is null')
    # Return and transfer compete for the same assignment; exactly one wins.
    current=sql(f'select athlete_id from equipment_assignments where id={quote(ca)}')
    rs=race([call('return_equipment_checked',[ca,uid()]),call('transfer_equipment',[ce,SECOND if current==ATHLETE else ATHLETE,ca,uid()])])
    check(sum(p.returncode==0 for p in rs)==1 and any('GL_STALE_ASSIGNMENT' in p.stderr for p in rs))
    c=confirm(register('001122334466')); ce=c['equipment']['id']; req=uid()
    rs=race([call('assign_equipment',[ce,ATHLETE,req])]*2)
    check(all(p.returncode==0 for p in rs) and sql(f'select count(*) from equipment_assignments where equipment_id={quote(ce)}')=='1')
    check(sql("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef")=='0')
    check(sql("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.prosecdef and not ('search_path=\"\"'=any(p.proconfig))")=='0')
    print(f'PASS: {COUNT} database assertions, including concurrent transactions and authenticated roles', flush=True)
    if '--swift-integration' in sys.argv[3:]:
        # Synthetic scale fixtures stay inside this disposable database.
        sql(f"""
          insert into athletes(organization_id,first_name,last_name,team,active)
          select {quote(ORG)}, 'Scale', lpad(n::text,6,'0'), 'Integration squad', n % 10 <> 0
          from generate_series(1,1200) n;
          with created as (
            insert into equipment(organization_id,name,category)
            select {quote(ORG)}, 'Scale equipment ' || n, 'Helmet' from generate_series(1,5000) n
            returning id,organization_id
          )
          insert into equipment_tags(organization_id,equipment_id,uid)
          select organization_id,id,'BEEF' || lpad(to_hex(row_number() over ()),8,'0') from created;
        """)
        subprocess.run(['sh', str(ROOT/'tests/swift/run-integration.sh'), HOST, PORT, DB, ADMIN, ORG, ATHLETE, SECOND], check=True)
finally:
    subprocess.run(['dropdb','-h',HOST,'-p',PORT,DB],check=True)
