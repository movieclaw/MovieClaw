"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";

import { COMPANION_LABELS, COMPANION_POSES, type CompanionState } from "@/lib/agent-companion";
import { useMediaQuery } from "@/lib/use-media-query";

function subscribeVisibility(onChange: () => void) {
  document.addEventListener("visibilitychange", onChange);
  return () => document.removeEventListener("visibilitychange", onChange);
}

interface Picture { pose: CompanionState; frame: number; moving: boolean }

/** 单张透明图集，只有宠物自身随帧更新；动作节奏与 iPhone 一致。 */
export function AgentCompanion({ activity, attentive }: { activity: CompanionState; attentive: boolean }) {
  const reduceMotion = useMediaQuery("(prefers-reduced-motion: reduce)");
  const visible = useSyncExternalStore(subscribeVisibility, () => !document.hidden, () => true);
  const [picture, setPicture] = useState<Picture>({ pose: "idle", frame: 0, moving: false });
  const pictureRef = useRef(picture);
  const observed = useRef<{ activity?: CompanionState; greeting: number }>({ greeting: 0 });
  const [greeting, setGreeting] = useState(0);

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    const sleep = (ms: number) => new Promise<void>((resolve) => { timer = setTimeout(resolve, ms); });
    const show = (pose: CompanionState, frame = 0, moving = false) => {
      if (cancelled) return;
      pictureRef.current = { pose, frame, moving };
      setPicture(pictureRef.current);
    };
    const once = async (pose: CompanionState) => {
      for (let frame = 0; frame < 4 && !cancelled; frame++) {
        show(pose, frame, true);
        await sleep(pose === "working" ? 300 : 160);
      }
    };
    void (async () => {
      // StrictMode 会立即清理首个 effect；等这一轮清理结束后再开始动作。
      await Promise.resolve();
      if (cancelled) return;
      const previous = observed.current;
      const previousPose = pictureRef.current.pose;
      const tapped = greeting !== previous.greeting;
      observed.current = { activity, greeting };
      let next = activity;
      // 打开历史会话不重复庆祝；流式文本变化也不会重启动作。
      if (next === "complete" && previous.activity !== "working") next = "idle";
      if ((next === "idle" || next === "failed") && attentive) next = "attentive";
      show(next);
      if (reduceMotion || !visible) return;
      if (next === "working" && previous.activity !== "working") {
        await once("departing");
        if (cancelled) return;
        await once("working");
      } else if (next === "complete") {
        await once("complete");
        if (cancelled) return;
        show("complete", 3);
        await sleep(1200);
        next = attentive ? "attentive" : "idle";
      } else if (next === "failed" && previous.activity !== "failed") {
        await once("failed");
      } else if (next === "attentive" && (previousPose !== "attentive" || tapped)) {
        await once("attentive");
      } else if (tapped && next === "idle") {
        await once("attentive");
      }
      if (cancelled) return;
      show(next);
      // 抱鱼静坐，长任务仅偶尔眨眼；错误和倾听没有循环计时器。
      while (!cancelled && (next === "working" || next === "idle")) {
        await sleep(next === "working" ? 15000 + Math.random() * 10000 : 8000 + Math.random() * 6000);
        if (cancelled) return;
        show(next, next === "working" ? 2 : 1, true);
        await sleep(250);
        if (cancelled) return;
        show(next);
      }
    })();
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [activity, attentive, greeting, reduceMotion, visible]);

  const { pose, frame, moving } = picture;
  return (
    <button
      type="button"
      aria-label={COMPANION_LABELS[pose]}
      title="轻点和小幕打招呼"
      data-testid="agent-companion"
      data-pose={pose}
      data-moving={moving && visible && !reduceMotion}
      data-frame={frame}
      onPointerDown={(event) => event.preventDefault()}
      onClick={() => setGreeting((value) => value + 1)}
      className="absolute -top-[62px] right-3.5 z-10 size-[72px] rounded-xl bg-transparent p-0 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--text-muted)]"
      style={{
        backgroundImage: "url('/companions/moonlight.png')",
        backgroundSize: "400% 600%",
        backgroundPosition: `${frame * 100 / 3}% ${COMPANION_POSES.indexOf(pose) * 100 / 5}%`,
        backgroundRepeat: "no-repeat",
        transform: pose === "departing" ? `translate(${frame * 5}px, ${-(frame % 3) * 4}px)` : undefined,
      }}
    />
  );
}
