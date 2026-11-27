/**
 * TV 播放引擎兼容导出：统一路由到双内核（AVPlayer + libmpv）的 `TvPlaybackHost`。
 * 车机端仍走 `common/AvPlayerEngine` 保持独立，互不干扰。
 */
export {
  TvPlaybackHost as TvAvPlayerEngine,
  TvPlaybackHost,
  TvPlayPhase,
  TvSkipSegments,
  TvPlayback,
  PlayRequest
} from '../playback/TvPlaybackHost';
