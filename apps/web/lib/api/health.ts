import { request } from "@/lib/http";

export interface HealthResponse {
  status: string;
  service: string;
  environment: string;
  /** 服务器应用版本。旧响应可能没有这个字段。 */
  version?: string | null;
}

export function getHealth(init?: RequestInit): Promise<HealthResponse> {
  return request<HealthResponse>("/health", init);
}
