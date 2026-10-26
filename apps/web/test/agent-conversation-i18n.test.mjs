import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import ts from "typescript";
import {appTranslator} from "../lib/i18n/translate.ts";

function helpers(path, names) {
  const source = readFileSync(new URL(path, import.meta.url), "utf8");
  const tree = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const declarations = tree.statements.filter(node => ts.isFunctionDeclaration(node) && names.includes(node.name?.text));
  assert.equal(declarations.length, names.length);
  const compiled = ts.transpile(declarations.map(node => source.slice(node.getStart(tree), node.end)).join("\n"));
  return Function("appTranslator", compiled + `;return {${names.join(",")}};`)(appTranslator);
}
const {processSummary, processStatus, formatDuration} = helpers("../components/agent-conversation-view.tsx", ["processSummary", "processStatus", "formatDuration"]);
const {applyAgentEvent} = helpers("../lib/agent-conversations.tsx", ["applyAgentEvent"]);

test("process summaries handle zero, singular and combined counts without changing tool facts", () => {
  for (const [items, zh, en] of [
    [[], "处理过程", "Processing details"],
    [[{kind:"thinking", text:"原始思考"}], "已思考", "Reasoned"],
    [[{kind:"tool", name:"bash", id:"raw-id"}], "已执行 1 次命令", "Ran 1 command"],
    [[{kind:"tool", name:"search", id:"raw-id"}], "已调用 1 次工具", "Called 1 tool"],
    [[{kind:"thinking"},{kind:"tool",name:"bash"},{kind:"tool",name:"search"}], "已思考，执行 1 次命令，调用 1 次工具", "Reasoned; ran 1 command; called 1 tool"],
  ]) {
    const before = structuredClone(items);
    for (const locale of ["en", "zh-Hans", "en"]) assert.equal(processSummary(items, locale), locale === "en" ? en : zh);
    assert.deepEqual(items, before);
  }
  const many = Array.from({length:1200}, (_, id) => ({kind:"tool",name:"bash",id}));
  assert.equal(processSummary(many,"zh-Hans"), "已执行 1200 次命令");
  assert.equal(processSummary(many,"en"), "Ran 1,200 commands");
});

test("live process labels preserve the tool name and follow its actual phase", () => {
  const preparing = [{kind:"tool",name:"Raw 工具",argsDone:false}];
  assert.equal(processStatus(preparing,"en"), "Preparing to call Raw 工具…");
  assert.equal(processStatus(preparing,"zh-Hans"), "准备调用 Raw 工具…");
  assert.equal(processStatus([{kind:"tool",name:"bash"}],"en"), "Running bash…");
  assert.equal(processStatus([{kind:"tool",name:"bash",output:"raw"}],"en"), "Thinking…");
});

test("elapsed time keeps the original bounds and decimal policy in SSR", () => {
  assert.equal(formatDuration(-1,true,"en"), "0.0s");
  assert.equal(formatDuration(1250,true,"en"), "1.3s");
  assert.equal(formatDuration(61000,false,"en"), "1m 1s");
  assert.equal(formatDuration(61000,false,"zh-Hans"), "1 分 1 秒");
});

test("missing client errors store a reference while upstream errors remain raw", () => {
  const turn = {id:"turn",status:"running",segments:[]};
  const missing = applyAgentEvent(turn, {type:"agent_error"});
  assert.equal(turn.status, "running");
  assert.equal(missing.errorKey, "agent.conversation.runUnknown");
  assert.equal(appTranslator("en")(missing.errorKey), "The run failed with no reason.");
  assert.equal(appTranslator("zh-Hans")(missing.errorKey), "运行失败，原因未知");
  const supplied = applyAgentEvent(missing, {type:"agent_error",error:"原始上游错误"});
  assert.equal(supplied.error, "原始上游错误");
  assert.equal(supplied.errorKey, undefined);
});
