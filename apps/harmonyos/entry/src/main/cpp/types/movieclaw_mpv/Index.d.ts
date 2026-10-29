/**
 * libmovieclaw_mpv.so 的类型声明：ArkTS ↔ libmpv client API 的桥接层。
 * 事件对象由 mpv 事件泵线程经 threadsafe function 推送。
 */
export interface MpvEvent {
  /** start-file | file-loaded | playback-restart | video-reconfig | idle
   *  | end-file | property-change | audio-interrupt | log */
  event: string;
  /** property-change：属性名 */
  name?: string;
  /** property-change：mpv_format（NONE=0/STRING=1/DOUBLE=2/FLAG=3…） */
  format?: number;
  /** property-change：按 format 解释；NONE 时不带 */
  value?: string | number | boolean;
  /** end-file：mpv_end_file_reason（0=EOF 2=stop 3=quit 4=redirect 5=error…按 mpv 头文件） */
  reason?: number;
  /** audio-interrupt：OH_AudioInterrupt_Hint（1=RESUME 2=PAUSE 3=STOP，与 ArkTS InterruptHint 同义） */
  hint?: number;
  /** audio-interrupt：OH_AudioInterrupt_ForceType */
  type?: number;
  /** log */
  level?: string;
  prefix?: string;
  text?: string;
}

export const createEngine: () => number;
export const initEngine: (handle: number, options: Record<string, string>,
  callback: (event: MpvEvent) => void) => boolean;
export const destroyEngine: (handle: number) => void;
export const command: (handle: number, args: Array<string>) => void;
export const setPropertyString: (handle: number, name: string, value: string) => void;
export const setPropertyNumber: (handle: number, name: string, value: number) => void;
export const setPropertyFlag: (handle: number, name: string, value: boolean) => void;
export const getPropertyString: (handle: number, name: string) => string | null;
export const getPropertyNumber: (handle: number, name: string) => number;
export const getPropertyFlag: (handle: number, name: string) => boolean;
/** format: 'string' | 'double' | 'flag' */
export const observe: (handle: number, name: string, format: string) => number;
export const unobserve: (handle: number, replyId: number) => void;
