import { describe, it, expect } from '@ohos/hypium';
import { ApiClient } from '../../../main/ets/api/ApiClient';
import { MovieClawApi } from '../../../main/ets/api/Endpoints';
import { LibraryFilter, fetchWallFacets, fetchWallIndex, fetchWallItems, fetchWallRelax } from '../../../main/ets/library/LibraryWall';
import { LibraryRouteParams } from '../../../main/ets/library/LibraryRouteParams';
import { castTapTarget } from '../../../main/ets/library/LibraryItemDetailPage';

/** 只记请求路径、不发网络：验证各取数入口拼出来的查询参数 */
class RecordingClient extends ApiClient {
  paths: string[] = [];
  constructor() { super('https://fixture.invalid', null); }
  get<T>(path: string): Promise<T> {
    this.paths.push(path);
    return Promise.resolve(JSON.parse('[]') as T);
  }
}

function actorFilter(name: string): LibraryFilter {
  const filter = new LibraryFilter();
  filter.actor = LibraryFilter.normalizeActor(name);
  return filter;
}

/** 本地 / NFO 库点演员 → 同库按演员筛的海报墙（同 Web 8540a15bc） */
export default function libraryActorFilterTest(): void {
  describe('LibraryActorFilter', () => {
    it('normalize_trims_and_treats_blank_as_absent', 0, () => {
      expect(LibraryFilter.normalizeActor(' 张三 ')).assertEqual('张三');
      expect(LibraryFilter.normalizeActor('   ')).assertNull();
      expect(LibraryFilter.normalizeActor('')).assertNull();
      expect(LibraryFilter.normalizeActor(null)).assertNull();
    });
    it('actor_counts_as_one_condition_and_survives_clone', 0, () => {
      const filter = actorFilter('张三');
      expect(filter.isEmpty()).assertFalse();
      expect(filter.count()).assertEqual(1);
      // 面板里再勾别的维度：宿主 clone → toggle，演员条件要原样留着
      const next = filter.clone();
      next.toggle('genres', '18');
      expect(next.actor).assertEqual('张三');
      expect(next.count()).assertEqual(2);
      expect(next.valuesOf('actor').join(',')).assertEqual('张三');
    });
    it('remove_and_clear_drop_actor', 0, () => {
      const filter = actorFilter('张三');
      filter.remove('actor', '张三');
      expect(filter.actor).assertNull();
      expect(filter.isEmpty()).assertTrue();
      expect(new LibraryFilter().isEmpty()).assertTrue();
    });
    it('key_includes_actor_but_rules_do_not', 0, () => {
      const plain = new LibraryFilter();
      plain.genres = [18];
      const withActor = plain.clone();
      withActor.actor = '张三';
      expect(withActor.key() === plain.key()).assertFalse();
      expect(withActor.key().endsWith('a张三')).assertTrue();
      expect(actorFilter('张三').key()).assertEqual('a张三');
      // 合集规则没有演员这一维
      expect(actorFilter('张三').rules().length).assertEqual(0);
      expect(withActor.rules().length).assertEqual(1);
    });
    it('every_wall_query_carries_actor', 0, async () => {
      const client = new RecordingClient();
      const api = new MovieClawApi(client);
      const filter = actorFilter(' 张三 ');
      filter.genres = [18];
      await fetchWallItems(api, 7, filter, null, null, 60, 0);
      await fetchWallIndex(api, 7, filter, 'title', null);
      await fetchWallFacets(api, 7, filter, true);
      await fetchWallRelax(api, 7, filter);
      expect(client.paths.length).assertEqual(4);
      for (const path of client.paths) {
        expect(path.includes('g=18')).assertTrue();
        expect(path.includes(`actor=${encodeURIComponent('张三')}`)).assertTrue();
      }
      expect(client.paths[0].startsWith('/libraries/7/items?')).assertTrue();
      expect(client.paths[1].startsWith('/libraries/7/item-index?')).assertTrue();
      expect(client.paths[2].startsWith('/libraries/7/facets?')).assertTrue();
      expect(client.paths[3].startsWith('/libraries/7/relax?')).assertTrue();
    });
    it('no_actor_means_no_actor_param', 0, async () => {
      const client = new RecordingClient();
      await fetchWallItems(new MovieClawApi(client), 7, new LibraryFilter(), null, null, 60, 0);
      expect(client.paths[0].includes('actor=')).assertFalse();
    });
    it('route_params_survive_serialization', 0, () => {
      // pushPathByName 的参数到 onReady 时是普通对象：按字段取
      const raw: Object = JSON.parse(JSON.stringify(LibraryRouteParams.forActor(3, ' 张三 '))) as Object;
      expect(LibraryRouteParams.idOf(raw)).assertEqual(3);
      expect(LibraryRouteParams.actorOf(raw)).assertEqual('张三');
      const plain: Object = JSON.parse(JSON.stringify(new LibraryRouteParams(3))) as Object;
      expect(LibraryRouteParams.actorOf(plain)).assertNull();
      expect(LibraryRouteParams.actorOf(JSON.parse('{"libraryId":3}') as Object)).assertNull();
      expect(LibraryRouteParams.actorOf(JSON.parse('{"libraryId":3,"actor":"  "}') as Object)).assertNull();
      expect(LibraryRouteParams.actorOf(null)).assertNull();
    });
    it('cast_tap_target_prefers_person_page_then_actor_wall', 0, () => {
      expect(castTapTarget(287, true, '布拉德·皮特', 3)).assertEqual('person');
      expect(castTapTarget(525, false, '诺兰', 3)).assertEqual('person');
      expect(castTapTarget(null, true, '张三', 3)).assertEqual('libraryDetail');
      // 没有 id 的导演不可点；空名 / 无效库也不可点
      expect(castTapTarget(null, false, '某导演', 3)).assertEqual('');
      expect(castTapTarget(null, true, '  ', 3)).assertEqual('');
      expect(castTapTarget(null, true, '张三', 0)).assertEqual('');
      expect(castTapTarget(0, true, '张三', 3)).assertEqual('libraryDetail');
    });
  });
}
