import { request } from "@/lib/http";

interface ApiEnvelope<T> {
  success: boolean;
  code: string;
  message: string;
  data: T;
}

async function unwrap<T>(promise: Promise<ApiEnvelope<T>>): Promise<T> {
  return (await promise).data;
}

/** 设置页可选的搜索供应商。 */
export interface WebSearchProviderOption {
  id: string;
  label: string;
  signup_url: string;
  note: string;
}

/**
 * 网页搜索接入状态。接口不返回密钥明文，只有末四位 hint。
 * provider 为 null 表示没选供应商。
 */
export interface WebSearchConfig {
  provider: string | null;
  configured: boolean;
  key_hint: string;
  providers: WebSearchProviderOption[];
}

export interface WebSearchTestResult {
  ok: boolean;
  message: string;
  sample_title: string | null;
}

export function getWebSearchConfig(): Promise<WebSearchConfig> {
  return unwrap(request<ApiEnvelope<WebSearchConfig>>("/llm/web-search"));
}

/** 保存供应商。apiKey 留空表示沿用已保存的密钥（仅限同一家供应商）。 */
export function saveWebSearchConfig(
  provider: string,
  apiKey: string,
): Promise<WebSearchConfig> {
  return unwrap(
    request<ApiEnvelope<WebSearchConfig>>("/llm/web-search", {
      method: "PUT",
      body: JSON.stringify({
        provider,
        api_key: apiKey.trim() ? apiKey.trim() : null,
      }),
    }),
  );
}

export function clearWebSearchConfig(): Promise<WebSearchConfig> {
  return unwrap(
    request<ApiEnvelope<WebSearchConfig>>("/llm/web-search", { method: "DELETE" }),
  );
}

/** 测试密钥，不保存。apiKey 留空则测试服务器上已保存的那把。 */
export function testWebSearchConfig(
  provider: string,
  apiKey: string,
): Promise<WebSearchTestResult> {
  return unwrap(
    request<ApiEnvelope<WebSearchTestResult>>("/llm/web-search/test", {
      method: "POST",
      body: JSON.stringify({
        provider,
        api_key: apiKey.trim() ? apiKey.trim() : null,
      }),
    }),
  );
}
