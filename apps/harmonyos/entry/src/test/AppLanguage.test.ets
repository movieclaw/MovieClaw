import { describe, it, expect } from '@ohos/hypium';
import { normalizeLanguage, lookupString, languageName, LanguageCode } from '../main/ets/common/AppLanguage';

export default function appLanguageTest(): void {
  describe('AppLanguage', () => {
    it('normalize_maps_common_bcp47_tags_to_three_languages', 0, () => {
      expect(normalizeLanguage('zh-Hans')).assertEqual(LanguageCode.zhHans);
      expect(normalizeLanguage('zh-CN')).assertEqual(LanguageCode.zhHans);
      expect(normalizeLanguage('zh_TW')).assertEqual(LanguageCode.zhHant);
      expect(normalizeLanguage('zh-Hant-HK')).assertEqual(LanguageCode.zhHant);
      expect(normalizeLanguage('yue-HK')).assertEqual(LanguageCode.en);
      expect(normalizeLanguage('en-US')).assertEqual(LanguageCode.en);
      expect(normalizeLanguage('fr')).assertEqual(LanguageCode.en);
      expect(normalizeLanguage('')).assertEqual(LanguageCode.en);
    });
    it('lookup_returns_translation_for_every_language', 0, () => {
      expect(lookupString(LanguageCode.zhHans, 'player.menu_audio')).assertEqual('音轨');
      expect(lookupString(LanguageCode.zhHant, 'player.menu_audio')).assertEqual('音軌');
      expect(lookupString(LanguageCode.en, 'player.menu_audio')).assertEqual('Audio');
    });
    it('lookup_missing_key_falls_back_to_zh_hans_then_key', 0, () => {
      expect(lookupString(LanguageCode.zhHans, 'no.such.key')).assertEqual('no.such.key');
      expect(lookupString(LanguageCode.zhHant, 'no.such.key')).assertEqual('no.such.key');
    });
    it('lookup_missing_key_in_zh_hant_falls_back_to_zh_hans', 0, () => {
      // 模拟词条没补齐：zh-Hans 有、zh-Hant 没有 → 回退简体，不出空文案
      expect(lookupString(LanguageCode.zhHant, 'settings.language.title').length).assertLarger(0);
      expect(lookupString(LanguageCode.en, 'playback.clips_footer_off').length).assertLarger(0);
    });
    it('autonyms_are_language_data_not_table_entries', 0, () => {
      expect(languageName(LanguageCode.zhHans)).assertEqual('简体中文');
      expect(languageName(LanguageCode.zhHant)).assertEqual('繁體中文');
      expect(languageName(LanguageCode.en)).assertEqual('English');
    });
  });
}
