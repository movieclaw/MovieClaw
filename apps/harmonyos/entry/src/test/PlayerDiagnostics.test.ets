import { describe, it, expect } from '@ohos/hypium';
import { NetBench, NetBenchResult } from '../main/ets/player/NetBench';
import { DeviceVitals, DeviceVitalsSnapshot } from '../main/ets/player/DeviceVitals';

/**
 * 播放诊断面板纯逻辑的单测：测速吞吐折算（NetBench.mbpsOf）、
 * 网络类型文案（DeviceVitals.labelFromFlags）、读数排版（lines）。
 * 真正的网络/设备 Kit 调用要在真机上走（本地无 DevEco，未构建验证）。
 */
export default function playerDiagnosticsTest() {
  describe('PlayerDiagnostics', () => {
    it('mbpsOf_字节数与耗时折算Mbit', 0, () => {
      // 1 MB 跑 1 秒 ≈ 8.4 Mbit/s
      expect(NetBench.mbpsOf(1048576, 1000)).assertEqual(8.4);
      // 0 字节 / 0 毫秒都不是合法输入，返回 0
      expect(NetBench.mbpsOf(0, 1000)).assertEqual(0);
      expect(NetBench.mbpsOf(1048576, 0)).assertEqual(0);
    });

    it('labelFromFlags_按bearer拼接网络文案', 0, () => {
      expect(DeviceVitals.labelFromFlags(true, false, false)).assertEqual('Wi-Fi');
      expect(DeviceVitals.labelFromFlags(false, true, false)).assertEqual('有线');
      expect(DeviceVitals.labelFromFlags(false, false, true)).assertEqual('蜂窝');
      expect(DeviceVitals.labelFromFlags(true, false, true)).assertEqual('Wi-Fi · 蜂窝');
      expect(DeviceVitals.labelFromFlags(false, false, false)).assertEqual('无网络');
    });

    it('lines_测速读数排版', 0, () => {
      const ok: NetBenchResult = new NetBenchResult();
      ok.rttMs = 42;
      ok.bytes = 5 * 1048576;
      ok.seconds = 2;
      const okLines: string[] = ok.lines();
      expect(okLines.length).assertEqual(2);
      expect(okLines[0]).assertEqual('往返延迟：42 ms');
      expect(okLines[1].includes('Mbit/s')).assertTrue();
      expect(ok.failed).assertFalse();

      // 没量到数据：吞吐行换成错误文案
      const bad: NetBenchResult = new NetBenchResult();
      bad.rttMs = -1;
      bad.error = '服务器没有返回数据，测不出吞吐';
      const badLines: string[] = bad.lines();
      expect(badLines.length).assertEqual(2);
      expect(badLines[0]).assertEqual('往返延迟：测不通');
      expect(badLines[1]).assertEqual('服务器没有返回数据，测不出吞吐');
      expect(bad.failed).assertTrue();
    });

    it('lines_设备读数排版', 0, () => {
      const s: DeviceVitalsSnapshot = new DeviceVitalsSnapshot();
      s.model = 'Mate 60';
      s.osVersion = '4.0.0';
      s.apiLevel = 12;
      s.heapUsedMb = 123.4;
      s.heapTotalMb = 512;
      s.netType = 'Wi-Fi';
      s.netDownKbps = 86000;
      const lines: string[] = s.lines();
      expect(lines.length).assertEqual(3);
      expect(lines[0]).assertEqual('设备：Mate 60 · HarmonyOS 4.0.0（API 12）');
      expect(lines[1]).assertEqual('内存：本机堆 123 MB / 512 MB');
      expect(lines[2]).assertEqual('网络：Wi-Fi · 下行约 86000 kbps');
    });
  });
}
