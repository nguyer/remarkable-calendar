// Exercise the actual QML arrangement function with deterministic text measurements.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync('qml/Main.qml', 'utf8');
const body = qml.slice(qml.indexOf('    function arrangeEvents('), qml.indexOf('    function reflowEvents('));
const context = {
    weekView: {width: 954, height: 7 * 136},
    displayPrefs: {time_format:'24h',day_scroll:true,day_start:420,day_end:1260},
    timeMeasure: {implicitHeight: 21, forceLayout() {}},
    titleMeasure: {text: '', width: 0, forceLayout() {}, get implicitHeight() { return this.text === 'Wrapped title' ? 75 : 27; }}
};
vm.createContext(context);
vm.runInContext(body, context);
const event = (offset, start, title = 'Event') => ({offset, start, title, time: start, color: '#112233'});
const input = [event(0,'00:00'), event(0,'09:00'), event(0,'11:00'), event(0,'12:00'), event(1,'09:00','Wrapped title'), event(1,'10:00'), event(2,'14:00')];
const before = JSON.stringify(input);
const result = context.arrangeEvents(input);
assert.deepEqual(Array.from(result, e => e.column), [0,0,1,1,0,1,1]);
assert.equal(JSON.stringify(input),before, 'arrangement must not mutate the currently displayed model');
assert.equal(JSON.stringify(context.arrangeEvents(result)),JSON.stringify(result), 'repeat layout must be stable');
assert.equal(context.titleMeasure.width,405);
// When four afternoon entries exceed right capacity, move the earliest to the bottom left.
context.weekView.height = 7 * 196; // 168 pixels available per column.
const afternoon = [event(0,'09:00'),event(0,'12:00'),event(0,'13:00'),event(0,'14:00'),event(0,'15:00')];
const flowed = context.arrangeEvents(afternoon);
assert.deepEqual(Array.from(flowed,e => e.column),[0,0,1,1,1]);
assert.equal(flowed[1].layoutY,120);
assert.equal(flowed[1].layoutY + flowed[1].layoutHeight,168, 'overflow must align with the bottom');
assert.ok(flowed[1].layoutY >= flowed[0].layoutHeight + 12, 'morning and afternoon must not overlap');
assert.equal(JSON.stringify(context.arrangeEvents(flowed)),JSON.stringify(flowed));
// No movement to the left if afternoon entries already fit.
assert.ok(context.arrangeEvents([event(0,'12:00'),event(0,'13:00')]).every(e => e.column === 1));
// Preserve order and retain an overflow indicator when neither column has enough room.
const crowded = context.arrangeEvents([...afternoon,event(0,'16:00'),event(0,'17:00')]);
assert.deepEqual(Array.from(crowded,e => e.column),[0,0,0,1,1,1,1]);
assert.equal(crowded[1].layoutY,60);
assert.equal(crowded[2].layoutY,120);
assert.ok(crowded[6].layoutY + crowded[6].layoutHeight > 168);
// Reading down the left column and then the right must preserve event chronology.
for (const arranged of [flowed,crowded]) {
    const readingOrder = [...arranged.filter(e => e.column === 0),...arranged.filter(e => e.column === 1)];
    assert.deepEqual(readingOrder.map(e => e.start), [...readingOrder.map(e => e.start)].sort());
}
// Do not skip an early, tall afternoon entry to move a later short one to the left.
const blocked = context.arrangeEvents([event(0,'09:00','Wrapped title'),event(0,'12:00','Wrapped title'),event(0,'13:00'),event(0,'14:00')]);
assert.deepEqual(Array.from(blocked,e => e.column),[0,1,1,1]);
context.weekView.height = 7 * 40;
assert.ok(context.arrangeEvents(input).every(e => e.column === 1), 'oversized entries continue on the right');
assert.equal(context.arrangeEvents([]).length,0);
// Metadata must survive layout and the day list must retain hidden events.
const metadata = event(0,'09:00');
metadata.details = {location:'Room A',description:'Notes',calendar_name:'Work'};
metadata.allDay = false;
assert.equal(JSON.stringify(context.arrangeEvents([metadata])[0].details),JSON.stringify(metadata.details));
assert.equal(context.arrangeEvents([metadata])[0].allDay,false);
assert.equal(context.plainDescription('<p>Meet &amp; plan<br>Bring notes</p>'),'Meet & plan\nBring notes');
assert.equal(context.plainDescription('2 < 3 and 4 > 1'),'2 < 3 and 4 > 1');
assert.equal(context.plainDescription('<a href="https://example.com">Join</a>'),'Join (https://example.com)');
assert.equal(context.plainDescription('<script>bad()</script><p>Safe</p>'),'Safe');
// The full-day snapshot includes hidden events; only visible entries are direct event targets.
context.weekView.height = 7 * 196;
context.events = context.arrangeEvents([...afternoon,event(0,'16:00'),event(0,'17:00')]);
context.dayList = {contentY:0,width:954,height:1400,contentHeight:2960};
context.hourHeight = 120;
context.daySerial = 0;
context.dayRequest = null;
context.dayDeadline = {stop() {}};
context.detailsLevel = "";
context.eventDetailsScroll = {contentY:0};
context.root = {refreshActiveEvent() {},dayAt(offset) { return new Date(2026,9,26+offset,12); }};
context.openWeeklyTap(20,20); // Date badge.
assert.equal(context.detailsLevel,'day');
assert.equal(context.dayDetailEvents.length,7);
context.openWeeklyTap(90,15); // First event in the left column.
assert.equal(context.detailsLevel,'event');
assert.equal(context.activeDetailEvent.start,'09:00');
assert.equal(context.eventReturnScreen,'');
context.closeEvent();
assert.equal(context.detailsLevel,'', 'weekly event closes directly to the week');
context.openDay(0);
context.openEvent(context.dayDetailEvents[0]);
assert.equal(context.eventReturnScreen,'day');
context.closeEvent();
assert.equal(context.detailsLevel,'day', 'day event closes back to the hourly schedule');

