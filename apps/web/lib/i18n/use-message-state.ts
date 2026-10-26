"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import type { AppMessageKey } from "./translate";

export type Message = string | {
  key: AppMessageKey;
  values?: Record<string, string | number | Date>;
};

/** Keep validation references in state so changing language also updates visible errors. */
export function useMessageState() {
  const t = useTranslations();
  const [message, setMessage] = useState<Message | null>(null);
  return [typeof message === "object" && message !== null
    ? t(message.key, message.values)
    : message, setMessage] as const;
}
