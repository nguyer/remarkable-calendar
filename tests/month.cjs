const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const source=fs.readFileSync('qml/Main.qml','utf8');
const c={Date,primaryView:'week',displayedDate:new Date(2026,9,29,12),detailDayDate:new Date(2026,9,29,12),detailsLevel:'',
    cancelDayRequest(){},cancelMonthRequest(){},rememberNavigation(){},
    monday(d){const r=new Date(d);r.setDate(r.getDate()-((r.getDay()+6)%7));return r;}};
c.loadMonth=date=>{c.requestedMonthDate=date;c.monthDate=date;};
vm.createContext(c);
vm.runInContext(source.slice(source.indexOf('    function monthGeometry('),source.indexOf('    function arrangeEvents(')),c);
const iso=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
for(const [date,start,rows] of [
    [new Date(2021,1,1,12),'2021-02-01',4],
    [new Date(2024,1,1,12),'2024-01-29',5],
    [new Date(2026,10,1,12),'2026-10-26',6],
    [new Date(2027,0,1,12),'2026-12-28',5]]){
    const g=c.monthGeometry(date);assert.equal(iso(g.start),start);assert.equal(g.rows,rows);
}
assert.equal(c.isoWeekNumber(new Date(2021,0,1,12)),53);
assert.equal(c.isoWeekNumber(new Date(2021,0,4,12)),1);
assert.equal(c.isoWeekNumber(new Date(2027,0,1,12)),53);
c.openMonth(new Date(2026,11,31,12));assert.equal(iso(c.monthDate),'2026-12-01');
c.shiftMonth(1);assert.equal(iso(c.monthDate),'2027-01-01');
c.shiftMonth(-2);assert.equal(iso(c.monthDate),'2026-11-01');
c.primaryView='day';c.detailDayDate=new Date(2024,1,29,12);c.openMonth();assert.equal(iso(c.monthDate),'2024-02-01');
let openedDay=null,openedWeek=null;
c.setDay=date=>{openedDay=iso(date);};c.loadDay=()=>{};
c.openDate(new Date(2027,0,1,12));assert.equal(c.primaryView,'day');assert.equal(openedDay,'2027-01-01');
// Execute the grid's actual hit testing for the week gutter, days, and outside bounds.
const month=fs.readFileSync('qml/MonthView.qml','utf8');
c.gridStart=new Date(2026,9,26,12);c.rowCount=6;c.weekWidth=64;c.grid={rowHeight:100,cellWidth:100};
c.app={showWeek:d=>{openedWeek=iso(d);},openDate:d=>{openedDay=iso(d);}};c.page=c;
vm.runInContext(month.slice(month.indexOf('    function dateAt('),month.indexOf('    CalendarToolbar')),c);
c.activateCell(20,20);assert.equal(openedWeek,'2026-10-26');
c.activateCell(714,20);assert.equal(openedDay,'2026-11-01');
c.activateCell(114,120);assert.equal(openedDay,'2026-11-02');
c.activateCell(20,599);assert.equal(openedWeek,'2026-11-30');
c.activateCell(114,601);assert.equal(openedDay,'2026-11-02','outside the grid must not navigate');
console.log('PASS: month grid sizes, leap years, ISO week numbers, month/year navigation, and date/week hit tests');
