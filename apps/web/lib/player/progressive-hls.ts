/** FetchLoader 才请求半成品：hls.js 在不支持流式 Fetch 时自动保留 XHR。 */
export function partialSegmentRequest(
  context: { url: string },
  initParams: RequestInit,
): Request {
  const url = new URL(context.url, globalThis.location?.href);
  if (/\/seg\d{5}\.m4s$/.test(url.pathname)) url.searchParams.set("partial", "1");
  return new Request(url, initParams);
}

/** 转码器还在生产数据的响应，传输耗时不能代表线路带宽。 */
export function isPartialSegmentResponse(networkDetails: unknown): boolean {
  return (
    typeof Response !== "undefined" &&
    networkDetails instanceof Response &&
    networkDetails.headers.get("X-MovieClaw-Partial-Segment") === "1"
  );
}
