/**
 * TV 大屏沉浸放映厅（鸿蒙智慧屏独占页签，Apple TV 无此能力）：
 * - 全屏 16:9 高码率精彩高光片段连播，单实例 AVPlayer 严控解码器句柄；
 * - 遥控器上下键秒切下一段/上一段，OK 键暂停/继续；
 * - 底部悬浮胶囊支持「从此处看全片」（毫秒级无缝续接正片双内核播放器）、进详情、收藏与标为已看。
 */
import { media } from '@kit.MediaKit';
import { KeyCode } from '@kit.InputKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PlaybackOwnership } from '@movieclaw/playback';
import { AppModel } from '../../common/AppModel';
import { ImageUrls } from '../../common/ImageUrls';
import { RemoteImage } from '../../common/RemoteImage';
import { MovieClawApi } from '../../api/Endpoints';
import {
  PlaybackMarksRequest,
  ReelEpisodeView,
  ReelFeedView,
  ReelItemView
} from '../../api/Models';
import { playbackUrl } from '../../playback/PhoneMedia';
import { TvFormat, TvPillButton, TvStateView } from '../components/TvCards';
import { TvFocus } from '../components/TvFocus';
import { TvDetailRoute, TvPlayRequest, TvUiState } from '../model/TvUiState';
import { TvPlayback } from '../playback/TvPlaybackHost';
import { TvColors, TvMetrics, TvType } from '../theme/TvTheme';

@ComponentV2
export struct TvReelsPage {
  @Local items: ReelItemView[] = [];
  @Local index: number = 0;
  @Local loading: boolean = true;
  @Local failed: boolean = false;
  @Local kindFilter: string = '';
  @Local frameReady: boolean = false;
  @Local paused: boolean = false;
  @Local clipProgress: number = 0;
  @Local favorite: boolean = false;
  @Local played: boolean = false;

  private seed: number | undefined = undefined;
  private nextOffset: number = 0;
  private hasMore: boolean = true;
  private loadingMore: boolean = false;
  private player: media.AVPlayer | null = null;
  private surfaceController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private playGen: number = 0;

  aboutToAppear(): void {
    this.loadInitial();
  }

  aboutToDisappear(): void {
    this.teardownPlayer();
    PlaybackOwnership.release(this);
  }

