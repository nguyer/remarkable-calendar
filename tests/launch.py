#!/usr/bin/env python3
"""Linux host integration test using a real SOCK_SEQPACKET fake AppLoad peer."""
import json, os, pathlib, socket, sqlite3, struct, subprocess, tempfile, time, urllib.request, urllib.error
ROOT=pathlib.Path(__file__).resolve().parents[1]
BIN=ROOT/'target/debug/remarkable-calendar-core'
def get(path):
    with urllib.request.urlopen('http://127.0.0.1:38765'+path,timeout=2) as r: return json.load(r)
def navigation_checks():
    assert get('/navigation') == {'navigation':None}
    original_settings = get('/settings')['settings']
    def save(state, authorized=True):
        request=urllib.request.Request('http://127.0.0.1:38765/navigation', data=json.dumps(state).encode(),
            headers={'X-RemarkableCalendar-Request':'sync','Content-Type':'application/json'} if authorized else {})
        try:
            with urllib.request.urlopen(request,timeout=2) as response: return response.status
        except urllib.error.HTTPError as error: return error.code
    assert save({'view':'day','date':'2027-01-02'},False)==403
    assert save({'view':'day','date':'2027-01-02'})==200
    for invalid in [{'view':'event','date':'2027-01-02'}, {'view':'day','date':'2027-02-30'}, {'view':'week','date':'invalid'}]:
        assert save(invalid)==400
    assert get('/navigation')['navigation']=={'view':'day','date':'2027-01-02'}
    assert get('/settings')['settings']==original_settings
    assert save({'view':'week','date':'2026-12-28'})==200
    assert save({'view':'day','date':'2027-01-02'})==200
    print('PASS: navigation defaults, guarded saves, validation, and settings isolation')
