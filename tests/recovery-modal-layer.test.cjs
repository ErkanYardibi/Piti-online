const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../index.html'),'utf8');
const modalCode=html.slice(html.indexOf('function openModal(html)'),html.indexOf('function toast(t)'));
function setup(){
 const classes=new Set();
 const modal={innerHTML:'',querySelector(){return /id="(?:forgotEmail|recoveryPasswordModal)"/.test(this.innerHTML)?{}:null},querySelectorAll(){return []}};
 const modalBack={classList:{add(...names){names.forEach(n=>classes.add(n))},remove(...names){names.forEach(n=>classes.delete(n))},toggle(name,on){on?classes.add(name):classes.delete(name)}}};
 const ctx={modal,modalBack,activeChatRecorderCleanup:null};vm.createContext(ctx);vm.runInContext(modalCode,ctx);
 return {ctx,classes};
}
function layer(selector){const rule=html.match(new RegExp(selector.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'\\{([^}]+)\\}'));assert.ok(rule,selector);return Number(rule[1].match(/z-index:(\d+)/)[1])}
for(const id of ['forgotEmail','recoveryPasswordModal'])test(id+' opens above the login overlay and closes cleanly',()=>{
 const {ctx,classes}=setup();ctx.openModal(`<div id="${id}"></div>`);
 assert.ok(classes.has('show'));assert.ok(classes.has('authModal'));
 assert.ok(layer('.modalBack.authModal')>layer('.authBack'));
 ctx.closeModal();assert.ok(!classes.has('show'));assert.ok(!classes.has('authModal'));
});
test('ordinary dialogs do not retain the recovery layer',()=>{const {ctx,classes}=setup();ctx.openModal('<input id="forgotEmail">');ctx.openModal('<h3>Other dialog</h3>');assert.ok(!classes.has('authModal'));assert.ok(classes.has('show'))});
test('all inline JavaScript parses',()=>{for(const m of html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g))new vm.Script(m[1])});
