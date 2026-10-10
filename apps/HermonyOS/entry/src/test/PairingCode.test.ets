import { describe, it, expect } from '@ohos/hypium';
import { PairingScan } from '../main/ets/common/PairingCode';

/**
 * PairingScan 纯函数的单测（对应 iOS 端 `PairingQRCodeTests`）。
 *
 * 这是扫码登录的第一道闸：**只认 MovieClaw 的登录二维码**，别的码必须解析失败——
 * 解析错了会把用户带去「批准一个陌生设备」的页面（钓鱼面），或者把好码丢掉（扫码白扫）。
 */
export default function pairingCodeTest() {
  describe('PairingScan', () => {
    it('parseActivateUrl_认 /activate?code= 的完整地址并取出「主机:端口」', 0, () => {
      const scanned: PairingScan | null =
        PairingScan.parse('https://mc.example.com:99/activate?code=MCLW-7F3K');
      expect(scanned === null).assertFalse();
      expect((scanned as PairingScan).code).assertEqual('MCLW-7F3K');
      expect((scanned as PairingScan).host).assertEqual('mc.example.com:99');
    });

    it('parseLegacyPath_旧版 /settings/devices?code= 也认，四位码自动补 MCLW 前缀', 0, () => {
      const scanned: PairingScan | null =
        PairingScan.parse('http://192.168.1.9:13000/settings/devices?code=ab12');
      expect(scanned === null).assertFalse();
      expect((scanned as PairingScan).code).assertEqual('MCLW-AB12');
      expect((scanned as PairingScan).host).assertEqual('192.168.1.9:13000');
    });

    it('parseBareCode_带 MCLW 前缀的纯码认，host 为空', 0, () => {
      const scanned: PairingScan | null = PairingScan.parse(' mclw7f3k ');
      expect(scanned === null).assertFalse();
      expect((scanned as PairingScan).code).assertEqual('MCLW-7F3K');
      expect((scanned as PairingScan).host === null).assertTrue();
    });

    it('rejectOtherQr_别的二维码不认（不能把人带去批准页）', 0, () => {
      // 裸的四位码扫码时不认（手输才认，随便一个四位字母的二维码可不能算）
      expect(PairingScan.parse('7F3K') === null).assertTrue();
      // 不是登录路径
      expect(PairingScan.parse('https://example.com/?code=MCLW-7F3K') === null).assertTrue();
      expect(PairingScan.parse('https://example.com/activate') === null).assertTrue();
      // 码不是 4 位
      expect(PairingScan.parse('https://example.com/activate?code=XYZ') === null).assertTrue();
      // 完全无关的码
      expect(PairingScan.parse('WIFI:S:MyNet;T:WPA;P:secret;;') === null).assertTrue();
      expect(PairingScan.parse('') === null).assertTrue();
    });

    it('normalize_空格横线大小写都规整成 MCLW-XXXX，正文必须恰好 4 位', 0, () => {
      expect(PairingScan.normalize('MCLW-7F3K')).assertEqual('MCLW-7F3K');
      expect(PairingScan.normalize('mclw_7f3k')).assertEqual('MCLW-7F3K');
      // 手输时只打后四位也认
      expect(PairingScan.normalize('7F3K')).assertEqual('MCLW-7F3K');
      // 8 位但没带 MCLW 前缀的正文不认（否则任意 8 位串都能当码）
      expect(PairingScan.normalize('AB12CD34') === null).assertTrue();
      expect(PairingScan.normalize('7F3') === null).assertTrue();
      expect(PairingScan.normalize('7F3KK') === null).assertTrue();
      expect(PairingScan.normalize('7F-K') === null).assertTrue();
    });
  });
}
