export interface MpvEvent {
  type: string;
  name: string;
  text: string;
  value: number;
  code: number;
  reason: number;
}
export const createEngine: () => number;
export const initEngine: (handle: number, options: Record<string, string>, callback: (event: MpvEvent) => void) => Promise<void>;
export const command: (handle: number, args: string[]) => Promise<void>;
export const tracks: (handle: number) => Promise<string>;
export const destroyEngine: (handle: number) => Promise<void>;
