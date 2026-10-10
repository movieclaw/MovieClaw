# 使用提示（对标 Apple TipKit）

在用户第一次（或第 N 次）做某件事时，在合适的位置出现一条提示，可带动作按钮；用户关掉或用过提示说的功能后，这条提示在所有设备上都不再出现。

## 分工

| 谁 | 管什么 |
|---|---|
| 各端代码 | 提示的文案、动作按钮、出现条件（规则）、出现在哪 |
| 服务端 | 每个人的状态：事件计数、每条提示的展示次数与作废记录 |

规则写在客户端，因为规则要读界面状态（「列表里有没有条目」），而且新提示随客户端发版即可，不用改服务端。状态放服务端，因为同一个人有网页、手机、电视好几端，在手机上关过的提示不该在电视上再出现。

## 状态与接口

两张成员级表（`member_id` 0 = 超管，删成员时随注册表清理）：

- `tip_event`：`(member_id, event_id)` 唯一；`count`、`first_at`、`last_at`。
- `tip_record`：`(member_id, tip_id)` 唯一；`display_count`、`first_displayed_at`、`last_displayed_at`、`invalidated_at`、`invalidated_reason`。

接口都在成员区，命令行不可见：

| 接口 | 作用 |
|---|---|
| `GET /tips/state` | 全量状态（`events[]` + `tips[]`），各端启动后第一次用到提示时拉一次 |
| `POST /tips/events/{event_id}` | 记一次用户行为，计数 +1 |
| `POST /tips/{tip_id}/displays` | 提示上屏一次，展示次数 +1 |
| `POST /tips/{tip_id}/invalidate` | 作废，body `{"reason": "..."}`（默认 `action_performed`）；以第一次为准，重复上报不改原因 |
| `DELETE /tips/state` | 重置自己的全部状态 |

- 标识：`^[a-z0-9][a-z0-9._-]{0,63}$`，按「页面或功能.提示」命名，如 `library.filter`。不合规返回 422。
- 作废原因不是枚举：`action_performed`（用过了）、`closed`（用户关掉）是约定值，新端上报新原因时旧服务端照收。
- 写入是原子 upsert：多台设备同时上报，计数不丢。

## 判定规则（各端实现必须一致）

一条提示能不能**开始**出现，按顺序判：

1. 已作废 → 永不出现。
2. 设置了 `maxDisplayCount` 且展示次数已到 → 永不出现。这一条只在本地算，不写回服务端。
3. 有一条规则不满足 → 暂不出现，条件满足后（例如事件计数够了）立刻出现。
4. 没展示过的新提示受全局频率节流：上一条新提示第一次出现后的 `displayFrequency` 内不出现新的。`ignoresDisplayFrequency` 可以豁免。Web 当前配置为 0，也就是不节流。

另外有两条展示约定：

- **同屏只出一条**：已经有提示在屏幕上时，其他满足条件的提示排队；前一条关闭或离开页面后，下一条接着出现。
- **上屏即锁定**：每次上屏记一次展示；已在屏幕上的提示不会因为这次展示把次数加到上限而当场消失，只有作废或离开页面才会消失。

快照拉回来之前不出任何提示，免得已作废的提示先闪一下。上报一律先改本地，再以服务端返回的那一行为准；网络失败静默处理，因为提示不是关键功能。

## Web 用法

```tsx
import { TipCard } from "@/components/tip-card";
import { defineTip } from "@/lib/tips/engine";
import { donateTipEvent, invalidateTip } from "@/lib/tips/store";

const filterTip = defineTip<{ itemCount: number }>({
  id: "library.filter",
  title: "试试筛选",
  message: "按年份、类型、画质快速找片",
  actions: [{ id: "open", label: "打开筛选" }],
  rules: [
    ({ event }) => event("library.opened").count >= 3,
    ({ params }) => params.itemCount > 50,
  ],
  maxDisplayCount: 1,
});

// 用户做了那件事的地方（事件处理函数里）
donateTipEvent("library.opened");

// 用户自己摸到了功能：提示没出现过也可以作废
invalidateTip("library.filter");

// 挂提示：动作按钮执行回调，之后按 action_performed 作废；关闭按钮按 closed 作废
<TipCard tip={filterTip} params={{ itemCount }} onAction={() => setFilterOpen(true)} />;
```

- `donateTipEvent` 要在事件处理函数里调用。放在 `useEffect` 里的话，开发模式（StrictMode）会记两次。
- 自定义样式时，用 `useTip(tip, params)` 拿到 `{ visible, invalidate }` 自己渲染。
- 文件：判定内核 `lib/tips/engine.ts`（纯函数，有单测），状态 `lib/tips/store.ts`，挂接 `lib/tips/use-tip.ts`，内联卡片 `components/tip-card.tsx`。

## 服务端代记的事件

有些事件不是看提示的人自己做的，提示要给的也不是做事的人。例如「家里有人在刷片」：谁都可能刷，
能打开片段预切的只有管理员。这类事件由服务端在业务链路上判定，写进**要看提示的那个人**的状态
（`services/tips.py` 与接口共用同一套写入），客户端的规则照常按事件计数判定，不用新接口。
相应地，服务端知道「功能已经用上了」时也直接作废提示，不管是在哪一端操作的。

- 服务端代记的事件放在业务产生点之后，只看内存标记，每个进程最多写一次库，不拖慢业务。
- 需要同时推送时，以事件计数第一次变成 1 为准，全服务器只推一次（推送事件 `usage_tip`，cloud-push.md §5）。

## 已上线的提示

| 提示 | 事件 | 出现在 | 作废 |
|---|---|---|---|
| `playback.reel-clips` 开启片段预切 | `reels.played-without-clips`（服务端替管理员记：开关关着时刷片或大图预告放出了原片片段） | 网页媒体库页顶部，只给管理员；动作「去开启」到「设置 → 播放」 | 打开开关时服务端作废；开关开着却有老 App 放原片时也作废 |

同一件事第一次记到时给管理员手机推一条「使用建议」，点开到 App 的「设置 → 播放」（与网页同一个开关）。

## 后续

- 其他客户端（iOS/Mac/TV、Android、Android TV）按本文的接口和判定规则各实现一份引擎。Apple 端不直接用 TipKit：TipKit 的存储没法接到服务端。
- 气泡式提示（指向某个按钮，对标 `popoverTip`）、设置页里的「重新显示使用提示」入口，等第一批真实提示上线时一起做。
- 事件只存累计次数和首末时间。如果以后需要「最近 7 天做过 3 次」这类规则，再加近期时间戳。
