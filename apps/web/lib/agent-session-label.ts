import type { SessionLabelRef } from "./api/agent";
import { parseSkillTokens } from "./agent-skills";
import { appTranslator, type AppMessageKey } from "./i18n/translate";
import type { AppLocale } from "./i18n/negotiate";

const LABEL_KEYS = new Set([
  "agent.session.continued", "agent.session.skill", "agent.session.skillOnly",
  "agent.session.image", "agent.session.images", "agent.session.defaultInstruction",
]);

export function sessionLabel(text: string, ref: SessionLabelRef | null | undefined, locale: AppLocale): string {
  if (!ref || !LABEL_KEYS.has(ref.message_key)) return text;
  const params = Object.fromEntries(Object.entries(ref.params ?? {}).map(([key, value]) => [
    key, typeof value === "object" ? sessionLabel(value.message ?? "", value, locale) : value,
  ]));
  return appTranslator(locale)(ref.message_key as AppMessageKey, params).trim().slice(0, 80);
}

export function optimisticSessionLabel(input: string, imageCount = 0): {title: string; titleRef?: SessionLabelRef} {
  const { names, text } = parseSkillTokens(input);
  if (names.length) return {
    title: appTranslator("zh-Hans")(text ? "agent.session.skill" : "agent.session.skillOnly", {text}).trim().slice(0, 30),
    titleRef: text ? {message_key: "agent.session.skill", params: {text: text.slice(0, 25)}} : {message_key: "agent.session.skillOnly"},
  };
  if (!input && imageCount) return {
    title: appTranslator("zh-Hans")(imageCount === 1 ? "agent.session.image" : "agent.session.images", {count: imageCount}),
    titleRef: imageCount === 1 ? {message_key:"agent.session.image"} : {message_key:"agent.session.images",params:{count:imageCount}},
  };
  return {title: input.slice(0, 30), titleRef: undefined};
}
