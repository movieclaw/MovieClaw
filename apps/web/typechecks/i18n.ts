// Compiled by web:typecheck: a missing augmentation would make expect-error fail.
import { createTranslator } from "next-intl";
import { zhHans } from "../lib/i18n/messages";
const t = createTranslator({ locale: "zh-Hans", messages: zhHans });
t("auth.login.action");
// @ts-expect-error Unknown semantic keys must fail at compile time.
t("auth.login.missingKey");
