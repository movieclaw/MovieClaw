import { parse, TYPE, type MessageFormatElement } from "@formatjs/icu-messageformat-parser";
import { printAST } from "@formatjs/icu-messageformat-parser/printer.js";

const latin = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
const accented = "åƀçðéƒğħîĵķļɱñöþǫŕšţûṽŵẋýžÅƁÇÐÉƑĞĦÎĴĶĻṀÑÖÞǪŔŠŢÛṼŴẊÝŽ";

export function pseudoMessage(message: string): string {
  function visit(nodes: MessageFormatElement[]): void {
    for (const node of nodes) {
      if (node.type === TYPE.literal && node.value.trim()) {
        node.value = `[${node.value.replace(/[a-z]/gi, (character) => accented[latin.indexOf(character)])} ${"·".repeat(Math.ceil(node.value.length / 3))}]`;
      } else if (node.type === TYPE.plural || node.type === TYPE.select) {
        for (const option of Object.values(node.options)) visit(option.value);
      } else if (node.type === TYPE.tag) visit(node.children);
    }
  }
  const ast = parse(message);
  visit(ast);
  return printAST(ast);
}

export function pseudoMessages<T extends Record<string, unknown>>(messages: T): T {
  return Object.fromEntries(Object.entries(messages).map(([key, value]) => [key,
    typeof value === "string" ? pseudoMessage(value) : pseudoMessages(value as Record<string, unknown>),
  ])) as T;
}

export function pseudoEnabled(mode: string | undefined, search: string): boolean {
  return mode === "development" && new URLSearchParams(search).get("locale") === "pseudo";
}