def sync_checks(tmp):
    def post(headers):
        request = urllib.request.Request('http://127.0.0.1:38765/google/sync', data=b'', headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)
    assert get('/google/sync')['state'] == 'idle'
    assert post({})[0] == 403
    headers = {'X-RemarkableCalendar-Request':'sync'}
    assert post(headers)[0] == 409  # No first sync configured yet.
    with sqlite3.connect(tmp+'/events.sqlite3') as db:
        db.execute("INSERT INTO google_sync VALUES ('work','2026-10-01T00:00:00-06:00','2027-02-01T00:00:00-06:00','America/Guatemala','test')")
        db.execute("INSERT INTO calendar_preferences (id,name,color,enabled) VALUES ('work','Work','#112233',1)")
    code, status = post(headers)
    assert code == 202
    for _ in range(100):
        status = get('/google/sync')
        assert get('/health')['ok']  # Status/week requests remain usable during background work.
        assert len(get('/week?date=2026-10-26')['events']) == 1
        if status['state'] != 'running': break
        time.sleep(.02)
    assert status['state'] == 'failed'  # Isolated test credentials are intentionally missing.
    assert status['completed'] == 0 and status['total'] == 1
    assert get('/google/status')['calendars'][0]['synced_at'] == 'test'
    assert post(headers)[0] == 202  # A failed job can be retried.
    # Settings requests exercise actual body parsing and persistent visibility.
    def save_settings(draft, authorized=True):
        request = urllib.request.Request('http://127.0.0.1:38765/settings', data=json.dumps(draft).encode(),
            headers=headers if authorized else {})
        try:
            with urllib.request.urlopen(request,timeout=2) as response: return response.status,json.load(response)
        except urllib.error.HTTPError as error: return error.code,json.load(error)
    # Wait for the deliberate retry to finish before editing its selection.
    for _ in range(100):
        if get('/google/sync')['state'] != 'running': break
        time.sleep(.02)
    config = get('/settings')
    draft = config['settings']
    assert draft['selected_ids'] == ['work']
    assert draft['months_before'] == 1 and draft['months_after'] == 6
    assert draft['time_format']=='12h' and draft['day_scroll'] is False
    assert draft['day_start']==420 and draft['day_end']==1260
    assert get('/week?date=2026-10-26')['display']==dict(time_format='12h',day_scroll=False,day_start=420,day_end=1260)

    assert save_settings(draft,False)[0] == 403
    with sqlite3.connect(tmp+'/events.sqlite3') as db:
        db.execute("INSERT INTO google_cache VALUES (?,?,?)",('work','remote',json.dumps(dict(id='remote',title='Remote',day='2026-10-26',start='13:00',end='14:00',color='#112233'))))
    assert len(get('/week?date=2026-10-26')['events']) == 2
    draft['selected_ids'] = []
    draft['auto_sync'] = False
    assert save_settings(draft)[0] == 200
    assert len(get('/week?date=2026-10-26')['events']) == 1
    assert get('/google/status')['calendars'] == []
    with sqlite3.connect(tmp+'/events.sqlite3') as db:
        assert db.execute('SELECT count(*) FROM google_cache').fetchone()[0] == 1
    draft['selected_ids'] = ['unknown']
    assert save_settings(draft)[0] == 400
    assert get('/settings')['settings']['selected_ids'] == []
    draft['selected_ids'] = ['work']
    assert save_settings(draft)[0] == 200
    assert len(get('/week?date=2026-10-26')['events']) == 2
    draft['time_format']='24h';draft['day_scroll']=True;draft['day_start']=480;draft['day_end']=1200
    assert save_settings(draft)[0]==200
    assert get('/week?date=2026-10-26')['display']==dict(time_format='24h',day_scroll=True,day_start=480,day_end=1200)
    draft['day_end']=draft['day_start']
    assert save_settings(draft)[0]==400
    assert get('/settings')['settings']['day_end']==1200
    # Details travel over the same weekly endpoint, including original multi-day times.
    remote = dict(id='remote',title='Remote',day='2026-10-25',start='22:00',end='02:00',end_day='2026-10-26',color='#112233',details=dict(location='Studio',description='Offline notes',calendar_name='Work',timezone='America/Guatemala'))
    with sqlite3.connect(tmp+'/events.sqlite3') as db:
        db.execute('UPDATE google_cache SET event_json=? WHERE event_id=?',(json.dumps(remote),'remote'))
    event = next(e for e in get('/week?date=2026-10-26')['events'] if e['id']=='remote')
    assert event['start']=='00:00'
    assert event['details']['start_day']=='2026-10-25'
    assert event['details']['start_time']=='22:00'
    assert event['details']['location']=='Studio'
    assert event['details']['description']=='Offline notes'
    print('PASS: offline HTTP event metadata and original interval survive weekly clipping')
    # Clean up the isolated fixture so the original HTTP assertions retain their meaning.
    with sqlite3.connect(tmp+'/events.sqlite3') as db: db.execute('DELETE FROM google_cache')
    def event_change(change, authorized=True):
        request=urllib.request.Request('http://127.0.0.1:38765/events/change',data=json.dumps(change).encode(),headers=headers if authorized else {})
        try:
            with urllib.request.urlopen(request,timeout=2) as response:return response.status,json.load(response)
        except urllib.error.HTTPError as error:return error.code,json.load(error)
    draft_event=dict(operation='create',calendar_id='local',title='Local edit test',start_day='2026-12-10',end_day='2026-12-10',start_time='09:00',end_time='10:00',location='Room A',description='Offline notes',all_day=False)
    assert event_change(draft_event,False)[0]==403
    code,created=event_change(draft_event);assert code==200 and created['queued'] is False
    assert get('/settings')['last_calendar_id']=='local'
    draft_event.update(operation='update',id=created['event']['id'],title='Edited locally')
    assert event_change(draft_event)[0]==200
    assert get('/week?date=2026-12-10')['events'][0]['title']=='Edited locally'
    assert event_change(dict(operation='delete',id=draft_event['id']))[0]==200
    assert get('/week?date=2026-12-10')['events']==[]
    with sqlite3.connect(tmp+'/events.sqlite3') as db:db.execute("UPDATE calendar_preferences SET access_role='writer' WHERE id='work'")
    draft_event.update(operation='create',calendar_id='work',id='',title='Pending Google event')
    code,created=event_change(draft_event);assert code==200 and created['queued'] is True
    assert get('/settings')['last_calendar_id']=='work'
    pending_id=created['event']['id']
    draft_event.update(operation='update',id=pending_id,title='Pending revised')
    assert event_change(draft_event)[0]==200
    assert len(get('/events/pending'))==1
    assert event_change(dict(operation='discard',id=pending_id))[0]==200
    assert get('/events/pending')==[]
    draft_event.update(operation='create',id='')
    assert event_change(draft_event)[0]==200
    assert get('/google/status')['pending_count']==1
    print('PASS: offline HTTP local CRUD, Google queue/coalescing/discard and mutation header guard')
    print('PASS: settings body parsing, guard, defaults, hide/show without deleting cache, invalid selection rollback')
    print('PASS: sync header guard, setup error, background failure/retry, HTTP responsiveness, cache metadata preservation')

