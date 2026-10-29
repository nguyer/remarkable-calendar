const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync('qml/Main.qml','utf8');
const helpers = qml.slice(qml.indexOf('    function rememberNavigation('),qml.indexOf('    Timer { id: navigationRetry;'));
const requests = [];
class XHR {
    static DONE = 4;
    open(method,url) { this.method=method; this.url=url; }
    setRequestHeader() {}
    send(body) { this.body=body; requests.push(this); }
    respond(value,status=200) { this.status=status; this.readyState=4; this.responseText=JSON.stringify(value); this.onreadystatechange(); }
}
const c = {
    XMLHttpRequest: XHR, navigationReady:false, navigationRequest:null, navigationPending:'', navigationFailures:0,
    primaryView:'week', displayedDate:new Date(2026,9,26,12), detailDayDate:new Date(2026,9,28,12),
    isoDate(d) { return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`; },
    monday(d) { const r=new Date(d); r.setDate(r.getDate()-((r.getDay()+6)%7)); return r; },
    localDate(s) { const [y,m,d]=s.split('-').map(Number); return new Date(y,m-1,d,12); },
    navigationDeadline:{restart(){},stop(){}}, navigationRetry:{restart(){}},
    loadWeek(){this.weeks=(this.weeks||0)+1;}, loadDay(d){this.loadedDay=this.isoDate(d);}
};
c.loadWeek=()=>{c.weeks=(c.weeks||0)+1;}; c.loadDay=d=>{c.loadedDay=c.isoDate(d);};
c.root=c; vm.createContext(c); vm.runInContext(helpers,c);
c.rememberNavigation(); assert.equal(requests.length,0,'startup must not overwrite saved navigation');
c.restoreNavigation(); requests.at(-1).respond({navigation:{view:'day',date:'2027-01-02'}});
assert.equal(c.primaryView,'day'); assert.equal(c.loadedDay,'2027-01-02'); assert.equal(c.weeks,1);
c.rememberNavigation(); const first=requests.at(-1);
assert.deepEqual(JSON.parse(first.body),{view:'day',date:'2027-01-02'});
c.detailDayDate=new Date(2027,0,3,12); c.rememberNavigation();
assert.equal(requests.at(-1),first,'serialize writes so old responses cannot overwrite newer navigation');
first.respond({ok:true}); const second=requests.at(-1);
assert.equal(JSON.parse(second.body).date,'2027-01-03'); second.respond({ok:true});
assert.equal(c.navigationPending,'');
c.primaryView='week'; c.displayedDate=new Date(2026,11,31,12); c.rememberNavigation();
assert.deepEqual(JSON.parse(requests.at(-1).body),{view:'week',date:'2026-12-28'});
requests.at(-1).respond({ok:true});
console.log('PASS: saved day restoration, startup guard, serialized navigation writes, and week boundaries');
