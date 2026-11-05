/**
 * 「开启并压制」保存软转开关之后，还该不该继续。
 *
 * 保存是异步的。用户在它返回前点了「不压制」、换了集、或播放器卸掉，这次意图就作废：
 * 不能再 ``onContinue``，否则取消之后视频仍会暂停重开、走进软件转码（#1187 评审）。
 * 调用方同时中止那次保存请求；请求若已经被服务端收下，这里只保证不再继续压制。
 */
export interface BurnEnableGate {
  /** 点下「开启并压制」时的记号 */
  token: number;
  /** 当前记号。取消、换集、卸载会把它加一 */
  current: () => number;
  signal: AbortSignal;
}

export type BurnEnableOutcome = "continue" | "dropped" | "rejected";

export async function enableSoftwareTranscodeForBurn(
  save: (signal: AbortSignal) => Promise<{ software_transcode_enabled: boolean }>,
  gate: BurnEnableGate,
): Promise<BurnEnableOutcome> {
  let saved: { software_transcode_enabled: boolean };
  try {
    saved = await save(gate.signal);
  } catch (error) {
    if (gate.signal.aborted || gate.current() !== gate.token) return "dropped";
    throw error;
  }
  if (gate.signal.aborted || gate.current() !== gate.token) return "dropped";
  return saved.software_transcode_enabled ? "continue" : "rejected";
}
