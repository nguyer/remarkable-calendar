const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const qml=fs.readFileSync('qml/GoogleConnect.qml','utf8');
const code=qml.slice(qml.indexOf('    function show()'), qml.indexOf('    Timer {'));
function fixture() {
 const requests=[];
 class XHR {
  static DONE=4;
  constructor(){this.headers={};requests.push(this)}
  open(method,url){this.method=method;this.url=url}
  setRequestHeader(k,v){this.headers[k]=v}
  send(body){this.body=body}
  abort(){this.aborted=true}
  reply(value,status=200){this.raw(JSON.stringify(value),status)}
  raw(text,status=200){this.responseText=text;this.status=status;this.readyState=4;this.onreadystatechange()}
 }
 const timer={restart(){},stop(){}};
 const ctx={opened:false,status:{state:'idle'},request:null,serial:0,busy:false,errorMessage:'',startup:true,
  startupRetry:timer,connectionPoll:timer,deadline:timer,XMLHttpRequest:XHR};
 ctx.page=ctx;vm.createContext(ctx);vm.runInContext(code,ctx);return {ctx,requests};
}
{
 const {ctx,requests}=fixture();ctx.call('',true);
 assert.equal(requests[0].url,'http://127.0.0.1:38765/google/connect');
 assert.equal(requests[0].headers['X-RemarkableCalendar-Request'],'sync');
 requests[0].reply({state:'idle',connected:false});assert.equal(ctx.opened,true);assert.equal(ctx.startup,false);
 ctx.call('start',false);assert.equal(JSON.parse(requests[1].body).action,'start');
 requests[1].reply({state:'pending',connected:false,user_code:'123456',qr:['111','101','111']});
 const previous=ctx.status;ctx.call('',false);requests[2].reply(previous);assert.equal(ctx.status,previous);
 ctx.call('',false);const stale=requests[3];ctx.close();assert.equal(stale.aborted,true);
 stale.reply({state:'confirm',connected:false,email:'stale@example.test'});assert.equal(ctx.opened,false);
 assert.equal(JSON.parse(requests[4].body).action,'cancel');
}
{
 const {ctx,requests}=fixture();ctx.call('',true);requests[0].reply({state:'idle',connected:true});
 assert.equal(ctx.opened,false);ctx.show();requests[1].reply({error:'Finish sync first'},409);
 assert.equal(ctx.errorMessage,'Finish sync first');assert.equal(ctx.busy,false);
}
console.log('PASS: Google onboarding startup, guarded requests, stable QR model, cancellation, stale responses, and errors');

for (const [text,status,expected] of [
 ['',0,/Cannot reach the Calendar backend/],
 ['',200,/empty sign-in response.*HTTP 200/],
 ['not found',404,/running Calendar backend does not support/],
 ['<html>method not allowed</html>',405,/running Calendar backend does not support/],
 ['<html>proxy error</html>',502,/unreadable sign-in response.*HTTP 502/],
 ['{broken',200,/unreadable sign-in response/],
 ['null',200,/invalid sign-in response/],
 ['[]',200,/invalid sign-in response/],
 ['{"ok":true}',200,/unexpected sign-in response/],
 ['{"error":"Finish sync first"}',409,/Finish sync first/],
 ['{"state":"idle","connected":true,"error":"Sync or discard pending Google edits before replacing the connection"}',200,/pending Google edits/],
]) {
 const {ctx,requests}=fixture();ctx.show();requests[0].raw(text,status);
 assert.match(ctx.errorMessage,expected);
 assert.doesNotMatch(ctx.errorMessage,/SyntaxError|JSON.parse/);
 assert.equal(ctx.busy,false);
 assert.equal(ctx.status.state,'idle');
}
console.log('PASS: Google onboarding handles unavailable, old, empty, malformed, and non-JSON backend responses');
