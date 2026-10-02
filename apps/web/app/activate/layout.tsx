import { AuthGate } from "@/components/auth-gate";

/**
 * 批准设备登录（/activate）：**刻意不套工作台外壳**，与 /login、/play 一样留在 (app) 组之外。
 *
 * 人来这里只为一件事——输入电视 / 终端上的配对码并批准，侧栏、顶栏都是干扰；手机扫码打开时
 * 更是一屏只该有这张卡片。只保留登录闸门：未登录时 http.ts 把人送去 /login?next=，登录后
 * 带着配对码回到这里。
 */
export default function ActivateLayout({ children }: { children: React.ReactNode }) {
  return <AuthGate>{children}</AuthGate>;
}
