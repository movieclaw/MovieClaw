import fs from "node:fs";
import path from "node:path";
import ts from "../../apps/web/node_modules/typescript/lib/typescript.js";

const root = path.resolve(import.meta.dirname, "../..");
const result = {};
function scan(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) scan(file);
    else if (/\.tsx?$/.test(entry.name)) {
      const text = fs.readFileSync(file, "utf8");
      const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
      let count = 0;
      function visit(node) {
        if ((ts.isStringLiteralLike(node) || ts.isJsxText(node) ||
             ts.isTemplateHead(node) || ts.isTemplateMiddle(node) || ts.isTemplateTail(node)) &&
            /\p{Script=Han}/u.test(node.text)) {
          const line = source.getLineAndCharacterOfPosition(node.getStart(source)).line;
          const lines = text.split("\n");
          if (![lines[line], lines[line - 1] ?? ""].some((s) => s.includes("i18n-ignore"))) count++;
        }
        ts.forEachChild(node, visit);
      }
      visit(source);
      if (count) result[path.relative(root, file)] = count;
    }
  }
}
for (const directory of ["app", "components", "lib", "themes", "theme-sdk"]) {
  scan(path.join(root, "apps/web", directory));
}
scan(path.join(root, "plugins/netflix/src"));
process.stdout.write(JSON.stringify(result));
