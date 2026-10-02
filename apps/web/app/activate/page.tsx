"use client";

import { DeviceApproval } from "@/components/device-approval";
import { WelcomeScreen } from "@/components/welcome-screen";
import { usePageTitle } from "@/lib/use-page-title";

/**
 * 批准设备登录：设备（Apple TV、命令行、转码器）发起配对后，人在这里输入配对码批准。
 * 服务端返回给设备的批准页地址就是这一页（routes/auth.py 的 _verification_uri）。
 * 外观沿用登录页的星空与玻璃卡片：扫码 → 登录 → 批准是一条连贯的路。
 */
export default function ActivatePage() {
  usePageTitle("批准设备登录");
  return <WelcomeScreen buttonLabel="批准设备" initialStage="card" card={() => <DeviceApproval />} />;
}