  private async loadInitial(): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      this.loading = false;
      this.failed = true;
      return;
    }
    this.loading = true;
    this.failed = false;
    this.teardownPlayer();
    try {
      const view: ReelFeedView = await api.reelsFeed(
        undefined,
        0,
        10,
        'seek,clip',
        this.kindFilter.length > 0 ? this.kindFilter : undefined
      );
      this.seed = view.seed;
      this.nextOffset = view.next_offset;
      this.hasMore = view.has_more;
      this.items = view.items;
      this.index = 0;
      this.loading = false;
      this.syncMarks();
      if (this.items.length > 0) {
        this.startCurrentClip();
        setTimeout((): void => {
          TvFocus.request(this.getUIContext(), 'tv_tab_anchor');
        }, 120);
      }
    } catch (_err) {
      this.loading = false;
      this.failed = true;
    }
  }

  private async loadMoreIfNeeded(): Promise<void> {
    if (!this.hasMore || this.loadingMore || this.index + 3 < this.items.length) {
      return;
    }
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    this.loadingMore = true;
    try {
      const view: ReelFeedView = await api.reelsFeed(
        this.seed,
        this.nextOffset,
        10,
        'seek,clip',
        this.kindFilter.length > 0 ? this.kindFilter : undefined
      );
      this.nextOffset = view.next_offset;
      this.hasMore = view.has_more;
      if (view.items.length > 0) {
        this.items = this.items.concat(view.items);
      }
    } catch (_err) {
    } finally {
      this.loadingMore = false;
    }
  }

  private current(): ReelItemView | null {
    if (this.index < 0 || this.index >= this.items.length) {
      return null;
    }
    return this.items[this.index];
  }

  private syncMarks(): void {
    const item: ReelItemView | null = this.current();
    this.favorite = item !== null ? item.title.favorite : false;
    this.played = item !== null ? item.title.played : false;
  }

  private stepClip(delta: number): void {
    if (this.items.length === 0) {
      return;
    }
    const next: number = Math.max(0, Math.min(this.items.length - 1, this.index + delta));
    if (next === this.index) {
      return;
    }
    this.index = next;
    this.syncMarks();
    this.startCurrentClip();
    this.loadMoreIfNeeded();
  }

  private switchKind(kind: string): void {
    if (kind === this.kindFilter) {
      return;
    }
    this.kindFilter = kind;
    this.loadInitial();
  }

  private async startCurrentClip(): Promise<void> {
    const item: ReelItemView | null = this.current();
    this.teardownPlayer();
    if (item === null || this.surfaceId.length === 0) {
      return;
    }
    const isClip: boolean = item.play.mode === 'clip';
    const rawUrl: string | null = isClip ? (item.play.clip_url ?? null) : (item.play.stream_url ?? null);
    if (rawUrl === null || rawUrl.length === 0) {
      return;
    }
    const url: string = playbackUrl(AppModel.origin(), rawUrl);
    const startMs: number = isClip ? 0 : item.segment.start_ms;
    const spanMs: number = Math.max(1000, item.segment.end_ms - item.segment.start_ms);
    const endMs: number = isClip ? spanMs : item.segment.end_ms;
    const gen: number = ++this.playGen;

    PlaybackOwnership.claim(this, (): void => {
      this.pauseClip();
    });

    let player: media.AVPlayer;
    try {
      player = await media.createAVPlayer();
    } catch (_err) {
      return;
    }
    if (gen !== this.playGen) {
      player.release().catch((): void => {
      });
      return;
    }
    this.player = player;
    this.paused = false;
    this.frameReady = false;
    this.clipProgress = 0;
    player.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;

    player.on('timeUpdate', (timeMs: number): void => {
      if (gen !== this.playGen) {
        return;
      }
      const rel: number = Math.max(0, timeMs - startMs);
      this.clipProgress = Math.min(1, rel / spanMs);
      if (timeMs >= endMs) {
        if (this.index + 1 < this.items.length) {
          this.stepClip(1);
        } else {
          player.seek(startMs, media.SeekMode.SEEK_CLOSEST);
        }
      }
    });

    player.on('stateChange', (state: media.AVPlayerState, _reason: media.StateChangeReason): void => {
      if (gen !== this.playGen) {
        return;
      }
      if (state === 'initialized') {
        player.surfaceId = this.surfaceId;
        player.prepare();
      } else if (state === 'prepared') {
        if (startMs > 0) {
          player.seek(startMs, media.SeekMode.SEEK_CLOSEST);
        }
        player.play();
      } else if (state === 'playing') {
        this.paused = false;
        this.frameReady = true;
      } else if (state === 'paused') {
        this.paused = true;
      } else if (state === 'completed') {
        if (this.index + 1 < this.items.length) {
          this.stepClip(1);
        }
      }
    });

    player.on('error', (_err: BusinessError): void => {
      if (gen === this.playGen && this.index + 1 < this.items.length) {
        this.stepClip(1);
      }
    });

    player.url = url;
  }

  private pauseClip(): void {
    const p: media.AVPlayer | null = this.player;
    if (p !== null) {
      try {
        p.pause();
        this.paused = true;
      } catch (_err) {
      }
    }
  }

  private toggleClipPlay(): void {
    const p: media.AVPlayer | null = this.player;
    if (p === null) {
      return;
    }
    try {
      if (this.paused) {
        p.play();
      } else {
        p.pause();
      }
    } catch (_err) {
    }
  }

  private teardownPlayer(): void {
    this.playGen++;
    this.frameReady = false;
    this.clipProgress = 0;
    const p: media.AVPlayer | null = this.player;
    this.player = null;
    if (p !== null) {
      try {
        p.stop();
      } catch (_err) {
      }
      p.release().catch((): void => {
      });
    }
  }

  private openFullMovie(item: ReelItemView): void {
    this.teardownPlayer();
    const ep: ReelEpisodeView | null = item.title.episode ?? null;
    const isTv: boolean = item.title.kind === 'tv' && ep !== null;
    const req: TvPlayRequest = new TvPlayRequest(
      item.title.library_id,
      item.title.media_item_id,
      isTv && ep !== null ? ep.season : null,
      isTv && ep !== null ? ep.episode : null,
      item.segment.file_id > 0 ? item.segment.file_id : null,
      item.segment.start_ms,
      item.title.name,
      isTv && ep !== null ? TvFormat.episodeLine(ep.season, ep.episode, ep.name ?? null) : null,
      isTv
    );
    TvPlayback.begin(req);
    TvUiState.shared.openPlayer(req);
  }

  private async toggleFavorite(item: ReelItemView): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const next: boolean = !this.favorite;
    this.favorite = next;
    item.title.favorite = next;
    const body: PlaybackMarksRequest = { media_item_id: item.title.media_item_id, favorite: next };
    try {
      const res = await api.playbackMarksSet(body);
      this.favorite = res.is_favorite;
      item.title.favorite = res.is_favorite;
    } catch (_err) {
      this.favorite = !next;
      item.title.favorite = !next;
    }
  }

  private async togglePlayed(item: ReelItemView): Promise<void> {
    const api: MovieClawApi | null = AppModel.shared.api;
    if (api === null) {
      return;
    }
    const next: boolean = !this.played;
    this.played = next;
    item.title.played = next;
    const ep: ReelEpisodeView | null = item.title.episode ?? null;
    const body: PlaybackMarksRequest = {
      media_item_id: item.title.media_item_id,
      season_number: ep !== null ? ep.season : null,
      episode_number: ep !== null ? ep.episode : null,
      played: next
    };
    try {
      const res = await api.playbackMarksSet(body);
      this.played = res.played;
      item.title.played = res.played;
    } catch (_err) {
      this.played = !next;
      item.title.played = !next;
    }
  }

  private coverUrlOf(item: ReelItemView): string {
    const raw: string | null = item.cover_url ?? item.title.backdrop_url ?? item.title.poster_url ?? null;
    const resolved: string | null = ImageUrls.resolve(AppModel.origin(), raw, null);
    return resolved === null ? '' : `${resolved}${resolved.includes('?') ? '&' : '?'}w=1920`;
  }

  private metaOf(item: ReelItemView): string {
    const parts: string[] = [];
    if (item.title.year !== null && item.title.year !== undefined) {
      parts.push(`${item.title.year}`);
    }
    for (const g of item.title.genres) {
      parts.push(g);
    }
    if (item.title.rating !== null && item.title.rating !== undefined && item.title.rating > 0) {
      parts.push(`★ ${item.title.rating.toFixed(1)}`);
    }
    const ep: ReelEpisodeView | null = item.title.episode ?? null;
    if (ep !== null) {
      parts.push(`第 ${ep.season} 季第 ${ep.episode} 集`);
    }
    return parts.join(' · ');
  }

  build() {
    Stack() {
      // 视频表面常驻单实例，换条只换流地址
      XComponent({
        id: 'tv_reels_surface',
        type: XComponentType.SURFACE,
        controller: this.surfaceController
      })
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .onLoad((): void => {
          this.surfaceId = this.surfaceController.getXComponentSurfaceId();
          if (this.items.length > 0) {
            this.startCurrentClip();
          }
        })

      if (this.current() !== null && !this.frameReady) {
        Stack() {
          RemoteImage({ url: this.coverUrlOf(this.current() as ReelItemView), placeholderText: '' })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

      // 上下暗角托底
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['rgba(0, 0, 0, 0.45)', 0], ['rgba(0, 0, 0, 0.05)', 0.42], ['rgba(0, 0, 0, 0.88)', 1]]
        })
        .hitTestBehavior(HitTestMode.None)

      if (this.loading) {
        Column({ space: 14 }) {
          LoadingProgress().width(48).height(48).color(TvColors.textMuted)
          Text('正在挑选高光放映片段…').fontSize(TvType.footnote).fontColor(TvColors.textMuted)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.failed || this.items.length === 0) {
        TvStateView({
          symbol: $r('sys.symbol.film'),
          title: '放映厅暂无可播片段',
          message: '媒体库完成扫描后会自动挑出高码率精彩段落供大屏刷片。',
          actionTitle: '重新抽取',
          defaultFocusAction: true,
          onAction: (): void => {
            this.loadInitial();
          }
        })
      } else if (this.current() !== null) {
        this.Overlay(this.current() as ReelItemView)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TvColors.bg)
    .onKeyEvent((event: KeyEvent): boolean => {
      if (event.type !== KeyType.Down) {
        return false;
      }
      if (event.keyCode === KeyCode.KEYCODE_DPAD_UP || event.keyCode === KeyCode.KEYCODE_CHANNEL_UP) {
        this.stepClip(-1);
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_DPAD_DOWN || event.keyCode === KeyCode.KEYCODE_CHANNEL_DOWN) {
        this.stepClip(1);
        return true;
      }
      if (event.keyCode === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE) {
        this.toggleClipPlay();
        return true;
      }
      return false;
    })
  }

  @Builder
  private Overlay(item: ReelItemView) {
    Column() {
      // 顶部：分类筛选胶囊 + 右侧「上下键切段」提示
      Row({ space: 10 }) {
        TvPillButton({
          label: '全部',
          prominent: this.kindFilter === '',
          onActivate: (): void => {
            this.switchKind('');
          }
        })
        TvPillButton({
          label: '电影',
          prominent: this.kindFilter === 'movie',
          onActivate: (): void => {
            this.switchKind('movie');
          }
        })
        TvPillButton({
          label: '剧集',
          prominent: this.kindFilter === 'tv',
          onActivate: (): void => {
            this.switchKind('tv');
          }
        })
        Blank()
        Text(`第 ${this.index + 1} 段 · 按上下键切换`)
          .fontSize(TvType.footnote)
          .fontColor(TvColors.textMuted)
      }
      .width('100%')
      .padding({ left: TvMetrics.edge + 150, right: TvMetrics.edge, top: 40 })

      Blank()

      // 底部：片名 + 元信息 + 简介 + 操作胶囊 + 片段进度细线
      Column({ space: 14 }) {
        Text(item.title.name)
          .fontSize(TvType.heroTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(TvColors.text)
          .maxLines(1)
        if (this.metaOf(item).length > 0) {
          Text(this.metaOf(item))
            .fontSize(TvType.body)
            .fontColor(TvColors.textMuted)
            .maxLines(1)
        }
        if ((item.title.overview ?? '').length > 0) {
          Text(item.title.overview ?? '')
            .fontSize(16)
            .fontColor('rgba(243, 245, 249, 0.80)')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 640 })
        }

        Row({ space: 12 }) {
          TvPillButton({
            label: '从此处看全片',
            prominent: true,
            icon: $r('sys.symbol.play_fill'),
            focusKey: 'tv_tab_anchor',
            defaultFocused: true,
            onActivate: (): void => {
              this.openFullMovie(item);
            }
          })
          TvPillButton({
            label: this.paused ? '继续片段' : '暂停',
            prominent: false,
            onActivate: (): void => {
              this.toggleClipPlay();
            }
          })
          TvPillButton({
            label: '下一段',
            prominent: false,
            onActivate: (): void => {
              this.stepClip(1);
            }
          })
          TvPillButton({
            label: '影片详情',
            prominent: false,
            icon: $r('sys.symbol.info_circle'),
            onActivate: (): void => {
              this.pauseClip();
              TvUiState.shared.pushRoute(new TvDetailRoute(item.title.library_id, item.title.media_item_id));
            }
          })
          TvPillButton({
            label: this.favorite ? '已收藏' : '收藏',
            prominent: false,
            icon: $r('sys.symbol.heart'),
            onActivate: (): void => {
              this.toggleFavorite(item);
            }
          })
          TvPillButton({
            label: this.played ? '已看过' : '标为已看',
            prominent: false,
            icon: $r('sys.symbol.checkmark_circle'),
            onActivate: (): void => {
              this.togglePlayed(item);
            }
          })
        }

        // 片段进度细条
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(4)
            .borderRadius(2)
            .backgroundColor('rgba(255, 255, 255, 0.18)')
          Row()
            .width(`${(this.clipProgress * 100).toFixed(1)}%`)
            .height(4)
            .borderRadius(2)
            .backgroundColor('#ffffff')
        }
        .width('100%')
        .height(4)
        .margin({ top: 6 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: TvMetrics.edge, right: TvMetrics.edge, bottom: 32 })
    }
    .width('100%')
    .height('100%')
  }
}
