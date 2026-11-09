import { describe, it, expect } from '@ohos/hypium';
import { CollectionView, HomeRowPref, HomeRowPrefInput, LibraryView } from '../main/ets/api/Models';
import { LibraryHomeStore } from '../main/ets/library/LibraryHomeStore';
import {
  CollectionRowKind,
  HomeRow,
  HomeRows,
  LibraryRowKind,
  MediaKindRowKind
} from '../main/ets/library/HomeRows';

/**
 * HomeRows 合并规则的单测（口径 = Web lib/home-rows.ts，蓝本 iOS LibraryHomeRowsTests）。
 *
 * 存下来的只是提示：指向已删库 / 不可见合集的行静默丢弃，没存过的内置行按出厂
 * 顺序补齐——这几条直接决定「升级版本 / 换账号 / 管理员删库」之后首页还能不能
 * 看到该看的行（review #1：类型行必须每次按当前可见库重算，不能看首次结果缓存）。
 */

function makeLibrary(id: number, kind: string, excluded: boolean = false): LibraryView {
  return {
    id: id,
    name: `库${id}`,
    kind: kind,
    source: 'tmdb',
    capabilities: {
      scraped: true,
      episodic: false,
      naming: true,
      subscribable: false,
      write_nfo: false,
      default_aspect: 0.667,
      jellyfin_collection: 'movies',
      playable: true
    },
    generate_thumbnails: true,
    extract_chapter_images: false,
    detect_media_segments: true,
    exclude_from_home: excluded,
    auto_series_collections: false,
    access_mode: 'everyone',
    admin_visible: true,
    member_ids: [],
    viewer_access: true,
    root_paths: [],
    is_default: false,
    match_rules: [],
    auto_clear_missing: false,
    realtime_watch: false,
    network_mount: false,
    custom_cover: false,
    scrape_overrides: {},
    stats: {
      item_count: 0,
      file_count: 0,
      total_size_bytes: 0,
      unidentified_count: 0,
      missing_count: 0,
      ignored_count: 0
    },
    scanning: false,
    organizing: false,
    created_at: '2026-01-01',
    updated_at: '2026-01-01'
  };
}

function makeCollection(id: number, sort: string): CollectionView {
  return {
    id: id,
    name: `合集${id}`,
    rules: [],
    sort: sort,
    visibility: 'household',
    editable: true,
    manageable: true,
    rule_driven: false,
    item_count: 0,
    covers: [],
    kind: 'user',
    hidden: false,
    position: 0
  };
}

function rowIds(rows: HomeRow[]): string[] {
  return rows.map((row: HomeRow): string => row.id);
}

function libraryKindOf(rows: HomeRow[], id: string): LibraryRowKind | null {
  for (const row of rows) {
    if (row.id === id && row.kind instanceof LibraryRowKind) {
      return row.kind;
    }
  }
  return null;
}

function mediaKindOf(rows: HomeRow[], id: string): MediaKindRowKind | null {
  for (const row of rows) {
    if (row.id === id && row.kind instanceof MediaKindRowKind) {
      return row.kind;
    }
  }
  return null;
}

function collectionKindOf(rows: HomeRow[], id: string): CollectionRowKind | null {
  for (const row of rows) {
    if (row.id === id && row.kind instanceof CollectionRowKind) {
      return row.kind;
    }
  }
  return null;
}

