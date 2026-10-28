/**
 * 车机播放引擎：TV / 车机共用的 `common/AvPlayerEngine` 的类型别名。
 * 车机独有交互（行车锁视频面隐藏、上一集）由共用引擎提供，页面层只做渲染。
 */
export {
  AvPlayerEngine as CarAvPlayerEngine,
  PlayPhase as CarPlayPhase,
  SkipSegments as CarSkipSegments,
  Playback as CarPlayback,
  PlayRequest
} from '../../common/AvPlayerEngine';
