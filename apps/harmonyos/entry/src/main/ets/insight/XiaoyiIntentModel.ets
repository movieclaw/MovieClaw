import { ContinuationTarget } from '../common/ContinuationBridge';

function readParamString(param: Record<string, Object> | undefined, keys: string[]): string {
  if (param === undefined) {
    return '';
  }
  for (const k of keys) {
    const raw: Object | undefined = param[k];
    if (raw !== undefined && raw !== null) {
      const text: string = `${raw}`.trim();
      if (text.length > 0) {
        return text;
      }
    }
  }
  return '';
}

/**
 * 纯函数：把小艺六大意图（严格对齐 `docs/design/harmonyos-xiaoyi.md` §4.1–4.3）
 * 翻译为统一路由中转载荷 `ContinuationTarget`，与 Ability / UI 解耦、支持宿主机单测。
 */
export function intentToContinuationTarget(
  name: string,
  param: Record<string, Object> | undefined
): ContinuationTarget {
  const title: string = readParamString(param, ['title', 'entityName', 'mediaTitle', 'name']);
  const keyword: string = readParamString(param, ['keyword', 'query', 'title', 'entityName']);

  if (name === 'ContinuePlay') {
    return new ContinuationTarget('continue_latest', '', 0, 0, 0, 0, 0, 0, 0, title, title);
  }
  if (name === 'PlayItem' || name === 'PlayVideo') {
    return new ContinuationTarget('play_by_title', '', 0, 0, 0, 0, 0, 0, 0, title, title);
  }
  if (name === 'SubscribeVoice') {
    return new ContinuationTarget('subscribe_voice', '', 0, 0, 0, 0, 0, 0, 0, title, title);
  }
  if (name === 'OpenSubscriptions' || name === 'ViewSubscriptions') {
    return new ContinuationTarget('open_subscriptions');
  }
  if (name === 'OpenSubscriptionDetail') {
    return new ContinuationTarget('open_subscription_by_title', '', 0, 0, 0, 0, 0, 0, 0, title, title);
  }
  if (name === 'SearchInApp' || name === 'SearchMedia') {
    return new ContinuationTarget('search', '', 0, 0, 0, 0, 0, 0, 0, keyword);
  }
  return new ContinuationTarget('continue_latest');
}