export default function homeRowsTest() {
  describe('HomeRows', () => {
    it('defaultLayout_空清单按出厂顺序_类型行夹在媒体库与库行之间', 0, () => {
      const libraries: LibraryView[] =
        [makeLibrary(1, 'movie'), makeLibrary(2, 'video'), makeLibrary(3, 'tv')];
      const rows: HomeRow[] = HomeRows.build([], libraries, []);
      expect(rowIds(rows).join(','))
        .assertEqual('up-next,favorites,libraries,genres:movie,genres:tv,lib:1,lib:2,lib:3');
    });

    it('insertGenreRows_老偏好没存过类型行时补插在「我的媒体库」之后', 0, () => {
      const libraries: LibraryView[] = [makeLibrary(1, 'movie'), makeLibrary(2, 'tv')];
      const prefs: HomeRowPref[] = [
        { id: 'up-next' }, { id: 'favorites' }, { id: 'libraries' },
        { id: 'lib:1' }, { id: 'lib:2' }
      ];
      const rows: HomeRow[] = HomeRows.build(prefs, libraries, []);
      expect(rowIds(rows).join(','))
        .assertEqual('up-next,favorites,libraries,genres:movie,genres:tv,lib:1,lib:2');
    });

    it('dropGenreRow_该类型一个可见库都不剩时类型行跟着消失_另一类型照常补齐', 0, () => {
      const libraries: LibraryView[] = [makeLibrary(3, 'tv')];
      const prefs: HomeRowPref[] = [{ id: 'genres:movie' }];
      const rows: HomeRow[] = HomeRows.build(prefs, libraries, []);
      expect(rowIds(rows).join(',')).assertEqual('up-next,favorites,libraries,genres:tv,lib:3');
    });

    it('legacyKindRows_v030 隐藏的类型行丢弃_显示中的按当前可见库迁移_没库的消失', 0, () => {
      const libraries: LibraryView[] =
        [makeLibrary(1, 'movie'), makeLibrary(2, 'movie', true), makeLibrary(3, 'movie')];
      const hidden: HomeRow[] = HomeRows.build([{ id: 'kind:movie', hidden: true }], libraries, []);
      expect(rowIds(hidden).includes('kind:movie')).assertFalse();
      const visible: HomeRow[] = HomeRows.build([{ id: 'kind:movie' }], libraries, []);
      const visibleKind: MediaKindRowKind | null = mediaKindOf(visible, 'kind:movie');
      expect(visibleKind === null).assertFalse();
      if (visibleKind !== null) {
        expect(visibleKind.libraryCount).assertEqual(2);
        expect(visibleKind.sort).assertEqual('added_at');
      }
      const orphan: HomeRow[] = HomeRows.build([{ id: 'kind:movie' }], [makeLibrary(3, 'tv')], []);
      expect(rowIds(orphan).includes('kind:movie')).assertFalse();
    });

    it('libRowFlags_unfinished 优先于 unwatched_两者都让位 last_played', 0, () => {
      const libraries: LibraryView[] = [makeLibrary(1, 'movie')];
      const onlyUnwatched: LibraryRowKind | null = libraryKindOf(
        HomeRows.build([{ id: 'lib:1', unwatched: true }], libraries, []), 'lib:1');
      expect(onlyUnwatched === null).assertFalse();
      if (onlyUnwatched !== null) {
        expect(onlyUnwatched.unwatched).assertTrue();
        expect(onlyUnwatched.unfinished).assertFalse();
        expect(onlyUnwatched.builtin).assertTrue();
      }
      const bothFlags: LibraryRowKind | null = libraryKindOf(
        HomeRows.build([{ id: 'lib:1', unwatched: true, unfinished: true }], libraries, []), 'lib:1');
      expect(bothFlags === null).assertFalse();
      if (bothFlags !== null) {
        expect(bothFlags.unwatched).assertFalse();
        expect(bothFlags.unfinished).assertTrue();
      }
      const unfinishedWithLastPlayed: LibraryRowKind | null = libraryKindOf(
        HomeRows.build([{ id: 'lib:1', unfinished: true, sort: 'last_played' }], libraries, []), 'lib:1');
      expect(unfinishedWithLastPlayed === null).assertFalse();
      if (unfinishedWithLastPlayed !== null) {
        expect(unfinishedWithLastPlayed.unwatched).assertFalse();
        expect(unfinishedWithLastPlayed.unfinished).assertFalse();
        expect(unfinishedWithLastPlayed.sort).assertEqual('last_played');
      }
    });

    it('asRowSort_老偏好 release_date_asc 归一_只在反转自然方向时才算 reversed', 0, () => {
      const libraries: LibraryView[] = [makeLibrary(1, 'movie')];
      const legacy: LibraryRowKind | null = libraryKindOf(
        HomeRows.build([{ id: 'lib:1', sort: 'release_date_asc' }], libraries, []), 'lib:1');
      expect(legacy === null).assertFalse();
      if (legacy !== null) {
        expect(legacy.sort).assertEqual('release_date');
        expect(legacy.reversed).assertTrue();
      }
      const asc: LibraryRowKind | null = libraryKindOf(
        HomeRows.build([{ id: 'lib:1', sort: 'added_at', order: 'asc' }], libraries, []), 'lib:1');
      expect(asc === null).assertFalse();
      if (asc !== null) {
        expect(asc.reversed).assertTrue();
      }
      const desc: LibraryRowKind | null = libraryKindOf(
        HomeRows.build([{ id: 'lib:1', sort: 'added_at', order: 'desc' }], libraries, []), 'lib:1');
      expect(desc === null).assertFalse();
      if (desc !== null) {
        expect(desc.reversed).assertFalse();
      }
      const bogus: LibraryRowKind | null = libraryKindOf(
        HomeRows.build([{ id: 'lib:1', sort: 'not-a-sort' }], libraries, []), 'lib:1');
      expect(bogus === null).assertFalse();
      if (bogus !== null) {
        expect(bogus.sort).assertEqual('added_at');
        expect(bogus.reversed).assertFalse();
      }
    });

    it('rowPrefShapes_media_kind 同库行口径_无判别字段的裸 row 丢弃', 0, () => {
      const libraries: LibraryView[] = [makeLibrary(1, 'movie'), makeLibrary(4, 'movie')];
      const kind: MediaKindRowKind | null = mediaKindOf(HomeRows.build(
        [{ id: 'row:xyz', media_kind: 'movie', unwatched: true, unfinished: true }], libraries, []),
        'row:xyz');
      expect(kind === null).assertFalse();
      if (kind !== null) {
        expect(kind.libraryCount).assertEqual(2);
        expect(kind.unwatched).assertFalse();
        expect(kind.unfinished).assertTrue();
        expect(kind.name).assertEqual('');
      }
      expect(rowIds(HomeRows.build([{ id: 'row:nothing' }], libraries, []))
        .includes('row:nothing')).assertFalse();
    });

    it('collectionRow_没存排序沿用合集的序_名字去空格_合集没了就丢弃', 0, () => {
      const collections: CollectionView[] = [makeCollection(9, 'rating')];
      const kind: CollectionRowKind | null = collectionKindOf(HomeRows.build(
        [{ id: 'row:c1', collection_id: 9, name: ' 佳片 ' }], [], collections), 'row:c1');
      expect(kind === null).assertFalse();
      if (kind !== null) {
        expect(kind.sort).assertEqual('rating');
        expect(kind.reversed).assertFalse();
        expect(kind.name).assertEqual('佳片');
      }
      expect(rowIds(HomeRows.build([{ id: 'row:gone', collection_id: 404 }], [], collections))
        .includes('row:gone')).assertFalse();
    });

    it('prefInputOf_整行逐字段拷贝_自定义页与合集页回写不丢能力', 0, () => {
      const pref: HomeRowPref = {
        id: 'row:xyz',
        sort: 'rating',
        order: 'asc',
        name: ' 佳片 ',
        unwatched: true,
        unfinished: false,
        hidden: false,
        library_id: 3,
        collection_id: null,
        media_kind: null
      };
      const input: HomeRowPrefInput = HomeRows.prefInputOf(pref);
      expect(input.id).assertEqual('row:xyz');
      expect(input.sort).assertEqual('rating');
      expect(input.order).assertEqual('asc');
      expect(input.name).assertEqual(' 佳片 ');
      expect(input.unwatched).assertTrue();
      expect(input.unfinished).assertFalse();
      expect(input.hidden).assertFalse();
      expect(input.library_id).assertEqual(3);
      expect(input.collection_id === null).assertTrue();
      expect(input.media_kind === null).assertTrue();
      // 只存了 id 的行：其余字段补 null，PUT 回去不会把这一行的能力误删
      const bareInput: HomeRowPrefInput = HomeRows.prefInputOf({ id: 'favorites' });
      expect(bareInput.sort === null).assertTrue();
      expect(bareInput.unfinished === null).assertTrue();
      expect(bareInput.media_kind === null).assertTrue();
    });

    it('fetchKey_coverKey_库行键六段含 unfinished_库卡片与默认行共用一份取数', 0, () => {
      const libraries: LibraryView[] = [makeLibrary(1, 'movie')];
      const rows: HomeRow[] = HomeRows.build(
        [{ id: 'lib:1', unwatched: true, unfinished: true }], libraries, []);
      const key: string = LibraryHomeStore.fetchKey(rows[0]);
      // TV / Car 行墙解析器按冒号分段：parts[5] = unfinished
      expect(key).assertEqual('lib:1:added_at:false:false:true');
      const segments: string[] = key.split(':');
      expect(segments.length).assertEqual(6);
      expect(segments[5]).assertEqual('true');
      // 库卡片封面与「最近添加」默认行同一个键（不反转、不过滤）
      const defaultRows: HomeRow[] = HomeRows.build([], libraries, []);
      const defaultLib: HomeRow | undefined =
        defaultRows.find((row: HomeRow): boolean => row.id === 'lib:1');
      expect(defaultLib === undefined).assertFalse();
      if (defaultLib !== undefined) {
        expect(LibraryHomeStore.fetchKey(defaultLib)).assertEqual(LibraryHomeStore.coverKey(1));
      }
      expect(LibraryHomeStore.coverKey(1)).assertEqual('lib:1:added_at:false:false:false');
    });

    it('fetchKey_合集行三段_类型行同库行六段口径', 0, () => {
      const libraries: LibraryView[] = [makeLibrary(1, 'movie')];
      const collections: CollectionView[] = [makeCollection(9, 'added_at')];
      const colKind: CollectionRowKind | null = collectionKindOf(HomeRows.build(
        [{ id: 'row:c1', collection_id: 9 }], libraries, collections), 'row:c1');
      expect(colKind === null).assertFalse();
      if (colKind !== null) {
        expect(LibraryHomeStore.fetchKey(new HomeRow('row:c1', false, colKind)))
          .assertEqual('col:9:added_at:false');
      }
      const kind: MediaKindRowKind | null = mediaKindOf(HomeRows.build(
        [{ id: 'kind:movie', unwatched: true }], libraries, []), 'kind:movie');
      expect(kind === null).assertFalse();
      if (kind !== null) {
        expect(LibraryHomeStore.fetchKey(new HomeRow('kind:movie', false, kind)))
          .assertEqual('kind:movie:added_at:false:true:false');
      }
    });
  });
}