context.openWeeklyTap(900,183); // Bottom-right More events notice.
assert.equal(context.detailsLevel,'day');
context.Qt = {formatDate(date) { return date.getFullYear()+'-'+String(date.getMonth()+1).padStart(2,'0')+'-'+String(date.getDate()).padStart(2,'0'); }};
context.isoDate = context.Qt.formatDate;
assert.equal(context.eventSpan({allDay:true,details:{start_day:'2026-11-01',end_day:'2026-11-03'}}),'All day · 2026-11-01 – 2026-11-02');
assert.equal(context.eventSpan({allDay:false,details:{start_day:'2026-11-01',start_time:'22:00',end_day:'2026-11-02',end_time:'02:00'}}),'2026-11-01 22:00 – 2026-11-02 02:00');
// Hourly positions and collision lanes use the actual scheduling function.
const timed = (start,end,allDay=false) => ({start,end,time:start+'–'+end,title:'Event',allDay});
const schedule = context.scheduleEvents([timed('09:00','10:00'),timed('09:30','10:30'),timed('10:30','11:00'),timed('00:00','24:00',true)]);
assert.equal(schedule.length,3);
assert.deepEqual(Array.from(schedule,e=>[e.startMinute,e.endMinute,e.lane,e.lanes]),[[540,600,0,2],[570,630,1,2],[630,660,0,1]]);
const short = context.scheduleEvents([timed('09:00','09:05'),timed('09:10','09:15'),timed('23:55','24:00')]);
assert.equal(short[0].renderEnd,572);
assert.equal(short[0].lanes,2, 'short blocks must not overlap visually');
assert.equal(short[2].renderEnd,1467, 'last-minute events retain a tappable minimum height');
context.daySchedule = schedule;
context.openTimelineTap(90,1090);
assert.equal(context.activeDetailEvent.start,'09:00');
assert.equal(context.eventReturnScreen,'day');
context.closeEvent();
// Day arrows advance the pending target so rapid navigation cannot repeat a day.
context.requestedDayDate = new Date(2026,11,31,12);
context.loadDay = date => { context.requestedDayDate = date; };
context.shiftDay(1);
assert.equal(context.requestedDayDate.getFullYear(),2027);
assert.equal(context.requestedDayDate.getDate(),1);
context.shiftDay(1);
assert.equal(context.requestedDayDate.getDate(),2);
// Preferences default to a fixed 7 am–9 pm grid; 12-hour formatting handles noon/midnight.
context.displayPrefs = {time_format:'12h',day_scroll:false,day_start:420,day_end:1260};
assert.equal(context.formatTime('00:00'),'12:00 am');
assert.equal(context.formatTime('12:00'),'12:00 pm');
assert.equal(context.formatTime('21:00'),'9:00 pm');
assert.equal(context.formatTime('24:00'),'12:00 am');
const fixed=context.dayGeometry();
assert.equal(fixed.start,420);assert.equal(fixed.end,1260);
assert.equal(fixed.scale*(fixed.end-fixed.start),context.dayList.height-24);
const bounded=context.scheduleEvents([timed('06:00','08:00'),timed('05:00','06:00'),timed('20:00','22:00'),timed('21:00','22:00')]);
assert.equal(bounded.length,2);
assert.equal(bounded[0].viewStart,420);
assert.equal(bounded[1].renderEnd,1260);
assert.ok(bounded.every(e=>e.viewStart>=420 && e.renderEnd<=1260));
context.daySchedule=bounded;
context.openTimelineTap(90,(450-420)*fixed.scale);
assert.equal(context.activeDetailEvent.start,'06:00','fixed-grid hit testing must use clipped/scaled positions');

context.displayPrefs.time_format='24h';
assert.equal(context.formatTime('21:00'),'21:00');
// Toolbar Day view chooses today only for the currently displayed week.
context.monday=date=>{ const d=new Date(date);d.setDate(d.getDate()-((d.getDay()+6)%7));d.setHours(12,0,0,0);return d; };
context.displayedDate=new Date(2026,9,26,12);
context.todayDate=new Date(2026,9,28,12);
let opened=-1;context.openDay=offset=>{opened=offset;};
context.openToolbarDay();assert.equal(opened,2);
context.displayedDate=new Date(2026,10,2,12);
context.openToolbarDay();assert.equal(opened,0);
// New-event defaults respect the last successful calendar, with safe fallbacks.
const choices=[{id:'work'},{id:'personal'}];
assert.equal(context.preferredCalendar('personal',choices),'personal');
assert.equal(context.preferredCalendar('local',choices),'local');
assert.equal(context.preferredCalendar('removed-calendar',choices),'work');
assert.equal(context.preferredCalendar(null,[]),'local');
// Dismiss both the custom keyboard state and the native input method/focus.
let committed=0,hidden=0,focused=0;
context.Qt.inputMethod={commit(){committed++;},hide(){hidden++;}};
context.keyboardInput={focus:true};context.editField='title';
context.root.forceActiveFocus=()=>{focused++;};
context.hideEditKeyboard();
assert.equal(context.editField,'');assert.equal(context.keyboardInput.focus,false);
assert.equal(committed,1);assert.equal(hidden,1);assert.equal(focused,1);
console.log('PASS: weekly packing, hourly schedule/overlap lanes, metadata, day hit tests, return navigation and date boundaries');