def ready(p):
    for _ in range(100):
        if p.poll() is not None: raise AssertionError('backend exited early')
        try: return get('/health')
        except OSError: time.sleep(.05)
    raise AssertionError('backend did not become ready')
with tempfile.TemporaryDirectory() as tmp:
    env=dict(os.environ,REMARKABLE_CALENDAR_DB=tmp+'/events.sqlite3',REMARKABLE_CALENDAR_GOOGLE_CREDENTIALS=tmp+'/missing-google.json')
    subprocess.run([BIN,'import',ROOT/'examples/events.json'],env=env,check=True)
    p=None
    try:
        try:
            s=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET)
        except PermissionError:
            print('SKIP: AppLoad lifecycle test: host denies AF_UNIX socket creation')
            p=subprocess.Popen([BIN,'serve'],env=env);ready(p)
            navigation_checks()
            sync_checks(tmp)
            assert len(get('/week?date=2026-10-26')['events'])==1
            assert get('/week?date=2026-11-02')['events']==[]
            duplicate=subprocess.run([BIN,'serve'],env=env,capture_output=True,timeout=5)
            assert duplicate.returncode!=0 and p.poll() is None
            p.terminate();p.wait(timeout=5)
            p=subprocess.Popen([BIN,'serve'],env=env);ready(p)
            assert len(get('/week?date=2027-01-03')['events'])==1
            p.terminate();p.wait(timeout=5)
            print('PASS: real HTTP, fixed dates, duplicate rejection, restart persistence')
            raise SystemExit(0)
        s.bind(tmp+'/app.sock');s.listen(1);s.settimeout(5)
        p=subprocess.Popen([BIN,tmp+'/app.sock'],env=env)
        c,_=s.accept()
        assert ready(p)=={'ok':True}
        navigation_checks()
        sync_checks(tmp)
        assert get('/week?date=2026-10-26')['events'][0]['id']=='planning-2026-10-26'
        assert get('/week?date=2026-11-02')['events']==[]
        duplicate=subprocess.run([BIN,'serve'],env=env,capture_output=True,timeout=5)
        assert duplicate.returncode!=0 and p.poll() is None
        # Upstream sends header and optional payload as separate packets.
        c.send(struct.pack('=II',0xfffffffe,2));c.send(b'{}')
        assert get('/health')['ok']
        c.close();p.wait(timeout=5);assert p.returncode==0
        p=subprocess.Popen([BIN,'serve'],env=env);ready(p)
        assert len(get('/week?date=2027-01-03')['events'])==1
        assert get('/navigation')['navigation']=={'view':'day','date':'2027-01-02'}
        assert len(get('/events/pending'))==1
        assert get('/week?date=2026-12-10')['events'][0]['details']['pending'] is True
        p.terminate();p.wait(timeout=5)
        # A stale enabled calendar starts one background refresh on launch, even offline.
        with sqlite3.connect(tmp+'/events.sqlite3') as db:
            draft = json.loads(db.execute('SELECT json FROM app_settings WHERE id=1').fetchone()[0])
            draft['auto_sync'] = True
            db.execute('UPDATE app_settings SET json=? WHERE id=1',(json.dumps(draft),))
        p=subprocess.Popen([BIN,'serve'],env=env);ready(p)
        for _ in range(100):
            state=get('/google/sync')['state']
            if state=='failed': break
            time.sleep(.02)
        assert state=='failed'
        assert get('/health')['ok']
        assert len(get('/week?date=2026-10-26')['events'])==1
        assert get('/settings')['settings']['auto_sync'] is True
        p.terminate();p.wait(timeout=5)
        print('PASS: stale launch starts sync offline without blocking cached events; settings persist after restart')
        # Explicit termination packet also ends the process.
        s.close();s=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET)
        os.unlink(tmp+'/app.sock');s.bind(tmp+'/app.sock');s.listen(1);s.settimeout(5)
        p=subprocess.Popen([BIN,tmp+'/app.sock'],env=env);c,_=s.accept();ready(p)
        c.send(struct.pack('=II',0xffffffff,5));c.send(b'close');p.wait(timeout=5);assert p.returncode==0
        c.close();s.close()
    finally:
        if p and p.poll() is None:p.kill();p.wait()
print('PASS: launch handshake, HTTP, fixed dates, duplicate rejection, restart persistence, disconnect and terminate')
