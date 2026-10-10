"use client";

/**
 * 按 JSON Schema 子集画表单（docs/design/plugin-phase4.md §2）：插件只描述「要填什么」，界面由这里统一画。
 *
 * 认得的字段：开关、文本（可带候选值、多行、敏感）、整数、数字、字符串列表。遇到不认识的类型整张不画、
 * 提示刷新——部分渲染会漏掉必填项。值的真正校验在服务端（插件的配置模型），这里只做基本类型转换。
 */

import { Toggle } from "@/components/cloud-push-ui";
import { SETTINGS_INPUT_CLASS } from "@/components/settings-ui";
import type { ConfigSchema, SchemaField } from "@/lib/api/plugins";

const SCALARS = new Set(["boolean", "string", "integer", "number"]);

/** 字段的主类型与是否可空（``type: ["string", "null"]``） */
export function fieldType(field: SchemaField): {
  kind: string;
  nullable: boolean;
} {
  const types = Array.isArray(field.type) ? field.type : [field.type];
  const kinds = types.filter((t) => t !== "null");
  return {
    kind: kinds.length === 1 ? kinds[0] : "unknown",
    nullable: types.includes("null"),
  };
}

/** 这张表单里有没有不认识的字段（网页比服务端旧） */
export function unsupportedField(schema: ConfigSchema): string | null {
  for (const [name, field] of Object.entries(schema.properties)) {
    const { kind } = fieldType(field);
    const ok =
      SCALARS.has(kind) ||
      (kind === "array" &&
        fieldType(field.items ?? { type: "" }).kind === "string");
    if (!ok) return name;
  }
  return null;
}

/** 输入框里的文本 → 提交的值；空的可空字段提交 null */
export function parseValue(field: SchemaField, text: string): unknown {
  const { kind, nullable } = fieldType(field);
  if (kind === "array") {
    return text
      .split(/\n|,|，/)
      .map((s) => s.trim())
      .filter(Boolean);
  }
  if (text === "" && nullable) return null;
  if (kind === "integer" || kind === "number") {
    const n = Number(text);
    return text.trim() === "" || Number.isNaN(n) ? text : n;
  }
  return text;
}

export function SchemaForm({
  schema,
  values,
  secretsSet,
  disabled,
  onChange,
}: {
  schema: ConfigSchema;
  /** 当前编辑中的值；字符串列表在编辑中保持为原始文本 */
  values: Record<string, unknown>;
  secretsSet: readonly string[];
  disabled?: boolean;
  onChange: (name: string, value: unknown) => void;
}) {
  const required = new Set(schema.required ?? []);
  return (
    <div className="space-y-5">
      {Object.entries(schema.properties).map(([name, field]) => {
        const { kind } = fieldType(field);
        const label = field.title || name;
        const id = `schema-field-${name}`;
        const value = values[name];
        let control;
        if (kind === "boolean") {
          return (
            <div key={name} className="flex items-center justify-between gap-4">
              <FieldText
                id={id}
                label={label}
                description={field.description}
              />
              <Toggle
                checked={Boolean(value)}
                label={label}
                disabled={disabled}
                onChange={(next) => onChange(name, next)}
              />
            </div>
          );
        }
        if (field.enum) {
          control = (
            <select
              id={id}
              className={`${SETTINGS_INPUT_CLASS} w-full`}
              value={value == null ? "" : String(value)}
              disabled={disabled}
              onChange={(e) => onChange(name, e.target.value)}
            >
              {fieldType(field).nullable && (
                <option value="">（不设置）</option>
              )}
              {field.enum.map((option) => (
                <option key={option} value={option}>
                  {option}
                </option>
              ))}
            </select>
          );
        } else if (kind === "array" || field["x-multiline"]) {
          control = (
            <textarea
              id={id}
              rows={kind === "array" ? 3 : 4}
              className={`${SETTINGS_INPUT_CLASS} w-full resize-y`}
              placeholder={kind === "array" ? "每行一个" : undefined}
              value={value == null ? "" : String(value)}
              disabled={disabled}
              onChange={(e) => onChange(name, e.target.value)}
            />
          );
        } else {
          const secret = Boolean(field.writeOnly);
          control = (
            <input
              id={id}
              type={secret ? "password" : kind === "string" ? "text" : "number"}
              autoComplete={secret ? "new-password" : "off"}
              className={`${SETTINGS_INPUT_CLASS} w-full`}
              min={field.minimum}
              max={field.maximum}
              placeholder={
                secret
                  ? secretsSet.includes(name)
                    ? "已设置（留空不改）"
                    : "未设置"
                  : undefined
              }
              value={value == null ? "" : String(value)}
              disabled={disabled}
              onChange={(e) => onChange(name, e.target.value)}
            />
          );
        }
        return (
          <div key={name} className="space-y-1.5">
            <FieldText
              id={id}
              label={required.has(name) ? `${label} *` : label}
              description={field.description}
            />
            {control}
          </div>
        );
      })}
    </div>
  );
}

function FieldText({
  id,
  label,
  description,
}: {
  id: string;
  label: string;
  description?: string;
}) {
  return (
    <div className="min-w-0">
      <label htmlFor={id} className="text-sub font-medium text-[var(--text)]">
        {label}
      </label>
      {description && (
        <p className="mt-0.5 text-caption leading-5 text-[var(--text-faint)]">
          {description}
        </p>
      )}
    </div>
  );
}
