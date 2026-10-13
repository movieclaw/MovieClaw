const test = require('node:test');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const script = path.resolve(__dirname, '../scripts/check-release-evidence.py');
const checks = ['embedded_render','first_frame_seek','hardware_decode','hdr_sdr','audio_passthrough','dpi_multimonitor','power_media_keys','window_restore','resume_twenty_cycles','windows_macos_performance'];
function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'movieclaw-release-gate-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  const version='0.2.112', revision='a'.repeat(40);
  const files=['Setup-x64.exe','portable-x64.zip'].map((suffix) => {
    const name=`MovieClaw-Windows-${version}-${suffix}`, bytes=Buffer.from(`fixture ${suffix}`);
    fs.writeFileSync(path.join(directory, name),bytes);
    return {name,size:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')};
  });
  const manifest={version,sourceRevision:revision,files,signatures:{installer:{status:'Valid',thumbprint:'fixture'},application:{status:'Valid',thumbprint:'fixture'}}};
  const evidence={schema_version:1,scope:'physical-windows-and-macos',revision,version,windows:{machine_id:'test-fixture',os:'Windows',gpu:'fixture',driver:'fixture'},macos:{machine_id:'test-fixture',os:'macOS',model:'fixture'},artifact_sha256:Object.fromEntries(files.map(f=>[f.name,f.sha256])),checks:Object.fromEntries(checks.map(name=>[name,{status:'passed',evidence_url:'https://example.test/fixture-evidence'}]))};
  function run(extra=[]) {
    fs.writeFileSync(path.join(directory,'release-manifest.json'),JSON.stringify(manifest));
    const response=spawnSync(process.platform==='win32'?'python':'python3',[script,'--directory',directory,'--revision',revision,'--version',version,...extra],{encoding:'utf8',env:{...process.env,DESKTOP_HARDWARE_ACCEPTANCE_JSON:JSON.stringify(evidence)}});
    assert.ifError(response.error); return response;
  }
  return {run,evidence,manifest,directory};
}
test('stable gate accepts complete synthetic contract fixture only',t=> { const f=fixture(t); assert.equal(f.run().status,0); });
test('hosted VM and pending physical acceptance cannot publish stable',t=> { const f=fixture(t); f.evidence.scope='windows-hosted-ci-smoke'; assert.notEqual(f.run().status,0); f.evidence.scope='physical-windows-and-macos'; f.evidence.checks.hdr_sdr.status='pending'; assert.notEqual(f.run().status,0); });
test('unsigned, different revision and mutated artifacts cannot publish stable',t=> { const f=fixture(t); f.manifest.signatures.installer.status='NotSigned'; assert.notEqual(f.run().status,0); f.manifest.signatures.installer.status='Valid'; f.evidence.revision='b'.repeat(40); assert.notEqual(f.run().status,0); f.evidence.revision=f.manifest.sourceRevision; fs.appendFileSync(path.join(f.directory,f.manifest.files[0].name),'mutated'); assert.notEqual(f.run().status,0); });

test('explicit CI publication verifies unsigned bytes and rejects missing disclosure, invalid signatures and fake hardware claims',t=> {
  const f=fixture(t), notes=path.join(f.directory,'notes.md');
  const args=['--policy','ci-verified','--notes',notes];
  f.manifest.scope='windows-hosted-ci-smoke'; f.manifest.physicalValidated=false;
  f.manifest.signatures.installer.status='NotSigned'; f.manifest.signatures.application.status='NotSigned';
  fs.writeFileSync(notes,'unsigned packages; physical acceptance pending');
  assert.notEqual(f.run(args).status,0);
  fs.writeFileSync(notes,'<!-- desktop-release-policy: ci-verified -->\nUnsigned; physical acceptance pending.');
  assert.equal(f.run(args).status,0);
  f.manifest.signatures.installer.status='HashMismatch'; assert.notEqual(f.run(args).status,0);
  f.manifest.signatures.installer.status='NotSigned'; f.manifest.physicalValidated=true; assert.notEqual(f.run(args).status,0);
  f.manifest.physicalValidated=false; f.manifest.sourceRevision='b'.repeat(40); assert.notEqual(f.run(args).status,0);
  f.manifest.sourceRevision='a'.repeat(40); fs.appendFileSync(path.join(f.directory,f.manifest.files[0].name),'mutated'); assert.notEqual(f.run(args).status,0);
});

test('build labeling preserves the tested installer, keeps legacy update checksums and rejects archive mutation', t => {
  const f=fixture(t), manifestPath=path.join(f.directory,'release-manifest.json');
  fs.writeFileSync(manifestPath,JSON.stringify(f.manifest));
  const labeling=path.resolve(__dirname,'../scripts/label-packages.py');
  const python=process.platform==='win32'?'python':'python3';
  const label=spawnSync(python,[labeling,'--directory',f.directory,'--build-number','61.1'],{encoding:'utf8'});
  assert.equal(label.status,0,label.stderr);
  Object.assign(f.manifest,JSON.parse(fs.readFileSync(manifestPath,'utf8')));
  assert.equal(f.manifest.buildNumber,'61.1');
  assert.equal(f.manifest.sourceRevision,'a'.repeat(40));
  const localName='MovieClaw-Windows-0.2.112(61.1)-Setup-x64.exe';
  assert.deepEqual(fs.readFileSync(path.join(f.directory,'labeled',localName)),fs.readFileSync(path.join(f.directory,f.manifest.files[0].name)));
  const sums=fs.readFileSync(path.join(f.directory,'SHA256SUMS.txt'),'utf8');
  for (const item of [...f.manifest.files,...f.manifest.buildArtifacts]) assert.ok(sums.includes(`${item.sha256}  ${item.name}`));
  assert.equal(f.run().status,0);
  fs.appendFileSync(path.join(f.directory,f.manifest.buildArtifacts[0].name),'mutated');
  assert.notEqual(f.run().status,0);
});

test('invalid build labels and changed originals cannot create a labeled installer', t => {
  const f=fixture(t);fs.writeFileSync(path.join(f.directory,'release-manifest.json'),JSON.stringify(f.manifest));
  const labeling=path.resolve(__dirname,'../scripts/label-packages.py');
  const run=number=>spawnSync(process.platform==='win32'?'python':'python3',[labeling,'--directory',f.directory,'--build-number',number],{encoding:'utf8'});
  for (const number of ['0.1','61.0','61','61.1/../../bad','61.1)']) assert.notEqual(run(number).status,0);
  fs.appendFileSync(path.join(f.directory,f.manifest.files[0].name),'changed');
  assert.notEqual(run('61.1').status,0);
  assert.equal(fs.existsSync(path.join(f.directory,'labeled')),false);
});
