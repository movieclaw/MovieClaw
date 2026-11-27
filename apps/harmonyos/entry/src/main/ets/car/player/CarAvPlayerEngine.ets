/**
 * 车机播放引擎：由统一的 `car/playback/CarPlaybackHost`（AVPlayer + libmpv + PGS + 原生 ASS + 双 Vivid）
 * 提供，保持与原 CarAvPlayerEngine 完全超集兼容。
 */
export {
  CarAvPlayerEngine,
  CarPlayPhase,
  CarSkipSegments,
  CarPlayback,
  PlayRequest
} from '../playback/CarPlaybackHost';
