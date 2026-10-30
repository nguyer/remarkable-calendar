const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const source=fs.readFileSync('qml/Main.qml','utf8');
const requests=[];
class XHR {
    static DONE=4;
    open(method,url){this.url=url;}
    send(){requests.push(this);}
    abort(){this.aborted=true;}
    respond(value,status=200){this.status=status;this.readyState=4;this.responseText=JSON.stringify(value);this.onreadystatechange();}
}
const c={Date,XMLHttpRequest:XHR,monthCache:{},monthCacheOrder:[],monthTextHeights:{},monthTextHeightCount:0,monthTextWidth:-1,monthSerial:0,monthRequest:null,monthDate:new Date(2026,9,1,12),monthEvents:[],monthMessage:'',
    monthDeadline:{restart(){},stop(){}},rememberNavigation(){},
    isoDate(d){return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;},
    monday(d){const r=new Date(d);r.setDate(r.getDate()-((r.getDay()+6)%7));return r;},
    monthFontMetrics:{height:24,advanceWidth(title){return title==='Long title' ? 200 : 40;}}
};
vm.createContext(c);
vm.runInContext(source.slice(source.indexOf('    function monthGeometry('),source.indexOf('    function isoWeekNumber(')),c);
vm.runInContext(source.slice(source.indexOf('    function cancelMonthRequest('),source.lastIndexOf('    Timer {',source.indexOf('id: monthDeadline;'))),c);
const response=(month,events=[])=>{const g=c.monthGeometry(new Date(month+'T12:00:00'));const end=new Date(g.start);end.setDate(end.getDate()+g.rows*7);return {month,start:c.isoDate(g.start),end:c.isoDate(end),events};};
const existing=[{id:'old'}];c.monthEvents=existing;
c.loadMonth(new Date(2026,10,1,12));const first=requests.at(-1);
assert.equal(c.isoDate(c.monthDate),'2026-10-01');assert.equal(c.monthEvents,existing,'keep old date/events together until success');
c.loadMonth(new Date(2026,11,1,12));const second=requests.at(-1);
assert.equal(first.aborted,true);first.respond(response('2026-11-01',[{id:'stale'}]));
assert.equal(c.monthEvents,existing,'stale response cannot replace newer navigation');
second.respond(response('2026-12-01',[{id:'new'}]));
assert.equal(c.isoDate(c.monthDate),'2026-12-01');assert.equal(c.monthEvents[0].id,'new');
c.loadMonth(new Date(2027,0,1,12));requests.at(-1).respond({},500);
assert.equal(c.isoDate(c.monthDate),'2026-12-01');assert.equal(c.monthEvents[0].id,'new');assert.ok(c.monthMessage);
const event=(id,title='Short')=>({id,day:'2026-12-01',title,color:'#123456'});
const input=[event('a'),event('b'),event('c')];const snapshot=JSON.stringify(input);
let layout=c.arrangeMonthEvents(input,128,160)['2026-12-01'];
assert.equal(layout.entries.length,2);assert.equal(layout.hidden,1);
assert.equal(layout.entries[1].y,30);assert.ok(layout.entries.every(e=>e.y+e.height<=56));
layout=c.arrangeMonthEvents(input.slice(0,2),128,134)['2026-12-01'];
assert.equal(layout.entries.length,2);assert.equal(layout.hidden,0,'fit all events without reserving an unnecessary footer');
layout=c.arrangeMonthEvents([event('a','Long title'),event('b'),event('c')],128,160)['2026-12-01'];
assert.equal(layout.entries.length,1);assert.equal(layout.hidden,2);assert.equal(layout.entries[0].height,48);
assert.equal(c.arrangeMonthEvents(input,128,90)['2026-12-01'].entries.length,0);
assert.equal(JSON.stringify(input),snapshot,'layout must not mutate cached events');
assert.equal(c.monthEntryHeight('First\nSecond',101),48,'explicit line breaks reserve two complete lines');

// A heavily crowded day must not measure hundreds of invisible titles.
let measured=0;c.monthFontMetrics.advanceWidth=()=>{measured++;return 40;};
c.monthTextHeights={};c.monthTextHeightCount=0;c.monthTextWidth=-1;
const crowded=Array.from({length:1000},(_,i)=>event(String(i),'Title '+i));
layout=c.arrangeMonthEvents(crowded,128,160)['2026-12-01'];
assert.equal(layout.hidden,998);assert.equal(measured,2,'measure only the visible prefix, not 1000 hidden titles');
c.arrangeMonthEvents(crowded,128,160);assert.equal(measured,2,'repeat layouts reuse text heights');
c.arrangeMonthEvents(crowded,140,160);assert.equal(measured,4,'width changes invalidate text heights');
const before=requests.length;
c.loadMonth(new Date(2026,11,1,12));
assert.equal(requests.length,before,'returning to a cached month skips HTTP');
c.invalidateMonthCache();c.loadMonth(new Date(2026,11,1,12));
assert.equal(requests.length,before+1,'edits/settings/sync can invalidate cached previews');
requests.at(-1).respond(response('2026-12-01'));
c.loadMonth(new Date(2026,10,1,12));const outdated=requests.at(-1);
c.invalidateMonthCache();outdated.respond(response('2026-11-01'));
assert.equal(c.isoDate(c.monthDate),'2026-12-01','invalidation rejects an in-flight outdated response');
for(let i=0;i<4;i++) {const date=new Date(2027,i,1,12);c.loadMonth(date);requests.at(-1).respond(response(c.isoDate(date)));}
assert.equal(Object.keys(c.monthCache).length,3,'bound recent-month cache size');
console.log('PASS: month response ordering, overflow, visible-only text measurement, cached heights/months, and invalidation');
