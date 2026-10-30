const fs=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const source=fs.readFileSync('qml/MonthEventsCanvas.qml','utf8');
let measurements=0;
const text=[];const bars=[];const clips=[];
const ctx={font:'600 20px sans-serif',fillStyle:'',
    reset(){},clearRect(){},save(){},restore(){},beginPath(){},clip(){},
    rect(...args){clips.push(args);},
    measureText(value){measurements++;return {width:Array.from(value).length*10};},
    fillRect(...args){bars.push({args,color:this.fillStyle});},
    fillText(value,x,y){text.push({value,x,y});}
};
const c={Date,console:{warn(){}},lineCache:{},lineCacheCount:0,width:764,height:600,weekWidth:64,rowCount:6,
    gridStart:new Date(2026,9,26,12),layouts:{},
    app:{monthFontMetrics:{height:24,font:{family:'sans-serif'}},monthLoadMs:20,monthLayoutMs:2,
        isoDate(d){return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;}}};
vm.createContext(c);
vm.runInContext(source.slice(source.indexOf('    function fitPrefix('),source.indexOf('    onPaint:')),c);
assert.equal(c.elideTitle(ctx,'Short',100),'Short');
assert.equal(c.elideTitle(ctx,'Longer title',70),'Longer…');
assert.equal(c.elideTitle(ctx,'Long',5),'');
assert.deepEqual(Array.from(c.titleLines(ctx,'One two three four five',100,2)),['One two','three fou…']);
assert.deepEqual(Array.from(c.titleLines(ctx,'First\nSecond',100,2)),['First','Second']);
assert.deepEqual(Array.from(c.titleLines(ctx,'LongUnbrokenWord',50,2)),['LongU','nbro…']);
const count=measurements;c.titleLines(ctx,'First\nSecond',100,2);assert.equal(measurements,count,'reuse already wrapped titles');
// Paint two days, including one overflow count, without instantiating event delegates.
c.height=960;
c.layouts={'2026-10-26':{entries:[{title:'One two three four five',color:'#123456',height:48,y:0}],hidden:2},
'2026-10-27':{entries:[{title:'Short',color:'#654321',height:24,y:0}],hidden:0}};
c.paintEvents(ctx);
assert.equal(bars.length,2);assert.equal(bars[0].color,'#123456');assert.equal(bars[1].args[0],172);
assert.ok(text.some(t=>t.value==='+2 more'));
assert.ok(text.filter(t=>t.value!=='+2 more').every(t=>t.y>=72 && t.y<128));
assert.ok(clips.every(r=>r[1]===72 && r[3]===80),'clip event ink inside the available day area');
assert.ok(c.app.monthPerformance.includes('Canvas'));assert.ok(c.app.monthPerformance.includes('2 previews'));
console.log('PASS: canvas wrapping, ellipsis, explicit line breaks, cached lines, colors, overflow, and cell bounds');
