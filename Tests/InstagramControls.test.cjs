// Offline DOM fixtures only. Never opens a browser, accesses accounts or sends real messages.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Resources/instagram-controls.js','utf8');
let passed = 0;
function fixture() {
  const body = {};
  class Element {
    constructor(tag, attrs={}, text='') {
      this.tagName=tag; this.attrs=attrs; this.innerText=text; this.isConnected=true; this.disabled=false;
      this.isContentEditable=attrs.contenteditable==='true'; this.children=[]; this.clicks=0; this._value='';
      this.href=attrs.href || ''; this.parentElement=body;
    }
    getAttribute(k) { return this.attrs[k] ?? null; }
    getBoundingClientRect() { return {width:80,height:25,left:20,top:20,bottom:45,right:100}; }
    contains(el) { return el===this || this.children.includes(el); }
    querySelector() { return null; }
    querySelectorAll(s) {
      if(s.startsWith('a[aria-label')) return this.children.filter(e=>e.tagName==='A' && e.attrs['aria-label']?.startsWith('Open the profile page of '));
      if(s==='button,[role="button"]') return this.children.filter(e=>e.tagName==='BUTTON');
      return [];
    }
    focus() { context.focused=this; }
    dispatchEvent() {}
    click() { this.clicks++; if(this===send) editor.innerText=''; }
  }
  class Input extends Element { get value(){return this._value;} set value(v){this._value=v;} }
  const search = new Element('A',{'aria-label':'Search',href:'https://www.instagram.com/explore/'});
  const field = new Input('INPUT',{'aria-label':'Search input'});
  const header = new Element('A',{'aria-label':'Open the profile page of demo.person',href:'https://www.instagram.com/demo.person/'},'Demo');
  const profile = new Element('A',{href:'https://www.instagram.com/demo.person/'},'demo.person Demo Person');
  const editor = new Element('DIV',{contenteditable:'true',role:'textbox','aria-placeholder':'Message...'});
  const send = new Element('BUTTON',{},'Send');
  const message = new Element('BUTTON',{},'Message');
  const chat = new Element('DIV');
  chat.children=[header,editor,send]; editor.parentElement=chat; send.parentElement=chat;
  const heading = new Element('H2',{},'demo.person');
  const context = {location:{protocol:'https:',hostname:'www.instagram.com',href:'https://www.instagram.com/demo.person/',pathname:'/demo.person/'},
    innerHeight:900,innerWidth:1400,getComputedStyle:()=>({visibility:'visible',display:'block'}),URL,Date,Event:class{},HTMLInputElement:Input,HTMLTextAreaElement:Input,
    crypto:{randomUUID:()=>String(Math.random())},window:{},focused:null,hit:null};
  context.document={body,querySelectorAll:s=>s==='a,button,[role="button"],input'?[search,field,profile,message,send]:s==='h1,h2'?[heading]:[editor],
    elementFromPoint:()=>context.hit,execCommand:(_command,_ui,text)=>{context.focused.innerText=text;return true}};
  vm.createContext(context); vm.runInContext(source,context);
  const snapshot=()=>context.jarvisInstagram({mode:'snapshot'});
  const act=(page,kind,extra={})=>{
    const c=page.controls.find(c=>c.kind===kind);
    context.hit=context.window.__jarvisInstagram.nodes[c.id];
    return context.jarvisInstagram({mode:'action',nonce:page.nonce,url:page.url,id:c.id,operation:['composer','searchField'].includes(kind)?'fill':'click',recipient:'demo.person',...extra});
  };
  return {context,editor,send,search,field,header,message,snapshot,act};
}
function test(name,fn){fn();passed++;console.log('PASS: '+name);}
test('search input receives literal user text',()=>{const f=fixture();f.act(f.snapshot(),'searchField',{text:'Demo Person'});assert.equal(f.field.value,'Demo Person');});
test('draft is bound to the observed conversation header',()=>{const f=fixture();f.act(f.snapshot(),'composer',{text:'Hello'});assert.equal(f.editor.innerText,'Hello');assert.equal(f.send.clicks,0);});
test('existing draft is never overwritten',()=>{const f=fixture();f.editor.innerText='my own draft';assert.throws(()=>f.act(f.snapshot(),'composer',{text:'New'}));assert.equal(f.editor.innerText,'my own draft');});
test('send requires explicit send intent',()=>{const f=fixture();f.editor.innerText='Hi';assert.throws(()=>f.act(f.snapshot(),'send',{text:'Hi'}));assert.equal(f.send.clicks,0);});
test('send verifies exact draft and recipient',()=>{const f=fixture();f.editor.innerText='Hi';f.act(f.snapshot(),'send',{text:'Hi',allowSend:true});assert.equal(f.send.clicks,1);assert.equal(f.editor.innerText,'');});
test('a consumed send cannot run twice',()=>{const f=fixture();f.editor.innerText='Hi';const page=f.snapshot();f.act(page,'send',{text:'Hi',allowSend:true});assert.throws(()=>f.act(page,'send',{text:'Hi',allowSend:true}));assert.equal(f.send.clicks,1);});
test('modified draft prevents sending',()=>{const f=fixture();f.editor.innerText='Changed';assert.throws(()=>f.act(f.snapshot(),'send',{text:'Hi',allowSend:true}));assert.equal(f.send.clicks,0);});
test('recipient mismatch prevents sending',()=>{const f=fixture();f.editor.innerText='Hi';assert.throws(()=>f.act(f.snapshot(),'send',{text:'Hi',recipient:'someone.else',allowSend:true}));assert.equal(f.send.clicks,0);});
test('changed live recipient header prevents sending',()=>{const f=fixture();f.editor.innerText='Hi';const page=f.snapshot();f.header.href='https://www.instagram.com/someone.else/';assert.throws(()=>f.act(page,'send',{text:'Hi',allowSend:true}));assert.equal(f.send.clicks,0);});
test('navigation invalidates observed controls',()=>{const f=fixture();const page=f.snapshot();f.context.location.href='https://www.instagram.com/other/';assert.throws(()=>f.act(page,'message'));});
test('offsite pages are rejected',()=>{const f=fixture();f.context.location.hostname='evil.test';assert.throws(()=>f.snapshot());});
test('covered controls are rejected',()=>{const f=fixture();const page=f.snapshot();const c=page.controls.find(c=>c.kind==='send');f.context.hit={};assert.throws(()=>f.context.jarvisInstagram({mode:'action',nonce:page.nonce,url:page.url,id:c.id,operation:'click',recipient:'demo.person',text:'',allowSend:true}));assert.equal(f.send.clicks,0);});
test('fresh observation invalidates older decisions',()=>{const f=fixture();const page=f.snapshot();f.snapshot();assert.throws(()=>f.act(page,'search'));});
console.log('Passed '+passed+' offline Instagram browser-control checks.');
