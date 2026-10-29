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
const c={Date,XMLHttpRequest:XHR,monthSerial:0,monthRequest:null,monthDate:new Date(2026,9,1,12),monthEvents:[],monthMessage:'',
    monthDeadline:{restart(){},stop(){}},rememberNavigation(){},
    isoDate(d){return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;},
    monday(d){const r=new Date(d);r.setDate(r.getDate()-((r.getDay()+6)%7));return r;},
    monthTitleMeasure:{text:'',width:0,forceLayout(){},get implicitHeight(){return this.text==='Long title' ? 48 : 24;}}
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
console.log('PASS: atomic/stale month responses, failures retain data, complete event fitting and overflow');
