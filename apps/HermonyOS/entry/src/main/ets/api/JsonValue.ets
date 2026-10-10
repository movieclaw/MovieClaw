/**
 * 任意 JSON 值（对应 iOS 端 Core/API/JSONValue.swift 的 `API.JSONValue`）。
 * 生成模型遇到无法静态表达的类型（多类型联合、任意对象）时落到这里，
 * 使用方按需用下面的取值函数判类型后取值。
 *
 * 说明：ArkTS 不允许类型别名直接递归引用，这里用命名接口（JsonList/JsonMap）
 * 承载递归；运行期它们就是普通数组和对象，JSON.parse 后的 as 转换不受影响。
 */
export interface JsonList extends Array<JsonValue> { }

export interface JsonMap extends Record<string, JsonValue> { }

export type JsonValue = boolean | number | string | JsonList | JsonMap | null;

/** 取字符串值（对应 iOS 端 JSONValue.stringValue） */
export function jsonStringValue(value: JsonValue | undefined | null): string | null {
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  return null;
}

/** 取整数值（对应 iOS 端 JSONValue.intValue） */
export function jsonIntValue(value: JsonValue | undefined | null): number | null {
  if (typeof value === 'number') {
    return Math.trunc(value);
  }
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isNaN(parsed) ? null : Math.trunc(parsed);
  }
  return null;
}

/** 取浮点值（对应 iOS 端 JSONValue.doubleValue） */
export function jsonDoubleValue(value: JsonValue | undefined | null): number | null {
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number(value);
    return Number.isNaN(parsed) ? null : parsed;
  }
  return null;
}

/** 取布尔值（对应 iOS 端 JSONValue.boolValue） */
export function jsonBoolValue(value: JsonValue | undefined | null): boolean | null {
  if (typeof value === 'boolean') {
    return value;
  }
  return null;
}

/** 取数组值（对应 iOS 端 JSONValue.arrayValue） */
export function jsonArrayValue(value: JsonValue | undefined | null): JsonList | null {
  if (Array.isArray(value)) {
    return value as JsonList;
  }
  return null;
}

/** 取对象值（对应 iOS 端 JSONValue.objectValue） */
export function jsonObjectValue(value: JsonValue | undefined | null): JsonMap | null {
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    return value as JsonMap;
  }
  return null;
}

/** 对象下标取值（对应 iOS 端 JSONValue 的 subscript(key:)），没有该键返回 null */
export function jsonGet(value: JsonValue | undefined | null, key: string): JsonValue | null {
  const map = jsonObjectValue(value);
  if (map === null) {
    return null;
  }
  const item = map[key];
  return item === undefined ? null : item;
}

/** 数组下标取值（对应 iOS 端 JSONValue 的 subscript(index:)），越界返回 null */
export function jsonAt(value: JsonValue | undefined | null, index: number): JsonValue | null {
  const list = jsonArrayValue(value);
  if (list === null || index < 0 || index >= list.length) {
    return null;
  }
  return list[index];
}
