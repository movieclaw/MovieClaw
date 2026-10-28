/**
 * TV 播放引擎：TV / 车机共用的 `common/AvPlayerEngine` 的类型别名。
 * TV 页只保留界面层，播放决策/会话/上报全部走共用引擎。
 */
export {
  AvPlayerEngine as TvAvPlayerEngine,
  PlayPhase as TvPlayPhase,
  SkipSegments as TvSkipSegments,
  Playback as TvPlayback,
  PlayRequest
} from '../../common/AvPlayerEngine';
