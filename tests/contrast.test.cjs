const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const css = fs.readFileSync('src/app/styles.css','utf8');
const blocks = [...css.matchAll(/:root\s*\{([^}]+)\}/g)];
const palettes = blocks.map(block => Object.fromEntries([...block[1].matchAll(/--([\w-]+):\s*(#[\da-f]+);/gi)].map(m => [m[1],m[2]])));
function luminance(hex) {
 const normalized = hex.length === 4 ? [...hex.slice(1)].map(c=>c+c).join('') : hex.slice(1);
 const rgb = [0,2,4].map(i => parseInt(normalized.slice(i,i+2),16)/255).map(v => v<=0.04045?v/12.92:((v+0.055)/1.055)**2.4);
 return rgb[0]*0.2126+rgb[1]*0.7152+rgb[2]*0.0722;
}
function contrast(a,b) { const values=[luminance(a),luminance(b)].sort((x,y)=>y-x); return (values[0]+0.05)/(values[1]+0.05); }
for(const [i,palette] of palettes.entries()) test(`${i===0?'light':'dark'} palette meets normal text contrast for semantic colors`,()=>{
 for(const [text,bg] of [['ink','surface'],['muted','surface'],['muted','paper'],['brand-hover','brand-soft'],['success-ink','success-bg'],['warning-ink','warning-bg'],['error-ink','error-bg']]) {
  assert.ok(contrast(palette[text],palette[bg])>=4.5,`${text} on ${bg} falls below 4.5:1`);
 }
});
test('primary action label meets normal text contrast',()=>assert.ok(contrast('#ffffff','#0062ff')>=4.5));
