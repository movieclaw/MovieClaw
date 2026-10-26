import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";

function load(path, dependencies = {}, extra = "") {
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX}}).outputText + extra,
    {exports,require:name=>dependencies[name] ?? {},Map,Set});
  return exports;
}
const api = load("../lib/api/downloaders.ts",{
  "@/lib/i18n/translate":{appTranslator}, "@/lib/i18n/negotiate":{},
});
const {connectionFields,typeInfo} = load("../components/downloader-config-section.tsx",{
  "@/lib/i18n/translate":{appTranslator},
},"\nexports.connectionFields=connectionFields;exports.typeInfo=typeInfo;");

test("built-in fallback connection labels follow the explicit SSR locale without changing protocol facts",()=>{
  const original=JSON.stringify(api.BUILTIN_DOWNLOADER_TYPES);
  for(const locale of ["en","zh-Hans","en"]){
    const types=api.builtinDownloaderTypes(locale);
    assert.equal(types[0].url_label,locale==="en"?"WebUI URL":"WebUI 地址");
    assert.equal(types[1].url_label,locale==="en"?"RPC URL":"RPC 地址");
    assert.equal(types[1].type,"transmission");
    assert.equal(types[1].url_placeholder,"http://192.168.1.10:9091");
    const fields=connectionFields(types[0],locale);
    assert.equal(fields.username.label,locale==="en"?"Username (optional)":"用户名（可选）");
    assert.equal(fields.password.label,locale==="en"?"Password (optional)":"密码（可选）");
  }
  assert.equal(JSON.stringify(api.BUILTIN_DOWNLOADER_TYPES),original);
});

test("custom plugin titles and connection field requirements stay raw while optional annotations translate",()=>{
  const info={type:"Raw 插件",title:"Raw 插件",url_label:"Custom URL",connection:{
    required:["url","password"],properties:{url:{title:"Custom endpoint",examples:["https://fixture.invalid/rpc"]},password:{title:"Custom secret"}},
  }};
  const original=structuredClone(info);
  for(const locale of ["en","zh-Hans"]){
    const fields=connectionFields(info,locale);
    assert.equal(fields.url.label,"Custom endpoint");
    assert.equal(fields.username,null);
    assert.equal(fields.password.label,"Custom secret");
    assert.equal(typeInfo([info],info.type,locale),info);
    const missing=typeInfo([],info.type,locale);
    assert.equal(missing.type,info.type);assert.equal(missing.title,info.type);
    assert.equal(missing.url_label,locale==="en"?"URL":"地址");
  }
  assert.deepEqual(info,original);
});

test("downloader summaries and mapping counts are complete ICU sentences",()=>{
  const en=appTranslator("en"),zh=appTranslator("zh-Hans");
  assert.equal(en("download.config.summary",{count:1,usable:0}),"1 downloader, 0 available. Connections are tested automatically after saving.");
  assert.equal(en("download.config.summary",{count:2,usable:1}),"2 downloaders, 1 available. Connections are tested automatically after saving.");
  assert.equal(zh("download.config.summary",{count:1200,usable:100}),"共 1200 个，100 个可用。保存后系统会自动测试连接。");
  assert.equal(en("download.config.mappingCount",{count:1}),"1 mapping configured");
  assert.equal(en("download.config.mappingCount",{count:2}),"2 mappings configured");
});
