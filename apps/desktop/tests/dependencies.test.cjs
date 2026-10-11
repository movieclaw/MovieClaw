const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

function pe(dll) {
  const bytes=Buffer.alloc(0x800); bytes.write('MZ'); bytes.writeUInt32LE(0x80,0x3c); bytes.write('PE\0\0',0x80);
  bytes.writeUInt16LE(1,0x86); bytes.writeUInt16LE(240,0x94); bytes.writeUInt16LE(0x20b,0x98);
  bytes.writeUInt32LE(0x1000,0x98+112+8); bytes.writeUInt32LE(40,0x98+112+12);
  const section=0x98+240; bytes.writeUInt32LE(0x400,section+8); bytes.writeUInt32LE(0x1000,section+12);
  bytes.writeUInt32LE(0x400,section+16); bytes.writeUInt32LE(0x400,section+20);
  bytes.writeUInt32LE(0x1040,0x400+12); bytes.write(dll+'\0',0x440); return bytes;
}

test('clean-device import audit accepts bundled loaders and rejects developer-only CRT dependencies', t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'movieclaw-deps-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  fs.mkdirSync(path.join(dir,'mpv'));
  fs.writeFileSync(path.join(dir,'movieclaw-desktop.exe'),pe('KERNEL32.dll'));
  fs.writeFileSync(path.join(dir,'mpv','mpv.exe'),pe('vulkan-1.dll'));
  const run=()=>spawnSync(process.platform==='win32'?'python':'python3',[path.resolve(__dirname,'../scripts/audit-dependencies.py'),'--package',dir,'--output',path.join(dir,'imports.json')],{encoding:'utf8'});
  assert.notEqual(run().status,0);
  fs.writeFileSync(path.join(dir,'mpv','vulkan-1.dll'),pe('api-ms-win-crt-runtime-l1-1-0.dll'));
  assert.equal(run().status,0);
  const imports=JSON.parse(fs.readFileSync(path.join(dir,'imports.json'),'utf8'));
  assert.deepEqual(imports['movieclaw-desktop.exe'],['kernel32.dll']);
  fs.writeFileSync(path.join(dir,'movieclaw-desktop.exe'),pe('VCRUNTIME140.dll'));
  assert.notEqual(run().status,0);
  fs.writeFileSync(path.join(dir,'movieclaw-desktop.exe'),Buffer.from('broken executable'));
  assert.notEqual(run().status,0);
});
