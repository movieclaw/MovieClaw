import { AuthGate } from "@/components/auth-gate";

/**
 * 片段（/reels）：同 /play，**不套工作台外壳**——竖滑看片要独占整块画面，标签栏、侧栏在这里都是干扰
 * （iOS / Android 进片段时同样收起标签栏）。只保留登录闸门。
 */
export default function ReelsLayout({ children }: { children: React.ReactNode }) {
  return (
    <AuthGate>
      <div className="h-dvh w-full overflow-hidden bg-black">{children}</div>
    </AuthGate>
  );
}
