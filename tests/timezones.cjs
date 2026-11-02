const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const qml=fs.readFileSync('qml/TimezonePicker.qml','utf8');
const body=qml.slice(qml.indexOf('    function matchingZones('),qml.indexOf('    Timer {'));
const changes=[];
const context={zones:['America/Guatemala','America/New_York','Asia/Tokyo','UTC'],opened:true,
 app:{settingsDraft:{timezone:'UTC'},changeSetting(name,value){changes.push({name,value})}}};
vm.createContext(context);vm.runInContext(body,context);
const search=(q)=>Array.from(context.matchingZones(context.zones,q,'UTC'));
assert.deepEqual(search(''),['UTC','America/Guatemala','America/New_York','Asia/Tokyo']);
assert.deepEqual(search(' GUAT '),['America/Guatemala']);
assert.deepEqual(search('new york'),['America/New_York']);
assert.deepEqual(search('new_york'),['America/New_York']);
assert.deepEqual(search('not a place'),[]);
context.choose('unknown');assert.equal(changes.length,0);assert.equal(context.opened,true);
context.choose('America/Guatemala');assert.deepEqual(changes,[{name:'timezone',value:'America/Guatemala'}]);assert.equal(context.opened,false);
assert.equal(context.app.settingsDraft.timezone,'UTC'); // Selection uses the draft-change hook, not a direct save.
console.log('PASS: timezone search, current-first ordering, valid selection, and draft-only updates');
