import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";
import ts from "typescript";
import { appTranslator } from "../lib/i18n/translate.ts";

function load(path, dependencies = {}) {
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const exports = {};
  const compiled = ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInNewContext(compiled, {exports, require:name=>dependencies[name] ?? {}});
  return exports;
}
const skills = load("../lib/agent-skills.ts");
const {sessionLabel, optimisticSessionLabel} = load("../lib/agent-session-label.ts", {
  "./agent-skills":skills, "./i18n/translate":{appTranslator},
});

test("automatic title references follow each reader and keep user text raw", () => {
  const ref = {message_key:"agent.session.continued", params:{title:{message_key:"agent.session.image"}}};
  const before = structuredClone(ref);
  for (const [locale,expected] of [["en","Continued: [Image]"],["zh-Hans","续：[图片]"],["en","Continued: [Image]"]]) {
    assert.equal(sessionLabel("续：[图片]",ref,locale),expected);
    assert.equal(sessionLabel("续：用户标题",null,locale),"续：用户标题");
    assert.equal(sessionLabel("Raw unknown",{message_key:"plugin.future"},locale),"Raw unknown");
  }
  assert.deepEqual(ref,before);
  assert.equal(sessionLabel("raw",{message_key:"agent.session.continued",params:{title:"a".repeat(100)}},"en").length,80);
});

test("optimistic previews use skill and image facts and clear stale generated metadata", () => {
  for (const [input,count,zh,en] of [
    ["/skill:demo My text",0,"[技能] My text","[Skill] My text"],
    ["/skill:demo",0,"[技能]","[Skill]"],
    ["",1,"[图片]","[Image]"],
    ["",2,"[图片 ×2]","[Images ×2]"],
    ["[图片]",0,"[图片]","[图片]"],
    ["续：User title",0,"续：User title","续：User title"],
  ]) {
    const result = optimisticSessionLabel(input,count);
    assert.equal(result.title,zh);
    assert.equal(sessionLabel(result.title,result.titleRef,"zh-Hans"),zh);
    assert.equal(sessionLabel(result.title,result.titleRef,"en"),en);
  }
  const old = optimisticSessionLabel("",1);
  const replaced = {...old,...optimisticSessionLabel("Real user text")};
  assert.equal(replaced.titleRef,undefined);
  assert.equal(sessionLabel(replaced.title,replaced.titleRef,"en"),"Real user text");
});
