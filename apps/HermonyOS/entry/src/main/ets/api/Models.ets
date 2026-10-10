// 由 tools/gen_api_arkts.py 从 MovieClaw iOS 端 Models.swift 自动转译，勿手改。
// 源文件：MovieClaw/apps/apple/MovieClaw/Core/API/Generated/Models.swift
// 字段名与服务器 JSON 逐字一致（snake_case），JSON.parse 后一次 as 即可用。
import { JsonValue } from './JsonValue';

/** 浏览器当前持有的一个账号（GET /auth/accounts 列表项）。 */
export interface AccountView {
  username: string
  nickname: string
  /// 头像相对 URL；未上传过为空
  avatar_url?: string | null
  /// admin=超级管理员；member=成员
  role: string
  /// 是否为当前激活账号（列表里恰有一个为 true）
  active: boolean
}

/** 切换当前生效背景图的请求体。``backdrop_id`` 为空表示切回内置默认背景。 */
export interface ActiveBackdropUpdate {
  /// 要启用的背景图 id；为空表示使用内置默认背景
  backdrop_id?: string | null
}

/** 一条正在进行的整文件下载（播放器的离线缓存）。 */
export interface ActiveFileDownloadView {
  device_id: string
  revocable: boolean
  member_name: string
  client: string
  device_name: string
  media?: MediaActivityTarget | null
  file_name: string
  size_bytes: number
  bytes_sent: number
  rate_bytes_per_second: number
  connections: number
  position_bytes: number
  progress_percent?: number | null
  started_at: string
}

/** 一台设备正在进行的播放会话。 */
export interface ActivePlaybackSessionView {
  device_id: string
  revocable: boolean
  member_name: string
  client: string
  device_name: string
  client_version: string
  media: MediaActivityTarget
  position_ms?: number | null
  duration_ms?: number | null
  progress_percent?: number | null
  paused: boolean
  play_method: string
  rate_bytes_per_second?: number | null
  bytes_sent?: number | null
  connections: number
  file?: PlaybackFileSpec | null
  delivery?: PlaybackDeliveryView | null
  started_at: string
  last_report_at: string
}

/** 活动时间线的一条记录：message 已是完整中文句子，前端直接展示。 */
export interface ActivityView {
  id: number
  type: string
  message: string
  payload: Record<string, JsonValue>
  created_at: string
  wanted_item_id?: number | null
}

/** 本地刮削（NFO）的一位演员。 */
export interface ActorView {
  name: string
  role?: string | null
  /// 头像地址（NFO 里的图床 URL）
  thumb_url?: string | null
  /// TMDB 影人 ID；有值时前端把这一格链到人物页
  tmdb_person_id?: number | null
}

/** 网页手工创建令牌（给没有人能按批准的无人值守环境）。 */
export interface ApiTokenCreateRequest {
  /// 令牌名字，如 'nas-cron'，便于识别与注销
  name: string
  /// full=与你相同的完全权限；transcode=只能转码（给命令行模式的转码器用）
  scope?: string | null
}

/** 清理长期没用过的设备（`POST /auth/devices/cleanup`）。 */
export interface DeviceCleanupRequest {
  /// 注销多少天没用过的设备
  inactive_days: number
  /// 超管：清理全部成员的设备（否则只清自己的）
  all?: boolean | null
  /// 只列出会被注销的设备，不真的注销
  dry_run?: boolean | null
}

/** 会被清理的一台设备。 */
export interface DeviceCleanupItem {
  /// 设备 ID（与设备列表同一套）
  id: string
  /// 设备名
  name: string
  /// 主人的昵称
  owner_nickname: string
}

/** 清理结果：dry_run 时 devices 是「将被注销」的清单。 */
export interface DeviceCleanupView {
  /// 判定口径（天）
  inactive_days: number
  /// 命中或已注销的设备
  devices: DeviceCleanupItem[]
  /// 真的注销了几台（dry_run 时为 0）
  removed: number
}

/** 创建成功的返回体：token 明文仅此一次，请立即保存。 */
export interface ApiTokenCreatedView {
  /// 设备 id（在「设备」列表里注销时使用）
  id: string
  name: string
  scope: string
  created_at: string
  /// 令牌明文；服务端只存哈希，之后无法再次查看
  token: string
}

/** 保存请求体：与 ``AppServerSetting`` 配置域字段一一对应（整体覆盖语义）。 */
export interface AppConfigPayload {
  /// 网络可访问到本应用的完整地址（http/https），如 http://192.168.1.10:3000；空 = 未配置
  external_url?: string | null
}

/** 读取响应 = 可保存字段 + 对外端口的运行时状态（只读，端口另有专用端点）。 */
/** 端口没有并进 ``AppConfigPayload``：其它字段是「失焦即存、保存即生效」， */
/** 而改端口要重启整个应用、且改错会把用户关在门外，两者的交互语义完全不同， */
/** 混在一个整体覆盖的请求体里会让改地址时误触发重启。 */
export interface AppConfigView {
  /// 网络可访问到本应用的完整地址（http/https），如 http://192.168.1.10:3000；空 = 未配置
  external_url: string
  /// 当前生效的对外端口（前端监听口）
  web_port: number
  /// 端口来源：setting（应用内设置）/ env（环境变量）/ default（默认）
  web_port_source: string
  /// 内置默认端口，用于「恢复默认」的展示
  web_port_default: number
  /// 上次启动时因无法绑定而被自动废弃的端口；null = 无
  web_port_rejected?: number | null
  /// 当前部署形态是否支持应用内改端口（仅由容器入口托管进程的 Docker 部署）
  web_port_configurable: boolean
}

/** 外观设置的对外视图。 */
/** 背景图是按账号隔离的「图库」：用户上传的图全部保留（``backdrops``，按上传 */
/** 时间升序），其中至多一张为当前生效图（``active_id`` / ``active_url``）。 */
/** 二者为空表示正在使用内置默认背景——默认背景是前端内置资源，不出现在图库列表里。 */
export interface AppearanceView {
  /// 当前生效的背景图 id；为空表示使用内置默认背景
  active_id?: string | null
  /// 当前生效背景图的相对 URL（含版本号）；为空表示内置默认
  active_url?: string | null
  /// 图库中的全部自定义背景图（上传时间升序）
  backdrops: BackdropItem[]
}

/** 「更换图片」弹层里的一张候选（docs/design/metadata.md 6.3）。 */
export interface ArtworkCandidateView {
  /// TMDB 图片路径（选定时原样回传）
  file_path: string
  /// 缩略预览地址（TMDB 图床，前端经代理加载）
  preview_url: string
  width?: number | null
  height?: number | null
  /// 图上文字的语言；null=无文字（背景首选这类）
  language?: string | null
  vote_average?: number | null
  vote_count?: number | null
}

/** 条目的全部候选图，按与自动选图一致的规则排序。 */
/** ``current_*`` 是**实际在用**的图路径（前端据此标「当前」）——不能用 */
/** "列表第一张"推断：策略升级前刮的条目、手动锁定的条目、TMDB 新增更高票 */
/** 的图，三种情况下第一张都不是在用的那张。 */
export interface ArtworkCandidatesView {
  posters: ArtworkCandidateView[]
  backdrops: ArtworkCandidateView[]
  /// 片名徽标（透明底 PNG，镜像为 clearlogo.png）
  logos: ArtworkCandidateView[]
  /// 当前在用的海报路径
  current_poster?: string | null
  /// 当前在用的背景路径
  current_backdrop?: string | null
  /// 当前在用的徽标路径；null=没有（TMDB 无合适徽标）
  current_logo?: string | null
  /// 海报已手动选定，刷新不覆盖
  poster_locked: boolean
  /// 背景已手动选定，刷新不覆盖
  backdrop_locked: boolean
  /// 徽标已手动选定，刷新不覆盖
  logo_locked: boolean
}

/** 选图请求：kind 指哪种图；file_path 为 null 表示恢复自动选图。 */
export interface ArtworkSelectPayload {
  /// poster=海报 / backdrop=背景图 / logo=片名徽标
  kind: string
  /// TMDB 图片路径；null=解锁并恢复自动选图
  file_path?: string | null
}

/** 图片附件上传成功的回执；attachment_id 随后交给 session.start 引用。 */
export interface AttachmentUploadView {
  /// 附件稳定编号，绑定会话前 24 小时内有效
  attachment_id: string
  /// 原始文件名（服务端截断到 120 字符）
  name: string
  /// 图片像素宽度
  width: number
  /// 图片像素高度
  height: number
  /// 原始字节数
  bytes: number
}

export interface AudioPlanView {
  action: string
  track_ref?: string | null
  codec?: string | null
  channels?: number | null
  downmix: boolean
}

/** 一条音轨（ffprobe 探测；字段 None=该项探不出）。 */
export interface AudioStreamView {
  codec?: string | null
  /// 编码档次（如 DTS-HD MA），比 codec 更贴近用户认知
  profile?: string | null
  channels?: number | null
  /// 声道布局（如 5.1(side)）
  channel_layout?: string | null
  /// 语言标签（ISO 639，如 chi/eng）
  language?: string | null
  title?: string | null
}

export interface AudioSupportIn {
  codec: string
  max_channels?: number | null
}

/** 文件里的一条可选音轨。给播放器渲染音轨菜单用——只有候选列表在手， */
/** 前端才能让用户换轨；`audio.track_ref` 说的是「这次放的是哪条」。 */
export interface AudioTrackView {
  ref: string
  codec?: string | null
  channels?: number | null
  language?: string | null
  is_default: boolean
}

/** 站点认证方式。与 ``movieclaw_tracker`` 的三种 AuthProvider 一一对应。 */
/** - ``COOKIE``：用户直接粘贴浏览器 cookie（最简单，见 CookieAuthProvider） */
/** - ``APIKEY``：走站点 API 的密钥认证（如 M-Team，见 ApiKeyAuthProvider） */
/** - ``CREDENTIAL``：用户名 + 密码，由程序模拟登录（见 CredentialAuthProvider） */
export type AuthType = string;

/** 某授权类型及其要求用户填写的字段，供前端渲染表单。 */
export interface AuthTypeRequirement {
  auth_type: AuthType
  /// 该授权类型需要填写的字段名
  required_fields: string[]
}

/** 图库中的一张背景图。 */
/** ``url`` 是**带版本号**的相对地址（形如 ``/api/v1/appearance/backdrops/<id>?v=…``）， */
/** 版本号取文件修改时间的纳秒值，用来强制刷新浏览器与 WebGL 着色器对旧图的缓存。 */
export interface BackdropItem {
  /// 背景图 id（uuid4 hex）
  id: string
  /// 图片文件的相对 URL（含版本号）
  url: string
}

/** 批量转移的请求体：目标库 + 选择集 + 冲突策略。 */
/** 选择集**只有两种形态**：显式 id 列表，或整库（``all_items``）。刻意不收 */
/** 筛选表达式——筛选面已经在 ``library.items.list`` 上，在这里复制一份必然 */
/** 分叉（面板说 593 部、实际搬了 586 部，而且没人说得清差在哪）。 */
export interface BatchTransferPayload {
  /// 转移目标库 id（必须与当前库同类型）
  target_library_id: number
  /// 要转移的条目 id 列表（最多 2000 个）
  media_item_ids?: number[] | null
  /// true=转移该库的全部条目，忽略 id 列表
  all_items?: boolean | null
  /// 目标已有同名目录时：skip=跳过这一条、其余照搬（缺省）；merge=目标那个目录若属于同一部作品就把文件并进去（撞名的按多版本约定退让成「标题 - 分辨率.ext」，绝不覆盖；只是目录重名的另一部片、以及原盘目录仍然跳过）；fail=整批中止（脚本场景要求要么全成要么不动）
  on_conflict?: string | null
}

/** 批量转移预检：执行前把「将要发生什么」一次摆清。 */
export interface BatchTransferPreviewView {
  target_library_id: number
  target_library_name: string
  target_root: string
  on_conflict: string
  /// 选中的条目数
  selected: number
  /// 其中真正会搬的条目数
  movable: number
  total_bytes: number
  members: PreflightMemberView[]
  cross_device_items: number
  /// 需要完整复制的字节数（同盘搬运是 rename，不占新空间）
  cross_device_bytes: number
  target_free_bytes: number
  /// 目标盘需要的空间（只算跨盘部分，含余量）
  target_required_bytes: number
  /// 源盘预计释放的字节数——已扣掉硬链接文件。全硬链接库跨盘搬时这个数是 0：下载目录还引用着，删源不释放空间
  source_reclaimable_bytes: number
  hardlinked_items: number
  hardlinked_bytes: number
  /// null 表示下载器不可达、无法确认（不阻断执行）
  seeding_in_place_items?: number | null
  /// 同名冲突按锚分类的计数
  conflicts: Record<string, number>
  /// 整批阻断（目标根不可访问、空间不足、库正忙）；非空则不给执行
  blocked: string[]
}

/** 清理残留刷流种子的请求体。 */
export interface BoostCleanupRequest {
  /// 只清理这些站点；null=全部有在池种子的站点
  site_ids?: string[] | null
  /// 先关闭这些站点的刷流（不关的话引擎几分钟内会重新拉新种）
  disable_boost?: boolean | null
  /// true=保留期内的也立即删除（可能被站点记 H&R）；false=保留期内的先标记，到期后由引擎自动删除
  force?: boolean | null
}

/** 清理结果。 */
export interface BoostCleanupResult {
  /// 已连数据删除的种子数
  deleted_count: number
  /// 已释放的体积（字节）
  deleted_bytes: number
  /// 保留期内、已标记到期自动删除的种子数
  scheduled_count: number
  /// 标记的种子里最晚的到期时刻
  scheduled_until?: string | null
  /// 下载器不可达等原因这次没删成的种子数（已标记，下一轮巡检自动重试）
  failed_count: number
  /// 本次顺带关闭了刷流的站点
  disabled_sites: string[]
}

/** 某站点在池刷流种子的概况：开关状态、体积、能否立即删。 */
export interface BoostPoolSiteView {
  /// 站点标识
  site_id: string
  /// 站点显示名
  site_name: string
  /// 该站当前是否开着刷流（站点配置已删除时为 false）
  boost_enabled: boolean
  /// 该站刷流是否处于暂停
  boost_paused: boolean
  /// 在池种子数
  task_count: number
  /// 在池种子总体积（字节）
  size_bytes: number
  /// 现在就能删的种子数（已过保留期或未下完）
  deletable_count: number
  /// 现在就能删的体积（字节）
  deletable_bytes: number
  /// 还在保留期内的种子数（现在删可能被记 H&R）
  protected_count: number
  /// 还在保留期内的体积（字节）
  protected_bytes: number
  /// 保留期内种子里最晚的到期时刻；null=没有保留期内的种子
  protected_until?: string | null
  /// 已请求清理、等待自动删除的种子数
  scheduled_count: number
}

/** 在池刷流任务的清理相关状态（逐种子，供界面在对应行上标注）。 */
export interface BoostPoolTaskView {
  /// 种子 infohash（小写）
  info_hash: string
  /// 站点标识
  site_id: string
  /// 保留期到期时刻（站点保留天数与 H&R 考核时长取大）；null=现在删不涉及保留期
  protected_until?: string | null
  /// 已请求清理，等保留期满（或下载器恢复可达）后自动删除
  cleanup_scheduled: boolean
}

/** 刷流在池概况：按站点汇总 + 逐种子的清理状态。 */
export interface BoostPoolView {
  /// 有在池种子的站点
  sites: BoostPoolSiteView[]
  /// 在池种子的清理状态
  tasks: BoostPoolTaskView[]
}

/** 首次初始化：创建超级管理员账号。 */
export interface BootstrapRequest {
  /// 管理员用户名
  username: string
  /// 管理员密码，至少 8 位
  password: string
}

/** 首次初始化状态：前端据此决定进引导页（/setup）还是登录页（/login）。 */
export interface BootstrapStatus {
  initialized: boolean
}

export interface CalibratePayload {
  filename: string
}

export interface CalibrateResultView {
  ok: boolean
  message: string
  scale?: number | null
  offset_ms?: number | null
  score?: number | null
}

/** 目录项：一个系统支持的可配置站点。 */
export interface CatalogItem {
  site_id: string
  display_name: string
  base_url: string
  /// 支持的授权类型及各自的必填字段
  supported_auth_types: AuthTypeRequirement[]
}

/** 标签栏里的内置分类标签；在列表中的位置即展示顺序。 */
/** ``id`` 用枚举类型：未知分类在请求校验阶段即被拒（422）， */
/** 存储层无需再防脏数据。 */
export interface CategoryTabItem {
  type: string
  id: TorrentCategory
  visible: boolean
}

/** 标签栏里的内置分类标签；在列表中的位置即展示顺序。 */
/** ``id`` 用枚举类型：未知分类在请求校验阶段即被拒（422）， */
/** 存储层无需再防脏数据。 */
export interface CategoryTabItemInput {
  type?: string | null
  id: TorrentCategory
  visible: boolean
}

export interface ChangePasswordRequest {
  /// 当前密码（校验身份）
  old_password: string
  /// 新密码，至少 8 位
  new_password: string
  /// 同时注销命令行、转码器与手工令牌。默认保留：它们常年无人值守，改个密码就停转码很难排查；怀疑密码泄露时应勾上
  sign_out_paired?: boolean | null
}

/** 推送内容开关(GET 返回与 PUT 载荷同构)。 */
export interface ChannelPushConfigView {
  /// 订阅开始下载时推送
  push_dispatch: boolean
  /// 入库完成时推送
  push_imported: boolean
}

/** 整库生成章节的作业状态（docs/design/video-chapters.md §4.5）。 */
/** 章节作业是低优先级后台 Job，点了菜单后常要排在扫描/刷新后面才跑；随库 */
/** 列表一并返回（见 LibraryView.chapter_job），管理页才能显示"排队中 / */
/** 生成到第几个"，用户不必去活动页找。只投影未完成态，跑完即 null。 */
export interface ChapterJobView {
  job_id: string
  /// Job 未完成态原词：queued / running / cancelling …
  status: string
  /// 已处理文件数（含失败）
  processed: number
  total: number
  /// 生成失败的文件数
  failed: number
  /// 0-100；排队中或分母未知为 null
  percent?: number | null
  /// 已请求停止，正在收尾
  stopping: boolean
}

/** 一个章节（docs/design/video-chapters.md §4.6）：详情页「场景」横排的一张卡。 */
export interface ChapterView {
  /// 章节序号（0 起），与 Jellyfin 章节图路由的 index 同义
  index: number
  /// 章节起点（毫秒）
  start_ms: number
  /// 章节终点（毫秒）；末章无终点时为 null
  end_ms?: number | null
  /// 场景图上那一帧的真实时间（毫秒）；跳播用它，无图时为 null（退回 start_ms）
  frame_ms?: number | null
  /// 章节标题；合成章节与无名章节为 null
  title?: string | null
  /// 是否按时长合成（容器里没有内嵌章节）
  synthetic: boolean
  /// 场景图地址（本地资产相对路径）；未生成为 null
  image_url?: string | null
}

/** 整组认领：一次把多个待识别文件挂到同一个 TMDB 条目。 */
/** 季集号默认不在这里指定——每个文件沿用扫描时已从文件名解析出的季集号， */
/** 这正是"一部剧几十集一次认领"能成立的前提。季号解析不出的一组（待识别 */
/** 分类 ``unit_unresolved``）用 ``season_number`` 统一指定季号，集号照旧沿用。 */
export interface ClaimBatchPayload {
  /// 待识别文件 id 数组（来自待识别清单接口），如 [101,102]
  file_ids: number[]
  /// Discover 返回的 TMDB 影视条目稳定引用，如 tmdb:tv:1396
  title_ref: string
  /// 整组统一指定的季号（剧集；0=特别篇）；缺省沿用各文件解析出的季号
  season_number?: number | null
}

export interface CleanPayload {
  /// all=全部清空，orphans=只删孤儿条目
  mode: string
}

export interface CleanResultView {
  key: string
  mode: string
  removed: number
  /// 因正在使用而跳过的条目数
  skipped_busy: number
  freed_bytes: number
}

/** 客户端解码能力快照。前端探测后随决策请求上送，并缓存在 localStorage。 */
export interface ClientCapabilityIn {
  video?: VideoSupportIn[] | null
  audio?: AudioSupportIn[] | null
  containers?: string[] | null
  hdr_passthrough?: boolean | null
  mse?: string | null
  is_mobile?: boolean | null
  native_hls?: boolean | null
  universal?: boolean | null
  disc_image?: boolean | null
  disc_folder?: boolean | null
}

/** 下载器类型。取值与 ``movieclaw_downloader.DownloaderType`` 一一对应。 */
/** 此处独立定义而非直接 import —— movieclaw_db 是纯存储层， */
/** 不反向依赖领域库（与 SiteCredential 不依赖 tracker 同理）。 */
export type ClientType = string;

/** 合集卡片的一张封面图。 */
/** 合集自己没有图，封面就是成员的海报。由服务端在列合集时一并给出——否则 */
/** 客户端要为每个合集再请求一次成员才画得出卡片，一屏合集就是一屏请求。 */
export interface CollectionCover {
  url: string
  blur?: string | null
}

/** 手动合集的成员操作：加入与排序共用这一个形状。 */
export interface CollectionItemsPayload {
  /// 作品 id 列表。加入时是「要加的这些」，排序时是「新的先后顺序」
  media_item_ids?: number[] | null
}

/** 创建 / 更新合集的请求体。不传的字段一律「不改动」。 */
export interface CollectionPayload {
  /// 展示名
  name?: string | null
  /// 所属库（创建时必给）
  library_id?: number | null
  /// 收录规则；给空表 = 改成名单驱动（配合 item_ids 快照）
  rules?: JsonValue[] | null
  /// 合集内默认排序
  sort?: string | null
  visibility?: string | null
  /// 隐藏 / 取消隐藏（自动合集删不掉，只能藏；藏了要能放回来）
  hidden?: boolean | null
  /// 固定名单（「固定当前这 N 部」就是把此刻的命中集快照过来）；给了它就是名单驱动的合集
  item_ids?: number[] | null
  /// 创建时把 rules 此刻的命中集固化成名单（此后不再自动收录）。客户端因此不必把上千个 id 回传一遍——它要表达的本来就是「就这一批」，而不是「这一批具体是哪些」
  snapshot?: boolean | null
}

/** 系列合集的「已有 N / 共 M」与缺片名单（docs/design/library-series-collections.md 6.5）。 */
/** 只在合集详情页展示，**不上卡片**——一屏几十个红色角标是压迫感不是帮助。 */
export interface CollectionSeriesView {
  series_name?: string | null
  /// 库里已有几部
  owned_count: number
  /// 这个系列一共几部（TMDB 档案）
  total: number
  /// 系列官方海报
  image_url?: string | null
  parts: SeriesPartView[]
  /// 拉到上游档案了吗；false=没配 TMDB / 网络不通 / 本地系列没有上游档案
  available: boolean
}

/** 一个合集。形态（规则驱动 / 名单驱动、可不可改）是**推导**出来的，不是存的。 */
export interface CollectionView {
  id: number
  name: string
  /// 所属库；null=跨库合集
  library_id?: number | null
  /// 收录规则，与 library.match_rules 同构
  rules: JsonValue[]
  /// 合集内默认排序
  sort: string
  /// household=全家可见 / private=只有我
  visibility: string
  /// 内置合集标识；null=用户创建
  builtin?: string | null
  /// 当前观看者能不能改规则与名单（用户创建的合集，且 manageable 为真）
  editable: boolean
  /// 当前观看者能不能管理这个合集（改名、排序、可见性、隐藏、删除）：超管恒为真；成员只能管理自己的私有合集与自己建的全家合集
  manageable: boolean
  /// 规则驱动（会自己长）还是名单驱动（固定）
  rule_driven: boolean
  /// 当前可见成员数
  item_count: number
  /// 封面取哪部作品；null=取首个成员
  cover_item_id?: number | null
  /// 封面素材（前若干个成员的海报）；由服务端取，客户端不必为每个合集再请求一次成员
  covers: CollectionCover[]
  /// 合集从哪来：user=用户自建 / builtin=内置 / series=按作品系列自动生成
  kind: string
  /// 已隐藏（自动合集的「删除」落成墓碑）
  hidden: boolean
  position: number
}

/** 站点配置的验证状态机。 */
/** 用户填入授权信息后并不立刻可用，需异步验证通过才算数。状态流转： */
/** PENDING ──► VERIFYING ──► ACTIVE   （验证成功，可用） */
/** └─────► FAILED   （验证失败，见 last_error） */
/** - ``PENDING``：已保存，等待验证（刚配置或刚更新后的初始态）。 */
/** - ``VERIFYING``：验证进行中（异步任务已接手）。 */
/** - ``ACTIVE``：验证通过，凭据真实有效。 */
/** - ``FAILED``：验证失败（密码错误、cookie 过期、网络不通等，原因见 last_error）。 */
/** 注意：「一个站点是否可用」= ``enabled=True`` 且 ``status=ACTIVE``。 */
/** ``enabled`` 是用户的启用开关（意图），``status`` 是系统的验证结果，二者正交。 */
export type ConfigStatus = string;

/** 已配置站点的对外视图（**脱敏**：绝不回传 cookie/api_key/密码）。 */
export interface ConfiguredSite {
  site_id: string
  auth_type: AuthType
  enabled: boolean
  status: ConfigStatus
  /// 是否可用 = 已启用且验证通过（status=active）
  usable: boolean
  /// 站点保护开关：订阅链路绕开该站，手动搜索/下载不受影响
  protected: boolean
  /// 自动刷分享率开关
  boost_enabled: boolean
  /// 刷流暂停中：做种压到极低上传限速，停止汰换与拉新种（任务保留）
  boost_paused: boolean
  /// 刷流存储预算（字节）
  boost_budget_bytes: number
  /// 刷流汰换最低保留天数；0=不保护
  boost_hold_days: number
  /// 最近验证成功时间
  last_verified_at?: string | null
  /// 最近验证尝试时间
  last_checked_at?: string | null
  /// 最近验证失败原因（清晰中文）
  last_error?: string | null
  /// 站点用户资料快照；从未验证成功过则为 null
  profile?: SiteUserProfileView | null
  created_at: string
  updated_at: string
}

/** 根路径归并的请求体：并到哪个根、从哪些根并过来。 */
export interface ConsolidateRootsPayload {
  /// 要并到的目标根路径。**允许是当前还不在媒体库配置里的新路径**（换盘、换挂载点场景）：归并会先把它加进配置再开始搬
  into: string
  /// 要并过来的源根路径；留空表示「除 into 之外的全部根」
  from_roots?: string[] | null
}

/** 根路径归并预检：与批量转移同一套影响面，外加根配置的变化。 */
export interface ConsolidateRootsPreviewView {
  library_id: number
  into: string
  from_roots: string[]
  /// true=归并前会先把 into 加进媒体库配置
  into_is_new_root: boolean
  selected: number
  movable: number
  total_bytes: number
  members: PreflightMemberView[]
  cross_device_items: number
  cross_device_bytes: number
  target_free_bytes: number
  target_required_bytes: number
  source_reclaimable_bytes: number
  hardlinked_items: number
  hardlinked_bytes: number
  seeding_in_place_items?: number | null
  conflicts: Record<string, number>
  blocked: string[]
}

/** 插件推送某站点 Cookie 的请求体。 */
/** 插件只需上报"当前浏览器域名 + 拼好的 Cookie 串"，站点识别交给后端按域名反查。 */
export interface CookiePushRequest {
  /// 浏览器域名，如 kp.m-team.cc
  domain: string
  /// 拼好的 Cookie 请求头字符串：name=value; name2=value2
  cookie: string
}

/** 推送结果：告诉插件命中了哪个站点、当前验证状态如何。 */
export interface CookieSyncResult {
  site_id: string
  display_name: string
  /// 命中该站点所用的浏览器域名
  domain: string
  /// 凭据验证状态（推送后通常为 verifying）
  status: ConfigStatus
  /// 是否可用 = 已启用且验证通过
  usable: boolean
}

export interface CountryOption {
  /// ISO 3166-1 地区码（CN / US …）
  code: string
  /// 地区中文名（TMDB native_name，缺失回落英文名）
  name: string
}

/** 一条投递记录（内存环形缓冲，诊断用途）。 */
export interface DeliveryView {
  event_id: string
  event: string
  ok: boolean
  status_code?: number | null
  duration_ms: number
  attempts: number
  error: string
  at: string
}

/** 「这不是独立作品」：摘掉身份锚并忽略，不动磁盘。 */
/** 花絮/预告/片段被高置信错挂到别的影片时用它——用户要表达的不是"改挂 */
/** 到条目 Y"，而是"它根本不该是个条目"。可在「已忽略」里恢复。 */
export interface DetachPayload {
  /// 要摘掉身份的台账行 id 数组
  file_ids: number[]
}

/** 客户端发起接入请求。 */
/** 刻意**没有权限字段**：客户端只声明自己是什么形态、叫什么名字， */
/** 能做什么由批准者决定。 */
export interface DeviceAuthorizeRequest {
  /// 客户端形态：worker（转码 Worker）或 cli（命令行 / Agent）
  client_type: string
  /// 设备名，批准页上给人看的，如 'Yi的Mac-mini'
  client_name: string
  /// 客户端安装标识：同一台机器重新配对时替换旧凭证，而不是越积越多
  installation_id?: string | null
  /// 系统与架构，如 'macOS 26.0 · arm64'
  platform?: string | null
  /// 客户端版本
  client_version?: string | null
}

/** 接入请求的回执。``user_code`` 给人看，``device_code`` 用于兑换。 */
export interface DeviceAuthorizeView {
  /// 配对码，客户端显示给用户，在网页上核对
  user_code: string
  /// 兑换凭据，仅客户端持有，不得展示给用户
  device_code: string
  /// 批准页地址（不带配对码，用户需手动输入）
  verification_uri: string
  /// 带配对码的批准页地址：打开即显示这一条请求，客户端应优先打开它
  verification_uri_complete: string
  /// 建议的轮询间隔（秒），不要比这更快
  interval: number
  /// 配对码有效期（秒），超时需重新发起
  expires_in: number
}

/** 当前请求所用的登录设备（「当前设备」标记、``mclaw status`` 回显用）。 */
export interface DeviceBrief {
  id: string
  /// web / ios / tvos / android / cli / worker / manual
  kind: string
  name: string
}

/** 原生 App 登录时自报的设备信息。 */
export interface DeviceClientInfo {
  /// App 平台
  kind: string
  /// App 安装标识（存在系统钥匙串）：同一台设备同一个人重新登录时替换旧凭证
  installation_id: string
  /// 设备名，如 'iPhone Air'；用户之后可改名
  name?: string | null
  /// 系统与机型，如 'iOS 26.0 · iPhone18,4'
  platform?: string | null
  /// App 版本
  client_version?: string | null
}

/** 原生 App 用账号密码登录，换一枚设备令牌。 */
export interface DeviceLoginRequest {
  username: string
  password: string
  client: DeviceClientInfo
}

/** App 登录成功：设备令牌（明文仅此一次）+ 这台设备 + 当前身份。 */
export interface DeviceLoginView {
  /// 设备令牌明文；存进系统钥匙串，服务端只存哈希
  token: string
  device: LoginDeviceView
  session: SessionView
}

/** 一条待批准的接入请求（按配对码取，批准页的数据源）。 */
export interface DeviceRequestView {
  user_code: string
  client_type: string
  client_name: string
  /// 请求来源 IP，帮助用户判断这是不是自己那台机器；容器桥接网络会把源地址 NAT 掉，那种情况下为空串，界面应如实说无法确定
  source_ip: string
  /// 剩余有效秒数
  expires_in: number
  /// 客户端自报的系统与架构
  platform?: string | null
  /// 客户端自报的版本
  client_version?: string | null
  /// 只有管理员能批准（转码器）；成员看到时应说明原因
  requires_admin: boolean
}

/** 客户端轮询兑换令牌。 */
export interface DeviceTokenRequest {
  device_code: string
}

/** 兑换成功的返回体：令牌明文仅此一次。 */
export interface DeviceTokenView {
  /// 令牌明文；服务端只存哈希，之后无法再次查看
  token: string
  client_name: string
  client_type: string
  /// 批准者的用户名：这枚令牌就是他的身份
  granted_by: string
}

export interface DirUsageView {
  /// 登记目录的稳定标识
  key: string
  title: string
  /// 一句话用途（行内展示）
  summary: string
  /// 完整说明与清理后果（悬停/确认时展示）
  description: string
  /// 运行期实际路径
  path: string
  /// cache=可清理派生物，data=只展示
  group: string
  rebuild_cost: string
  /// 是否允许「全部清空」
  clearable: boolean
  /// 是否提供「清理孤儿条目」
  orphan_aware: boolean
  exists: boolean
  bytes: number
  /// 直接子项数量
  entries: number
}

/** 库内人物关系表中的一位导演。 */
export interface DirectorView {
  name: string
  /// 头像地址（TMDB 图床 URL）
  thumb_url?: string | null
  /// TMDB 影人 ID；用于人物页链接
  tmdb_person_id: number
}

export interface DiscoverRegionPayload {
  /// ISO 3166-1 地区码
  region: string
}

/** 当前生效的院线地区（含名称，页脚直接展示）。 */
export interface DiscoverRegionView {
  region: string
  /// 当前用户是否可修改（管理员）
  can_edit: boolean
}

/** 发现页影人档案：TMDB 中的全部影视作品及本地库存状态。 */
export interface DiscoveredPersonDetailsView {
  tmdb_person_id: number
  name: string
  avatar_url?: string | null
  /// 参演与幕后作品合并去重后的完整 TMDB 影视履历
  titles: DiscoveredTitleView[]
}

/** 电影详情中的系列作品。 */
export interface DiscoveredTitleCollectionView {
  id: string
  name: string
  titles: DiscoveredTitleView[]
}

/** 影视条目的完整资料、预告片、图片、相关推荐与本地媒体库入口。 */
export interface DiscoveredTitleDetailsView {
  title: DiscoveredTitleView
  metadata: DiscoveredTitleMetadata
  /// 主横幅剧照的 original 原图；详情页沉浸背景的高清升级源，缺失时为 None
  backdrop_original_url?: string | null
  /// 预告片与花絮（正式预告在前）；来源未提供时为空数组
  videos: MediaVideo[]
  backdrops: MediaImage[]
  posters: MediaImage[]
  collection?: DiscoveredTitleCollectionView | null
  recommendations: DiscoveredTitleView[]
  library_links: MediaLibraryLink[]
}

/** 影视条目详情中的作品资料与演职员。 */
export interface DiscoveredTitleMetadata {
  directors: string[]
  /// 带头像和人物 ID 的导演/主创；缺失时前端回退 directors 姓名
  director_credits: MediaCastMember[]
  cast: MediaCastMember[]
  country: string
  language: string
  released: string
  network?: string | null
  aliases: string[]
  source_url?: string | null
}

/** 发现/搜索结果中的影视条目摘要。 */
/** 豆瓣轻量搜索不提供媒体类型、年份与原名，这些字段允许为空；进入详情后 */
/** 服务端会补齐。``external_id`` 只用于展示或排障，后续调用应使用 */
/** ``title_ref``，避免不同来源的数字 ID 相互碰撞。 */
export interface DiscoveredTitleView {
  /// 影视条目稳定引用；详情接口原样消费
  title_ref: string
  provider: MediaSource
  external_id: string
  media_type?: MediaKind | null
  title: string
  original_title: string
  release_year?: number | null
  /// 来源站评分，0 表示暂无评分
  provider_rating: number
  genres: string[]
  /// 规模展示文本：电影片长或剧集季数；列表结果可能为空
  extent_label: string
  overview: string
  poster_url: string
  backdrop_url?: string | null
  /// 本地在位库存摘要；未匹配到本地条目时为空
  library_status?: MediaLibraryStatus | null
}

/** 指定来源和媒体类型下，按产品编排顺序返回的全部片单。 */
export interface DiscoveryCollectionListView {
  provider: MediaSource
  media_type: MediaKind
  collections: DiscoveryCollectionView[]
}

/** 一个片单及本次返回的影视条目。 */
export interface DiscoveryCollectionTitlesView {
  collection: DiscoveryCollectionView
  titles: DiscoveredTitleView[]
  returned_count: number
  /// 服务端当前取得的条目是否因本次 limit 被截断
  truncated: boolean
  page: number
  total_pages: number
  total_results: number
  has_more: boolean
}

/** 一个可浏览的影视片单及其能力说明。 */
export interface DiscoveryCollectionView {
  /// 片单稳定引用；浏览内容时原样传给 browse-collection
  collection_ref: string
  /// 片单数据来源：tmdb / douban
  provider: MediaSource
  /// 片单中的影视类型：movie / tv
  media_type: MediaKind
  /// 面向用户的片单名称
  name: string
  /// 片单内容与选取口径说明
  description: string
  /// 是否为有明确名次的排行榜
  is_ranked: boolean
  /// 发现页预览该片单时的默认条数
  default_limit: number
  /// 是否支持请求完整榜单（可用较大的 limit）
  supports_full_listing: boolean
}

/** 指定媒体类型可用于组合发现的动态选项。 */
export interface DiscoveryFilterOptionsView {
  media_type: MediaKind
  genres: DiscoveryGenreView[]
}

/** 筛选器里一个本地化的 TMDB 类型。 */
export interface DiscoveryGenreView {
  id: number
  name: string
}

/** 发现页的一个展示分区，数据由 collection_ref 指向领域接口。 */
export interface DiscoveryPageSectionView {
  collection_ref: string
  title: string
  presentation: DiscoveryPresentation
  preview_limit: number
  supports_full_listing: boolean
}

/** Web 发现页编排；只声明分区，不携带片单条目。 */
export interface DiscoveryPageView {
  provider: MediaSource
  media_type: MediaKind
  sections: DiscoveryPageSectionView[]
}

/** 发现页支持的展示形态；只在 Web 专用协议中出现。 */
export type DiscoveryPresentation = string;

/** 搜索时的数据来源范围；浏览片单仍要求指定单一来源。 */
export type DiscoveryProviderSelection = string;

/** TMDB 组合筛选支持的稳定排序值。 */
export type DiscoverySort = string;

/** 一次组合筛选得到的一页影视条目。 */
export interface DiscoveryTitlePageView {
  media_type: MediaKind
  titles: DiscoveredTitleView[]
  page: number
  total_pages: number
  total_results: number
  has_more: boolean
}

/** 投递路由预检（订阅弹窗选库时的即时提示）。 */
/** 与真实投递的三级兜底 + 映射守门同源判定，把"下载完成后能不能进库" */
/** 这个问题在订阅那一刻就回答掉，而不是等投递失败/落点告警才暴露。 */
export interface DispatchPreviewView {
  /// 投递路由：监听导入目录 / 直接下载进库 / 下载器默认目录
  mode: string
  /// movieclaw 视角的投递基底目录
  path?: string | null
  /// 条目目录的完整路径预览（按生效的命名模板渲染）。前端展示「直接下载到 …」时必须用它，不要自己拼「标题 (年份)」——命名模板可全局/按库自定义，自己拼会与真实落点不一致
  entry_dir?: string | null
  /// 命中自定义目录规则时的整理落点：下载完成后整理到该目录（不直接入库），文件外部流转回库根后才入账
  staging_path?: string | null
  /// 解析出的目标库（前端预选用）
  library_id?: number | null
  library_name?: string | null
  downloader_name?: string | null
  /// 收藏范围路由结论：true=命中声明库 / false=默认库兜底；未走路由为 null
  route_matched?: boolean | null
  /// 路由理由（中文整句，弹窗徽标直接展示）
  route_reason?: string | null
  /// 按规则组适用范围自动选出的规则组（与 route_* 同条件：走了路由才有）
  rule_set_id?: number | null
  rule_set_name?: string | null
  /// true=命中某组适用范围 / false=默认规则组兜底
  rule_set_matched?: boolean | null
  /// 选组理由（中文整句，弹窗与模拟一单直接展示）
  rule_set_reason?: string | null
  /// 按当前配置投递能否顺利入库
  ok: boolean
  /// 不 ok 时的中文指引
  warning?: string | null
}

/** 手动提交下载的请求体：搜索结果里的一条种子。 */
/** site_id + download_url 均来自搜索接口返回的 TorrentHit，后端凭它们 */
/** 带站点登录态取回 .torrent 字节再递交下载器。 */
export interface DownloadSubmitPayload {
  /// 种子所属站点 ID（TorrentHit.site_id）
  site_id: string
  /// 种子下载入口（TorrentHit.download_url）
  download_url: string
  /// 站点内种子 ID（TorrentHit.torrent_id）
  torrent_id?: string | null
  /// 入库到哪个媒体库
  library_id?: number | null
  /// 条目标题（推导条目子目录用）
  title?: string | null
  /// 条目年份
  year?: number | null
  /// 种子副标题（识别线索用）
  subtitle?: string | null
  /// 手选保存目录（覆盖库推导）
  save_path?: string | null
  /// 指定下载器；缺省用默认下载器
  downloader_id?: number | null
  /// 按确认的 TMDB 身份自动匹配媒体库并投递
  auto_route?: boolean | null
  /// 智能入库的媒体类型
  media_kind?: string | null
  /// 智能入库已确认的 TMDB 条目 ID
  tmdb_id?: number | null
  /// 种子分类；带上即表示记住本次保存位置，缺省不记
  category?: string | null
}

/** 手动提交下载的结果视图。 */
export interface DownloadSubmitView {
  /// 种子 infohash（极少数纯 v2 磁力无法解析时为空）
  info_hash?: string | null
  /// 下载器中的任务名称（提交后未能立即回查到时为空）
  name: string
  /// 种子提交前已存在于下载器（幂等，未重复添加）
  already_exists: boolean
  /// 接收本次提交的下载器 ID
  downloader_id: number
  /// 接收本次提交的下载器名称
  downloader_name: string
  /// 实际使用的保存目录（下载器视角，已过路径映射；空 = 下载器自身默认目录）
  save_path?: string | null
}

/** 一条保存位置记忆（确认条与「不再记住」的数据来源）。 */
/** ``downloader_name`` 由服务端解析后回显：确认条要在预检返回前就把「保存到 */
/** 哪台下载器」显示出来，让前端再去拉一次下载器列表来翻译 ID 没有必要。 */
/** 下载器已被删除时为 None，前端据此判定记忆失效、回落完整弹窗。 */
export interface DownloadTargetPrefView {
  /// 种子分类（TorrentCategory 值）
  category: string
  /// smart=智能入库 / dir=固定目录 / default=下载器默认目录
  kind: string
  /// 固定目录；仅 kind=dir 有值
  save_path?: string | null
  /// 指定下载器；空=默认下载器
  downloader_id?: number | null
  /// 下载器名称；空=用默认下载器，或指定的下载器已被删除
  downloader_name?: string | null
  /// 这条记忆最后一次被改变的时间
  updated_at: string
}

/** 删除下载器任务的结果。 */
export interface DownloadTaskDeleteView {
  downloader_id: number
  info_hash: string
  delete_files: boolean
}

export interface DownloadTaskListView {
  items: DownloadTaskView[]
  sources: DownloadTaskSourceView[]
}

/** 下载完成后**还没发生**的那段路：内容会被搬到哪、进不进库。 */
/** 口径来自 ``resolve_save_path``（投递、预检、体检共用的唯一实现），因此 */
/** 卡片上预告的落点与真正投递时的落点必然一致。任务中心据此把"等待入库 · */
/** 下一步"这种空话，换成"复制到「综艺」→ 扫描入账"的真实步骤链；推不出 */
/** 落点（外部任务、无业务身份）时整体为 null。 */
export interface DownloadTaskPlanView {
  /// watch=命中监听导入规则，下载完成后按策略搬进目标；inplace=直接下载在库内目录，扫描即入账，没有搬运动作；downloader_default=没有可用库/库无根路径，落下载器默认目录，不会自动入库
  mode: string
  /// 监听导入的搬运策略；mode=watch 才有
  strategy?: string | null
  /// 目标媒体库名；库未定（按收藏范围自动选库）或不进库时为 null
  library_name?: string | null
  /// 落点目录（库内条目目录或自定义目录）；推不出时为 null
  dest_path?: string | null
  /// 整理后是否进入媒体库。自定义目录规则为 false——文件落规则目录后不写库台账，需外部流转后由库根扫描收尾
  enters_library: boolean
}

/** 用户立即换种请求的受理结果。 */
export interface DownloadTaskReplaceView {
  downloader_id: number
  info_hash: string
  attempt_id: number
}

/** 一台下载器在本次快照中的可观测状态；单台故障不拖垮整页。 */
export interface DownloadTaskSourceView {
  id: number
  name: string
  client_type: ClientType
  status: string
  message?: string | null
  task_count: number
}

/** 下载器任务关联的订阅摘要，供任务中心回到业务上下文。 */
/** ``units`` 是**种子声明覆盖的全集**（含已入库的集），不是"还欠哪些集"。 */
/** 早期这里按在途工单过滤，导致列表随入库推进不断缩水、末集入库后变成空， */
/** "覆盖剧集"标签下却少了已入库的集（真实教训）。 */
/** ``purpose`` 区分补缺下载与洗版：两者在任务中心同形，但"已入库"对洗版是 */
/** 前提而非成果，进度必须换成 ``units[].replaced`` 的替换口径来讲。 */
export interface DownloadTaskSubscriptionView {
  id: number
  media_item_id: number
  media_title: string
  media_kind: string
  poster_url?: string | null
  purpose: string
  /// 洗版成功后是否保留旧版本共存（规则组的收藏家模式）。默认 false=旧版本移入回收站，保留期满自动清理——这是洗版真正会对磁盘做的事，任务中心要在替换发生前就说清楚
  upgrade_keep_old: boolean
  units: DownloadTaskUnitView[]
}

/** 订阅下载覆盖的一个追踪单元；电影沿用 0/0 哨兵。 */
/** ``status`` 直接透传工单状态机（wanted/grabbed/downloaded/imported）。分批 */
/** 入库时同一个种子里各集进度不同，只有逐集状态才能让任务中心说清"覆盖 10 */
/** 集、已入库 2 集"——入库 Job 在两批之间并不存活，不能拿它当状态源。 */
export interface DownloadTaskUnitView {
  season_number: number
  episode_number: number
  status: string
  /// 洗版任务专用：该集是否已被本种子替换完成。洗版单元在投递前就是 imported（库里有旧版本），status 无法表达洗版进度，只有工单改指本 种子才说明替换真的完成了；补缺下载恒为 false
  replaced: boolean
  /// 内容核验证明种子里没有这一集（声明的覆盖范围与实际文件不符）。这一集已退回重新寻找资源，不会再等这个种子——任务中心必须显示为需关注，而不是继续挂「等待下载完成」
  content_missing: boolean
}

/** 任务中心使用的下载器实时快照。 */
/** 下载器仍是下载状态的事实源；这里只在请求时汇总快照，并通过 infohash */
/** 关联订阅工单、换源心跳或手动下载意图，不把实时下载进度复制进本地数据库。 */
export interface DownloadTaskView {
  /// 稳定前端键：下载器 ID + infohash；缺失任务用 missing 前缀
  id: string
  info_hash: string
  name?: string | null
  downloader_id?: number | null
  downloader_name?: string | null
  downloader_type?: ClientType | null
  progress?: number | null
  size_bytes?: number | null
  dlspeed_bytes?: number | null
  upspeed_bytes?: number | null
  /// 累计上传量；刷流分组汇总用
  uploaded_bytes?: number | null
  /// 已完成字节；刷流分组汇总用
  completed_bytes?: number | null
  eta_seconds?: number | null
  state: string
  error_message?: string | null
  landing_error?: string | null
  source: string
  site_id?: string | null
  /// 来源站点显示名；未知站点回落 site_id
  site_name?: string | null
  /// 站点种子详情页 URL；能定位到站内种子时提供
  page_url?: string | null
  /// 投递时快照的分辨率，如 2160p
  resolution?: string | null
  /// 投递时快照的片源，如 WEB-DL
  media_source?: string | null
  /// 投递时快照是否为原盘 Remux
  remux: boolean
  media_item_id?: number | null
  media_title?: string | null
  media_kind?: string | null
  poster_url?: string | null
  plan?: DownloadTaskPlanView | null
  subscriptions: DownloadTaskSubscriptionView[]
  rescue_state?: string | null
  no_progress_seconds?: number | null
  can_replace: boolean
  replacement_due_at?: string | null
  rescue_message?: string | null
}

/** 追踪单元（电影为 0/0）——下载快照与手动选种结果共用。 */
export interface DownloadUnitView {
  season_number: number
  episode_number: number
}

/** 写入下载器全局限制的请求体（读-改-写：建议先 GET 再整体提交）。 */
/** - 限速 null = 取消限速，有值 = 限到该字节/秒； */
/** - 其余字段 null = 保持下载器现状不修改； */
/** - Transmission 不支持 ``max_active_torrents``，传了也会被忽略。 */
export interface DownloaderLimitsUpdate {
  download_limit_bytes?: number | null
  upload_limit_bytes?: number | null
  alt_speed_enabled?: boolean | null
  queue_enabled?: boolean | null
  max_active_downloads?: number | null
  max_active_uploads?: number | null
  max_active_torrents?: number | null
}

/** 下载器全局限制（实时读自下载器，不落库）。 */
/** - 限速单位**字节/秒**，null = 不限速； */
/** - ``alt_speed_enabled``：备用限速档（qB Alternative Speed / Tr Turtle Mode）； */
/** - 队列上限决定同时活动的任务数，超限任务进 queued 排队——刷流做种多时 */
/** 最容易撞上的墙；``max_active_torrents``（下载+做种总数上限）为 */
/** qBittorrent 独有，Transmission 恒为 null。 */
export interface DownloaderLimitsView {
  download_limit_bytes?: number | null
  upload_limit_bytes?: number | null
  alt_speed_enabled?: boolean | null
  queue_enabled?: boolean | null
  max_active_downloads?: number | null
  max_active_uploads?: number | null
  max_active_torrents?: number | null
}

/** 新增/更新下载器的请求体（更新时 id 走路径参数）。 */
/** 与站点配置同语义：更新是**全字段覆盖**，密码出于安全不回显， */
/** 编辑时需要重新填写（未填则视为该下载器无需密码）。 */
export interface DownloaderPayload {
  /// 下载器名称（全局唯一）
  name: string
  /// 下载器类型：qbittorrent / transmission
  client_type: ClientType
  /// 下载器地址，如 http://192.168.1.10:8080
  url: string
  /// 登录用户名（未开鉴权可留空）
  username?: string | null
  /// 登录密码（未开鉴权可留空）
  password?: string | null
  /// 默认保存目录（留空用下载器默认）
  save_path?: string | null
  /// 路径映射（movieclaw 路径 → 下载器路径，视角一致时留空）
  path_mappings?: PathMapping[] | null
  /// 是否启用（默认启用）
  enabled?: boolean | null
}

/** 启用/停用请求体。 */
export interface DownloaderStatusUpdate {
  /// true=启用 / false=停用（停用后不接收新的下载提交）
  enabled: boolean
}

/** 下载器配置的对外视图（**脱敏**：绝不回传密码）。 */
export interface DownloaderView {
  id: number
  name: string
  client_type: ClientType
  url: string
  username?: string | null
  /// 提交下载时的默认保存目录
  save_path?: string | null
  /// 路径映射 JSON 数组（movieclaw 路径 → 下载器路径），形如 [{"local":"/volume1/downloads","remote":"/downloads"}]
  path_mappings?: PathMapping[] | null
  enabled: boolean
  /// 是否为默认下载器（一键下载不选目标时投给它）
  is_default: boolean
  status: ConfigStatus
  /// 是否可用 = 已启用且连接测试通过（status=active）
  usable: boolean
  /// 最近一次连接成功获取的版本号
  version?: string | null
  /// 最近测试失败原因（清晰中文）
  last_error?: string | null
  /// 最近一次测试时间
  last_checked_at?: string | null
  /// 路径映射体检结果；null = 尚未体检或未配置映射
  path_health?: PathProbeView[] | null
  /// 路径映射是否全部可达（未体检/未配置映射视为健康，不误报）
  paths_healthy: boolean
  created_at: string
  updated_at: string
}

/** 一个多文件单元里的一个文件。 */
export interface DuplicateFileView {
  id: number
  file_name: string
  /// 绝对路径（悬停显示；成员视图不返回本接口）
  file_path: string
  /// 版本签名的质量部分：「分辨率 片源[ HDR]」
  quality_label: string
  size_bytes: number
  bit_rate?: number | null
  resolution?: string | null
  media_source?: string | null
  hdr?: string | null
  video_codec?: string | null
  /// 首条音轨「编码 声道」
  audio_label?: string | null
  origin: FileOriginView
  /// 版本签名：质量标签|来源 label（整季留这个版本时传回）
  version_key: string
  /// 系统建议保留的那个（只是建议）
  suggested: boolean
  /// 建议依据：档位最高 / 档位无法比较，按实测码率建议 / 同档，…
  suggest_reason?: string | null
  /// 用户「都留着」过；null=未标记
  kept_at?: string | null
}

/** 重复文件页的一次读取：扫描状态 + 分档摘要 + 本页条目。 */
/** 页面落地只看前两样（``limit=0`` 时不带条目）；点进某一档才拉明细。 */
export interface DuplicateFilesData {
  scan: DuplicateScanStateView
  /// 三档：放心清 / 建议清 / 要你决定
  tiers: DuplicateGroupView[]
  /// 「需要你决定」按取舍类型分组，同一种取舍一次决定一批
  review_groups: DuplicateGroupView[]
  total_units: number
  total_files: number
  total_bytes: number
  /// 当前筛选下有重复的条目数（分页总数）
  total_items: number
  items: DuplicateItemView[]
}

/** 一档、或「需要你决定」里的一组：有多少活、清掉能腾多少。 */
export interface DuplicateGroupView {
  /// safe / suggested / review；或取舍类型 resolution / hdr / …
  key: string
  label: string
  /// 一句话说明这一档是什么、该怎么处置
  hint: string
  units: number
  /// 按建议清理会清掉几个文件
  files: number
  bytes: number
}

export interface DuplicateItemView {
  library: TrashedLibraryRefView
  media_item: TrashedItemRefView
  seasons: DuplicateSeasonView[]
}

/** 一整档、或「需要你决定」里的一组，一次决定一批。 */
/** 同一种取舍的几百个单元，用户其实只有一个答案（"我要 4K" / "都留着"）， */
/** 所以批量的粒度是**档 / 组**而不是"全部重复文件"。 */
export interface DuplicateResolveAllPayload {
  /// safe 可以放心清理（机器确认没区别）/ suggested 建议清理（有一个档位明显更高）/ review 需要你决定
  tier: string
  /// tier=review 时只处理这一种取舍；省略 = 整个 review 档
  review_kind?: string | null
  /// 只处理某个库；省略 = 全部库
  library_id?: number | null
  /// true = 这一组都留着（只盖标记不动文件）；false = 按「建议保留」清理
  keep_all?: boolean | null
}

/** 一个单元 / 一季的决定：三选一，正好给一个。 */
/** 三个字段而不是一个联合类型的 ``keep``：联合类型在 OpenAPI 生成的 CLI 里会被 */
/** 压成单一标量（实测生成出 ``--keep int``），三种决定里只剩一种表达得出来。 */
/** 拆开之后 JSON 与命令行都自解释：``--keep-file-id`` / ``--keep-version`` / */
/** ``--keep-all``。 */
export interface DuplicateResolvePayload {
  /// 条目 id
  media_item_id: number
  /// 季号；电影为 0（哨兵）
  season_number?: number | null
  /// 集号；省略 = 整季（电影传 0 或省略）
  episode_number?: number | null
  /// 留这个：保留该文件，单元内其余移入回收站
  keep_file_id?: number | null
  /// 整季留这个版本：版本签名（列表接口的 version_key，形如「1080p Blu-ray|监听目录自动识别入库」）；没有该版本的集保留建议保留者
  keep_version?: string | null
  /// 都留着：这些版本都要，单元不再列为重复（不动文件）
  keep_all?: boolean | null
}

/** 扫描本身的状态：扫过没有、上次什么时候、现在是不是正在跑。 */
export interface DuplicateScanStateView {
  /// null=从未扫描；queued/running/… =正在跑；succeeded=有结果
  status?: string | null
  job_id?: string | null
  /// 正在跑时的进度文案
  message?: string | null
  percent?: number | null
  /// 上一轮扫描完成的时间
  scanned_at?: string | null
  /// 洗版验证在途、暂不列出的单元数
  upgrading_units: number
  /// 规则组「保留共存」、不列出的条目数
  keep_old_items: number
}

/** 一个条目的一季在某一堆里的块（一季两种都有时两堆各一块）。电影恰好一季一集。 */
export interface DuplicateSeasonView {
  season_number: number
  bucket: string
  /// 同构：各集版本签名一致，可整季按版本决定
  uniform: boolean
  versions: DuplicateVersionView[]
  units: DuplicateUnitView[]
}

/** 一个单元（电影 = 条目；剧集 = 某季某集）。 */
export interface DuplicateUnitView {
  season_number: number
  episode_number: number
  bucket: string
  files: DuplicateFileView[]
}

/** 同构季的一个版本行：这版本覆盖哪些集、多大、从哪来。 */
export interface DuplicateVersionView {
  key: string
  quality_label: string
  origin_label: string
  episodes: number[]
  bytes: number
  suggested: boolean
}

/** 设置页「走代理」开关列表里的一项。 */
export interface EgressServiceOption {
  id: string
  label: string
  description: string
}

export interface EndpointCreateRequest {
  /// 展示名，如「家庭影音助理」
  name: string
  /// 地址标识，URL 末段
  slug: string
  /// 选中的服务域
  services: string[]
  description?: string | null
  expand_tools?: boolean | null
  timeout_seconds?: number | null
}

/** 创建/轮换的响应：唯一一次带令牌明文。 */
export interface EndpointCreatedView {
  endpoint: EndpointView
  /// 令牌明文，仅本次返回，服务端只存哈希
  token: string
}

/** 只更新给出的字段；地址标识建成后不可改。 */
export interface EndpointUpdateRequest {
  name?: string | null
  description?: string | null
  services?: string[] | null
  expand_tools?: boolean | null
  enabled?: boolean | null
  timeout_seconds?: number | null
}

/** 端点的展示形态。永远不含令牌明文——它只在创建与轮换时返回一次。 */
export interface EndpointView {
  id: string
  slug: string
  name: string
  description: string
  services: string[]
  /// 配置里存在但当前版本已没有的服务域（已忽略）
  missing_services: string[]
  expand_tools: boolean
  enabled: boolean
  token_hint: string
  timeout_seconds: number
  /// 当前配置下的实际工具数
  tool_count: number
  /// 供客户端填写的完整地址
  url: string
  created_at: string
  last_used_at?: string | null
}

/** 剧集分集区的一集：季集结构 + 本地分集刮削 + TMDB 兜底的合并结果。 */
export interface EpisodeView {
  episode_number: number
  name?: string | null
  /// 分集简介
  overview?: string | null
  air_date?: string | null
  /// 分集剧照：本地缩略图接口相对路径或 TMDB 图床地址；无为 null
  still_url?: string | null
  /// 该集有在位文件；false=缺集或文件缺失（前端置灰）
  owned: boolean
  /// 该集的台账文件 id
  file_ids: number[]
  /// 当前观看者上次看到的位置（毫秒）
  position_ms: number
  /// 当前观看者已看完该集
  played: boolean
  /// 观看进度 1~99；已看完由 played 表达，不给百分比
  progress_percent?: number | null
}

export interface EventCatalogEntry {
  event: string
  group: string
  label: string
  jellyfin_supported: boolean
  default_on: boolean
}

/** 供插件识别"当前站点是否被支持"的站点视图。 */
export interface ExtensionSiteView {
  site_id: string
  display_name: string
  /// 该站点的匹配域名（可注册域名），插件据此比对当前标签页
  domain: string
  /// 用户是否已配置该站点
  configured: boolean
  /// 已配置时的验证状态
  status?: ConfigStatus | null
  /// 是否可用 = 已启用且验证通过
  usable: boolean
}

/** 筛选面板里的一个候选值（docs/design/library-filtering.md 3.3）。 */
export interface FacetValueView {
  /// 取值（类型是 TMDB genre id、地区是国家码、年代是档名）
  value: string
  /// 展示名（类型/地区走内置映射表，未知取值原样显示）
  label: string
  /// 在**其他维度**已选条件下勾上本值还剩几部——算本维时排除本维自身的条件，否则勾了「动画」之后其他类型全变 0，多选就废了
  count: number
}

/** 首页「我的收藏」的一格：单库海报墙的条目视图 + 收藏上下文。 */
/** 收藏层级来自最近一次收藏的那一行：整剧两者皆 null，整季只有季号， */
/** 单集季集都有；电影恒为 null（内部 (0,0) 哨兵不外泄）。 */
export interface FavoriteItemView {
  media_item_id: number
  kind: MediaKind
  /// 卡片的详情落点库（同一作品跨库时取首页顺序第一个可见库）
  library_id: number
  /// 身份来源：tmdb / local（local=未识别或其他库）
  source: string
  /// TMDB 条目 ID；本地来源条目为 null
  tmdb_id?: number | null
  title: string
  year?: number | null
  poster_url?: string | null
  backdrop_url?: string | null
  /// 主图宽高比（真实像素尺寸或来源惯例），卡片按它排版
  primary_aspect: number
  /// 内容日期：影视为上映/首播日，本地条目为拍摄/录制日（图片库按月分组与悬停日期用）
  release_date?: string | null
  /// 评分（0~10，TMDB 或 NFO）；海报墙默认不印，悬停层与按评分排序/筛选时才显示
  rating?: number | null
  /// 主图的微缩占位图 data URI（约 300 字节）：缩略图到达前铺一层模糊色块
  poster_blur?: string | null
  /// 条目的首个在位文件 id（一文件一条目的库用它取原图；多文件条目取最早入账的）
  primary_file_id?: number | null
  file_count: number
  total_size_bytes: number
  seasons: number[]
  episode_count: number
  resolutions: string[]
  /// 标记 missing 的文件数（>0 时前端提示）
  missing_count: number
  /// 剧集播出状态：airing=在播 / ended=完结；电影或状态未知为 NULL
  air_status?: string | null
  /// 已播出但所有媒体库里都没有的正季集数（电影恒 0）——「补齐缺集」的依据
  missing_episode_count: number
  /// 最近一次文件入账时间（首页「最近添加」排序依据）
  added_at?: string | null
  /// 当前观看者是否收藏了这部作品（海报右上角那颗心）；不认人的调用恒 False
  is_favorite: boolean
  /// 最近一次可追溯入库批次的剧集摘要；NULL=电影或迁移前旧台账
  recent_addition?: LibraryRecentAdditionView | null
  /// 本库在位剧集相对 TMDB 季集结构的完整度摘要；电影或无有效集号为 NULL
  inventory_summary?: LibraryInventorySummaryView | null
  /// 在位但尚未探出介质规格的文件数——扫描补探阶段前端据此把「还在处理」的条目排到海报墙前面并点亮标记
  probe_pending_count: number
  favorite_season_number?: number | null
  favorite_episode_number?: number | null
}

/** 「我的收藏」分区的数据载荷。``total`` 是去重后的收藏作品总数， */
/** ``items`` 受 limit 截断——前端据此决定要不要给「展开全部」。 */
export interface FavoritesView {
  items: FavoriteItemView[]
  total: number
}

/** 接入飞书群自定义机器人(粘贴 Webhook 地址即绑即用,无配对码)。 */
export interface FeishuBindPayload {
  /// 飞书自定义机器人 Webhook 地址
  webhook_url: string
  /// 签名校验密钥;未开启签名校验留空
  secret?: string | null
}

/** 文件来源快照（docs/design/library-duplicate-files.md §2）：这个文件是怎么进库的。 */
export interface FileOriginView {
  /// subscription / manual_download / watch_import / scan
  kind: string
  /// 一句话：订阅《九门》自动投递 / 手动下载 / 监听目录自动识别入库 / 存量扫描发现
  label: string
  /// 第二行：站点 · 种子标题 · 下载器 · 搬运方式
  detail?: string | null
}

/** 修复卡里的一个可选修法。 */
export interface FixOptionView {
  /// 选项标题（如「补一条公共父目录映射」）
  title: string
  /// 为什么这么做 / 适合谁（帮用户在多个选项间取舍）
  why: string
  /// 具体做什么，含建议值
  steps: string
  /// 修复去处：设置分区 id 或 libraries（前端映射到路由）
  fix_section: string
  /// 跳转按钮文案
  fix_label: string
  /// 跳转预填参数（目标设置页读取后自动填表单）
  fix_params?: Record<string, string> | null
}

/** 一次目录浏览的结果：当前位置 + 上级 + 子目录列表。 */
export interface FsBrowseView {
  /// 当前目录的绝对路径（已规范化）
  path: string
  /// 上级目录路径；已在根目录时为 null
  parent?: string | null
  /// 子目录列表（只含目录，按名称排序）
  entries: FsEntry[]
}

/** 当前目录下的一个子目录。 */
export interface FsEntry {
  /// 目录名
  name: string
  /// 绝对路径
  path: string
}

/** 无法生成时的原因与下一步；前端据此渲染指导弹窗。 */
export interface GenPreviewBlockerView {
  code: string
  title: string
  message: string
  suggestions: string[]
}

/** 旧版服务端的「预检还没有结论，稍后重试」信号。 */
/** 新版预检不再读视频，永远当场给结论，这个字段恒为 null；保留它是为了让 */
/** 新版 App 连到旧版服务端时，仍能识别旧服务端返回的 pending 并照旧轮询。 */
export interface GenPreviewPendingView {
  /// 面向用户的等待文案
  message: string
  /// 正在抽取的候选，如 embedded:0
  candidate_key: string
  /// 建议的下次轮询间隔
  retry_after_ms: number
}

/** 发起前的确认素材：选源结果 + 成本估算。 */
export interface GenPreviewView {
  candidates: SourceCandidateView[]
  chosen_key?: string | null
  selected_source_key?: string | null
  event_count: number
  estimated_tokens: number
  already_generated: boolean
  warnings: string[]
  pgs_conversion?: PgsConversionView | null
  blocker?: GenPreviewBlockerView | null
  output_filename?: string | null
  pending?: GenPreviewPendingView | null
  /// 非空 = 参考字幕还没读取过（内封轨首次使用），确认后由任务先读取；此时 event_count 为 0，estimated_tokens 按片长粗估
  reference_notice?: string | null
}

export interface GenStartPayload {
  /// 目标语言，如 chs / eng
  target_language?: string | null
  /// 双语第二行语言
  secondary_language?: string | null
  /// 参考字幕标识，如 embedded:1
  source_candidate_key?: string | null
  /// 确认把图片字幕识别为文本
  convert_pgs?: boolean | null
  /// 图片字幕原始语言
  pgs_ocr_language?: string | null
}

/** 保存 GitHub 访问令牌的请求体。空串 = 清除令牌。 */
export interface GithubTokenPayload {
  /// GitHub 访问令牌；空 = 清除
  token?: string | null
}

/** GitHub 访问令牌的配置状态。令牌明文永不回传，只给打码后的尾号供用户辨认。 */
export interface GithubTokenView {
  configured: boolean
  masked: string
}

/** 人工选择种子下载：把搜索结果里的一条种子直接投给本订阅。 */
/** 字段即搜索结果行（TorrentHit）原样回传——交互式搜索现算现返、不落 */
/** 种子索引，只能由前端带回。attrs 同样回传（它本就是搜索链路里服务端 */
/** enrich 的产物，用户按它筛选后选中了这条）；缺失时服务端重新推导兜底。 */
export interface GrabPayload {
  site_id: string
  torrent_id: string
  title: string
  subtitle?: string | null
  /// 站点分类（movie/tv/…）
  category?: string | null
  /// 搜索结果里的结构化属性（TorrentAttrs）；缺失时服务端重算
  attrs?: Record<string, JsonValue> | null
  download_url?: string | null
  size_bytes?: number | null
  seeders?: number | null
  is_free?: boolean | null
  hit_and_run?: boolean | null
  imdb_id?: string | null
  douban_id?: string | null
  publish_time?: string | null
}

/** 手动选种的投递结果。 */
export interface GrabResultView {
  /// 本次投递满足的追踪单元
  units: DownloadUnitView[]
}

export interface HandoffPromptView {
  title: string
  prompt: string
}

export interface HandoffRequest {
  kind: string
  ref: string
}

/** 订阅链路体检里的一段检查结论。 */
export interface HealthCheckView {
  /// downloader / dispatch_dir / mapping / transfer_disk / watch_active
  key: string
  /// 段落名（如「下载器」「路径映射」）
  label: string
  /// ok=正常 / warn=能转但降级 / error=会失败，必须修
  status: string
  /// 中文事实陈述，直接展示
  detail: string
  /// 修复去处：设置分区 id（sites/downloaders/import-watch）或 libraries
  fix_section?: string | null
}

/** 按根因聚合的问题卡：一个根因 = 一张卡，不随受影响的库数膨胀。 */
export interface HealthIssueView {
  /// 与被聚合检查项的 HealthCheck.key 同词表
  key: string
  status: string
  /// 一句话根因
  title: string
  /// 根因的事实陈述与后果
  detail: string
  /// 受影响的库名
  affected_libraries: string[]
  /// 结构化修复选项（多个时由用户取舍）
  options: FixOptionView[]
}

export interface HealthResponse {
  status: string
  service: string
  environment: string
  spec_hash: string
}

/** 媒体库首页的一「行」：来源 × 排序 × 名字（docs/design/library-home-perspective.md）。 */
/** - 内置行（``up-next`` / ``favorites`` / ``libraries``）只存 ``hidden``，收藏行多一个 */
/** ``sort``；来源与名字由前端决定，这里不存； */
/** - 默认库行 ``lib:<library_id>`` 每库一条，能藏、能改排序和名字，不能删； */
/** - 自加行 ``row:<slug>`` 必须且只能带 ``library_id`` 或 ``collection_id`` 之一。 */
/** 除 ``id`` 外全部可空：空即默认（排序用预设、名字跟随推荐、不隐藏）。 */
/** 坏形状在 PUT 时就拒掉，读取端不再兜底——与 ``NavUiPrefs`` 一样，存下来的 */
/** 只是提示：指向已删库 / 不可见合集的行由前端合并时静默丢弃。 */
export interface HomeRowPref {
  /// 行 id，见类注释的四种形状
  id: string
  /// 排序档；空 = 该行的默认排序
  sort?: string | null
  /// 排序方向 asc / desc；空 = 该档的自然方向。前端只在反转自然方向时才存它
  order?: string | null
  /// 用户起的名字；空 = 跟随推荐
  name?: string | null
  /// 只显示没看过的（仅库行）
  unwatched?: boolean | null
  /// 隐藏这一行，位置保留
  hidden?: boolean | null
  /// 自加库行的来源库
  library_id?: number | null
  /// 合集行的来源合集
  collection_id?: number | null
}

/** 媒体库首页的一「行」：来源 × 排序 × 名字（docs/design/library-home-perspective.md）。 */
/** - 内置行（``up-next`` / ``favorites`` / ``libraries``）只存 ``hidden``，收藏行多一个 */
/** ``sort``；来源与名字由前端决定，这里不存； */
/** - 默认库行 ``lib:<library_id>`` 每库一条，能藏、能改排序和名字，不能删； */
/** - 自加行 ``row:<slug>`` 必须且只能带 ``library_id`` 或 ``collection_id`` 之一。 */
/** 除 ``id`` 外全部可空：空即默认（排序用预设、名字跟随推荐、不隐藏）。 */
/** 坏形状在 PUT 时就拒掉，读取端不再兜底——与 ``NavUiPrefs`` 一样，存下来的 */
/** 只是提示：指向已删库 / 不可见合集的行由前端合并时静默丢弃。 */
export interface HomeRowPrefInput {
  /// 行 id，见类注释的四种形状
  id: string
  /// 排序档；空 = 该行的默认排序
  sort?: string | null
  /// 排序方向 asc / desc；空 = 该档的自然方向。前端只在反转自然方向时才存它
  order?: string | null
  /// 用户起的名字；空 = 跟随推荐
  name?: string | null
  /// 只显示没看过的（仅库行）
  unwatched?: boolean | null
  /// 隐藏这一行，位置保留
  hidden?: boolean | null
  /// 自加库行的来源库
  library_id?: number | null
  /// 合集行的来源合集
  collection_id?: number | null
}

/** 媒体库首页的行清单（每个成员一份，超管走全局域）。 */
/** 空列表 = 出厂布局；合并规则（存过的按存的顺序、没存过的内置行与每库默认行追加 */
/** 在后、认不出的 id 忽略）在前端 ``lib/home-rows.ts``。 */
/** 上限 128 只是防脏数据的安全阀：自定义页会把合并后的整份清单存回来（三个内置行 + */
/** 每个可见库一条 + 自加的行），上限必须留得比"家里有很多库"大得多。 */
export interface HomeUiPrefs {
  /// 首页的行，按显示顺序；空 = 出厂布局
  rows: HomeRowPref[]
}

/** 媒体库首页的行清单（每个成员一份，超管走全局域）。 */
/** 空列表 = 出厂布局；合并规则（存过的按存的顺序、没存过的内置行与每库默认行追加 */
/** 在后、认不出的 id 忽略）在前端 ``lib/home-rows.ts``。 */
/** 上限 128 只是防脏数据的安全阀：自定义页会把合并后的整份清单存回来（三个内置行 + */
/** 每个可见库一条 + 自加的行），上限必须留得比"家里有很多库"大得多。 */
export interface HomeUiPrefsInput {
  /// 首页的行，按显示顺序；空 = 出厂布局
  rows?: HomeRowPrefInput[] | null
}

/** 一个硬件加速后端的自检结论。``detail`` 是给用户看的中文原因与修法。 */
export interface HwBackendStatusView {
  name: string
  label: string
  available: boolean
  detail: string
}

/** 硬件加速自检结果。 */
/** `available` 为空即「只能软件转码」——用户据此决定是去挂设备，还是接受 */
/** 软件转码的代价。 */
export interface HwProbeView {
  backends: HwBackendStatusView[]
  hardware_available: boolean
}

/** 身份复核的明确决策，避免调用方猜测布尔值含义。 */
export type IdentityReviewDecision = string;

/** 已绑定的 TG/Discord bot 账号(绑定页列表项)。 */
export interface ImAccountView {
  channel_id: string
  account_id: string
  bound_user_id?: string | null
  status: string
  running: boolean
  last_error?: string | null
  bound_at: string
}

/** 发起绑定:提交 bot token。 */
export interface ImBindTokenPayload {
  /// bot token
  token: string
}

/** 配对绑定状态(发起返回 + 前端 poll 同一结构)。 */
/** status 取值:pending / confirmed / expired / failed。 */
export interface ImBindingView {
  challenge_id: string
  status: string
  pair_code: string
  bot_name: string
  message: string
  account?: ImAccountView | null
}

/** 图片输入。三种形态（docs/design/agent-image-input.md）： */
/** - ``url``：http(s) 直链，原样发给供应商； */
/** - ``data`` + ``media_type``：base64 内联，仅存在于发请求前的内存消息里； */
/** - ``attachment_id``：服务端附件引用（会话 assets 目录下的 id）。**转录里 */
/** 只存引用**，发请求前由 API 层水合成 data；传输层遇到「只有引用、没有 */
/** data/url」的块会降级为占位文本，绝不把内部引用发给供应商。 */
export interface ImagePart {
  type: string
  url?: string | null
  data?: string | null
  media_type?: string | null
  attachment_id?: string | null
  name?: string | null
}

/** 创建/更新监听导入规则的请求体。 */
/** 目标三态：``library_id`` 指定库；``target_path`` 自定义目录（movie/tv */
/** 识别改名、video 原样搬运后落该目录，不进任何媒体库——整理结果需外部 */
/** 流转再进库的场景，此时 ``kind`` 必填）；两者都为 null 即**自动路由**（识别出作品后按各库收藏 */
/** 范围选库，``kind`` 同样必填）。``library_id`` 与 ``target_path`` 互斥。 */
export interface ImportWatchPayload {
  /// 源目录（绝对路径，不得与任何库根路径重叠）
  source_path: string
  /// 搬运策略：hardlink（零占用需与落点同盘）/ copy（可跨盘）
  strategy: string
  /// 目标媒体库；null=自动路由或自定义目录
  library_id?: number | null
  /// 自定义目录目标（绝对路径，不得与库根/监听源重叠）；与 library_id 互斥
  target_path?: string | null
  /// 自动路由/自定义目录的媒体类型；指定库时忽略（video：不识别不改名，自动路由落默认其他库、自定义目录原样落该目录）
  kind?: string | null
  /// 是否整理源目录里已有的存量内容；false=跳过存量只处理新增（存量条目在首轮巡检被标记为已忽略，清单中可恢复）
  process_existing?: boolean | null
}

/** 一条监听导入规则（带目标展示信息）。 */
export interface ImportWatchView {
  id: number
  source_path: string
  strategy: string
  /// null=自动路由或自定义目录
  library_id?: number | null
  library_name?: string | null
  /// 自定义目录目标（其余目标为 null）
  target_path?: string | null
  /// 自动路由/自定义目录的媒体类型（指定库时为 null）
  kind?: string | null
  /// 目标展示名：库名 /「自动路由（电影/剧集）」/「自定义目录 …」
  target_label: string
  /// 是否整理存量（false=跳过存量只处理新增）
  process_existing: boolean
  /// 台账状态计数（imported/pending/failed/skipped/ignored → 条目数）
  stats: Record<string, number>
  /// 已入库条目累计入库的文件数（剧集一条目是一个季包，条目数说不清入了几集）
  imported_files: number
  /// 已入库的作品数（同一部剧的多季、多版本合并为一部）——「已入库」展示的就是这个数，stats.imported 是记账条目数
  imported_works: number
  created_at: string
}

/** 一条规则的台账清单 + 各状态计数。 */
export interface IngestEntriesView {
  counts: Record<string, number>
  entries: IngestEntryView[]
}

/** 监听目录一个条目的处理台账行（清单展示）。 */
export interface IngestEntryView {
  id: number
  /// 条目名（源目录顶层的文件/目录名）
  name: string
  entry_path: string
  status: string
  /// 处理结论（中文）
  message?: string | null
  imported_count: number
  attempted_at: string
  /// 电影合集里识别不出、待逐个认领的视频（条目内相对路径）；普通条目为空
  unresolved_files: string[]
}

/** 作品详情页那一行「合集」的一项：只要名字和落点。 */
/** **刻意不带封面与成员数**。合集封面是从成员海报里借的——在《千与千寻》 */
/** 的页面上摆「日本动画」的封面卡，那张图很可能就是《千与千寻》自己； */
/** 而成员数属于合集卡片，这一行回答的是"它在哪儿"，不是"那儿有多大"。 */
export interface ItemCollectionRef {
  id: number
  name: string
}

/** 条目真实删除的结论。 */
export interface ItemDeleteResultView {
  /// 实际从磁盘删除的目录/文件
  removed_paths: string[]
  rows_deleted: number
  freed_bytes: number
  errors: string[]
}

export interface JobCancelView {
  cancelled: boolean
  job: JobView
}

export interface JobDismissAllRequest {
  /// 只忽略该类型；留空表示全部
  job_type?: string | null
}

export interface JobDismissAllView {
  /// 本次忽略的任务条数
  dismissed: number
  jobs: JobView[]
}

export interface JobDismissRequest {
  /// 同时静音自动来源：不再自动为该对象重建同类任务。只对有自动来源的任务类型有效（当前为字幕自动生成）；手动触发不受影响
  mute_source?: boolean | null
}

export interface JobDismissView {
  /// 本次是否真的改变了状态；重复忽略为 false
  dismissed: boolean
  /// 是否落了自动来源静音记录
  muted: boolean
  job: JobView
}

export interface JobEventListView {
  items: JobEventView[]
}

export interface JobEventView {
  id: number
  job_id: string
  revision: number
  event_type: string
  payload: Record<string, JsonValue>
  created_at: string
}

export interface JobListView {
  items: JobView[]
}

export interface JobProgressView {
  /// determinate / indeterminate / waiting / paused
  mode: string
  /// 当前领域阶段的稳定标识
  phase: string
  /// 面向用户的即时进展
  message: string
  /// 当前完成量
  current?: number | null
  /// 总量；未知时为空
  total?: number | null
  /// 真实可计算时才返回百分比
  percent?: number | null
  /// 当前阶段序号
  phase_index?: number | null
  /// 总阶段数
  phase_count?: number | null
  /// 领域进度明细
  details: Record<string, JsonValue>
}

export interface JobResourceView {
  resource_type: string
  resource_id: string
  relation: string
}

export interface JobRetryView {
  created: boolean
  job: JobView
}

/** 用户可见后台任务的持久化状态。 */
/** 状态值是 API、CLI、前端和执行器共同依赖的稳定协议，不能拿临时协程状态 */
/** 代替。``retry_wait`` 表示系统会自动重试，``blocked`` 表示必须由用户修复 */
/** 配置或补充输入；二者都不是普通失败。 */
/** 「用户忽略」刻意**不做成状态**：忽略只表达"我不打算处理了"，不改写 */
/** "这件事失败过"这个事实。日志溯源、重试链（``retry_of_job_id``）与终态 */
/** 集合都建立在 status 上，多一个终态会让每一处判定都要跟着改。忽略因此 */
/** 记在 ``dismissed_at`` 这一维上，与 status 正交。 */
export type JobStatus = string;

export interface JobView {
  id: string
  job_type: string
  subject?: string | null
  definition_version: number
  handler_revision: string
  prompt_revision?: string | null
  provider_ref?: string | null
  status: JobStatus
  /// 已确认的任务输入（永不包含密钥）
  input_data: Record<string, JsonValue>
  progress: JobProgressView
  result?: Record<string, JsonValue> | null
  error?: Record<string, JsonValue> | null
  usage: Record<string, JsonValue>
  resources: JobResourceView[]
  origin: string
  actor_kind?: string | null
  actor_name?: string | null
  parent_job_id?: string | null
  root_job_id?: string | null
  retry_of_job_id?: string | null
  attempt: number
  max_attempts: number
  revision: number
  cancel_requested_at?: string | null
  /// 取消发起方；system: 前缀代表系统自动收口，前端据此隐藏「重新执行」
  cancel_requested_by?: string | null
  /// 用户忽略的时间；非空表示不再计入「需要处理」，但任务本身仍是失败
  dismissed_at?: string | null
  /// 忽略操作者
  dismissed_by?: string | null
  created_at: string
  updated_at: string
  started_at?: string | null
  finished_at?: string | null
}

export interface JobWaitView {
  changed: boolean
  job: JobView
}

export interface JobWorkerHealthView {
  running: boolean
  owner?: string | null
  active_workers: number
  counts: Record<string, number>
  oldest_queued_seconds?: number | null
}

export interface LanguageOption {
  /// ISO 639-1 语言码（zh / en / ja …）
  code: string
  /// 该语言的本族名（TMDB name，缺失回落英文名）
  name: string
  english_name: string
}

/** 上一次容器异常退出的记录（entrypoint 落盘 updates/state/last-exit.json）。 */
/** 容器被 Docker 自动拉起后，用户需要知道曾发生过什么——无人值守的自愈 */
/** 不能悄无声息。正常停机与设置页/更新触发的重启不会产生该记录。 */
export interface LastAbnormalExitView {
  at: number
  reason: string
  exit_code: number
  detail: string
}

/** 最近一次整理的结论——给用户"整理完成了什么"的反馈。 */
export interface LastOrganizeView {
  finished_at: string
  /// 改名归位的主文件数
  renamed: number
  /// 跟随改名的附属文件数（字幕、分集剧照等）
  sidecars_renamed: number
  /// 跟随条目目录改名的镜像资产数（海报/背景/Logo/季海报/条目 NFO）
  entry_assets_moved: number
  /// 本就符合规范、无需动作的文件数
  already_ok: number
  /// 计划阶段跳过的文件数（原因见预览）
  skipped: number
  /// 搬空后清理掉的目录数
  removed_dirs: number
  errors: string[]
}

/** 最近一次扫描的结论——扫描常毫秒级结束，前端靠它给用户"点了有反应"的反馈。 */
export interface LastScanView {
  finished_at: string
  /// 本轮新入账文件数
  scanned: number
  identified: number
  unidentified: number
  /// 本轮标记丢失的文件数
  marked_missing: number
  /// 本轮自动清理出台账的丢失记录数（库开了自动清理才非 0）
  cleared_missing: number
  /// 本轮因已移除根路径而标记缺失的旧台账数
  removed_root_marked_missing: number
  /// 本轮因已移除根路径而自动清理的旧台账数
  removed_root_cleared: number
  /// 本轮已移除根路径台账的身份冲突数（需人工处理）
  removed_root_conflicts: number
  /// 疑似写入中暂缓入账的文件数（稍后自动补扫）
  deferred: number
  /// 识别重试数：在位但待识别的文件重走识别链（不算新入账）
  retried: number
  /// 本轮扫描被用户手动停止（未扫完）
  cancelled: boolean
  errors: string[]
}

/** 库的能力位（docs/design/library-other-kind.md 3.1）：前端按位显隐功能， */
/** 不按 kind 字面分叉——新增类型/来源时前端零改动。 */
export interface LibraryCapabilitiesView {
  /// 有外部刮削链（识别/刷新元数据/选图/待识别清单）
  scraped: boolean
  /// 有季集结构（分集区、缺集统计）
  episodic: boolean
  /// 有规范命名（整理功能）
  naming: boolean
  /// 可作为订阅入库目标
  subscribable: boolean
  /// 向媒体目录写 NFO/图片镜像
  write_nfo: boolean
  /// 卡片主图默认宽高比（无真实尺寸时）
  default_aspect: number
  /// Jellyfin 视图类型：movies / tvshows / homevideos / photos
  jellyfin_collection: string
  /// 条目可播放；假 = 只可查看（图片库：点击开灯箱而非播放器）
  playable: boolean
}

/** 一次筛选下的全部候选值与计数。 */
/** 与 /items 共用同一组筛选参数，因此两者口径天然一致：面板上显示多少部， */
/** 点下去墙上就是多少部。为 0 的候选值仍然返回（前端置灰不可点）， */
/** 这是"永不空货架"的第一道闸。 */
export interface LibraryFacetsView {
  /// 当前条件下的命中总数
  total: number
  /// 类型，按数量倒序
  genres: FacetValueView[]
  /// 地区，按数量倒序
  countries: FacetValueView[]
  /// 年代，按时间倒序
  decades: FacetValueView[]
  /// 观看状态：未看/在看/已看完是一个划分，另加我收藏的
  watch: FacetValueView[]
  /// 评分档（找片）
  ratings: FacetValueView[]
  /// 片长档（找片）
  runtimes: FacetValueView[]
  /// 原始语言（找片）
  languages: FacetValueView[]
  /// 分辨率（查库）
  resolutions: FacetValueView[]
  /// 动态范围（查库）
  hdr: FacetValueView[]
  /// 库存状态（查库）
  stock: FacetValueView[]
}

/** 条目详情页的一个物理文件（一个版本 / 一集）。 */
export interface LibraryFileView {
  id: number
  file_path: string
  file_name: string
  size_bytes: number
  container?: string | null
  resolution?: string | null
  video_codec?: string | null
  hdr?: string | null
  bit_depth?: number | null
  duration_seconds?: number | null
  bit_rate?: number | null
  frame_rate?: number | null
  color_space?: string | null
  media_source?: string | null
  /// 片源为人工标注（含 user-lowest 哨兵）
  media_source_manual: boolean
  release_group?: string | null
  /// imported（入库管线）/ scanned（存量扫描）
  source: string
  season_number: number
  episode_number: number
  /// 文件当前不在磁盘（missing 标记）
  missing: boolean
  /// 生命周期：in_place 在位 / missing 缺失 / trashed 待回收
  state: string
  /// 待回收的预计自动清理时间；null 且 trashed = 做种保护，不自动删
  purge_after?: string | null
  /// 待回收原因（中文整句，含触发方），文件区直接展示
  trash_note?: string | null
  /// 来源快照：这个文件是怎么进库的
  origin: FileOriginView
  /// 用户在重复文件页点过「都留着」的时间；null=未标记
  kept_at?: string | null
  /// 音轨列表；null=尚未探测（ffprobe 缺失或文件不可达）
  audio_streams?: AudioStreamView[] | null
  /// 字幕列表：内封轨 + 外挂文件
  subtitle_streams: SubtitleStreamView[]
  /// 当前成员起播时会放的音轨 / 字幕与原因；null = 原盘或尚未探测轨道（界面退回按片源标注的默认旗标展示）
  playback_defaults?: TrackDefaultsView | null
  /// 有效章节列表（内嵌或按时长合成）；null=所在库未开启「生成章节」或尚未探测
  chapters?: ChapterView[] | null
  added_at: string
}

/** 图廊按条目分的一组（一部作品的全部图），墙上是一段标题 + 一面瀑布流。 */
export interface LibraryGalleryGroupView {
  media_item_id: number
  /// 这一组的详情落点库：段标题与灯箱「前往详情」的地址按它拼。单库图廊恒等于本库；「我的收藏」的图廊跨库，每组各带自己的落点库
  library_id: number
  kind: MediaKind
  title: string
  year?: number | null
  /// 当前观看者是否收藏了这部作品：瓦片右上角的心形角标与灯箱里那颗心的初始态
  is_favorite: boolean
  images: LibraryGalleryImageView[]
}

/** 图廊里的一张图：条目的海报 / 剧照 / 分集剧照 / 章节场景图之一。 */
/** 影视库与其他库的「图床浏览模式」把这些图铺平成一面瀑布流墙，灯箱里 */
/** 除了看图还能一键进条目详情、从这一帧起播——所以每张图都带着它在 */
/** 作品里的坐标（季集号 + 起播秒数），前端拼播放地址时不必再查详情。 */
export interface LibraryGalleryImageView {
  /// poster=海报 / backdrop=横幅剧照 / still=分集剧照 / chapter=章节场景图
  kind: string
  /// 图片地址：本地资产相对路径或 TMDB 图床绝对地址（前端走缓存代理）
  url: string
  /// 宽高比：海报按真实像素或 2:3 惯例，剧照与场景图 16:9
  aspect: number
  /// 角标文案：海报 / 剧照 / 第 N 集 / 章节标题
  label: string
  /// 分集剧照与剧集章节图所属的季号
  season?: number | null
  /// 分集剧照与剧集章节图所属的集号
  episode?: number | null
  /// 章节场景图对应的起播秒数（「从此处播放」）；其它图为 null
  t_seconds?: number | null
}

/** 海报墙 A-Z 索引条的一档（按标题排序下的首字母分组）。 */
export interface LibraryIndexEntryView {
  /// 首字母档：A-Z，落不进的（数字/符号/假名等）为 #
  initial: string
  /// 该档的条目数
  count: number
  /// 该档第一格在按标题排序中的位置——即 /items?sort=title&offset= 的取值
  offset: number
}

/** 剧集库海报 hover 的在位库存完整度摘要。 */
export interface LibraryInventorySummaryView {
  /// 在位正季数；仅特别篇时为 0
  season_count: number
  /// 摘要覆盖的在位去重集数
  episode_count: number
  /// 只覆盖一季时的季号（0=特别篇）；多季为 NULL
  season_number?: number | null
  /// 摘要所覆盖季的 TMDB 已知总集数；任一季未知时为 NULL
  total_episode_count?: number | null
  /// 是否覆盖 TMDB 已知的全部正季
  all_seasons_owned: boolean
  /// 摘要所覆盖的每一季是否都已收齐
  all_episodes_owned: boolean
}

/** 条目详情页的完整数据：基本信息 + 本地刮削元数据 + 逐文件真实规格。 */
/** 图片优先级：条目目录里的本地美术图（poster.jpg/fanart.jpg，走 */
/** /libraries/.../artwork 接口的相对路径）优先，其次 TMDB 图床绝对地址 */
/** ——前端按"是否 http 开头"区分两种加载方式。 */
export interface LibraryItemDetailView {
  media_item_id: number
  kind: MediaKind
  /// 身份来源：tmdb / local（local=未识别或其他库）
  source: string
  /// TMDB 条目 ID；本地来源条目为 null
  tmdb_id?: number | null
  imdb_id?: string | null
  douban_id?: string | null
  title: string
  original_title: string
  year?: number | null
  poster_url?: string | null
  backdrop_url?: string | null
  /// 片名 Logo（透明底 PNG）；没有时前端显示文字片名
  logo_url?: string | null
  /// 主图宽高比（同海报墙）
  primary_aspect: number
  /// NFO 本地刮削元数据；目录里没有可用 NFO 时为 null
  local_meta?: LocalMetaView | null
  /// 条目在磁盘上的目录（删除确认时展示）
  entry_dirs: string[]
  files: LibraryFileView[]
  file_count: number
  total_size_bytes: number
  /// 季号列表（电影为空）
  seasons: number[]
  /// 该条目正在后台刮削元数据
  scraping: boolean
  /// 刮削当前阶段；没在刮为 null
  scraping_phase?: string | null
  /// 章节场景图正在后台生成
  chapters_pending: boolean
  /// 所属作品系列名；不属于任何系列为 null
  series_name?: string | null
  /// 所属系列合集的 id；本库没生成该合集时为 null
  series_collection_id?: number | null
  /// 这部片所属的合集（不含系列与「我的收藏」）
  collections: ItemCollectionRef[]
}

/** 库内一个媒体条目的库存聚合（单库海报墙的一格）。 */
export interface LibraryItemView {
  media_item_id: number
  kind: MediaKind
  /// 所属库；单库墙上恒为该库
  library_id?: number | null
  /// 身份来源：tmdb / local（local=未识别或其他库）
  source: string
  /// TMDB 条目 ID；本地来源条目为 null
  tmdb_id?: number | null
  title: string
  year?: number | null
  poster_url?: string | null
  backdrop_url?: string | null
  /// 主图宽高比（真实像素尺寸或来源惯例），卡片按它排版
  primary_aspect: number
  /// 内容日期：影视为上映/首播日，本地条目为拍摄/录制日（图片库按月分组与悬停日期用）
  release_date?: string | null
  /// 评分（0~10，TMDB 或 NFO）；海报墙默认不印，悬停层与按评分排序/筛选时才显示
  rating?: number | null
  /// 主图的微缩占位图 data URI（约 300 字节）：缩略图到达前铺一层模糊色块
  poster_blur?: string | null
  /// 条目的首个在位文件 id（一文件一条目的库用它取原图；多文件条目取最早入账的）
  primary_file_id?: number | null
  file_count: number
  total_size_bytes: number
  seasons: number[]
  episode_count: number
  resolutions: string[]
  /// 标记 missing 的文件数（>0 时前端提示）
  missing_count: number
  /// 剧集播出状态：airing=在播 / ended=完结；电影或状态未知为 NULL
  air_status?: string | null
  /// 已播出但所有媒体库里都没有的正季集数（电影恒 0）——「补齐缺集」的依据
  missing_episode_count: number
  /// 最近一次文件入账时间（首页「最近添加」排序依据）
  added_at?: string | null
  /// 当前观看者是否收藏了这部作品（海报右上角那颗心）；不认人的调用恒 False
  is_favorite: boolean
  /// 最近一次可追溯入库批次的剧集摘要；NULL=电影或迁移前旧台账
  recent_addition?: LibraryRecentAdditionView | null
  /// 本库在位剧集相对 TMDB 季集结构的完整度摘要；电影或无有效集号为 NULL
  inventory_summary?: LibraryInventorySummaryView | null
  /// 在位但尚未探出介质规格的文件数——扫描补探阶段前端据此把「还在处理」的条目排到海报墙前面并点亮标记
  probe_pending_count: number
}

/** 创建/更新库的请求体。kind/source 仅创建时生效，更新时忽略（创建后不可改）。 */
export interface LibraryPayload {
  /// 库的展示名（全局唯一）
  name: string
  /// 内容形态：movie=电影 / tv=剧集 / video=其他（无结构假设）
  kind: MediaKind
  /// 身份来源：tmdb / local；不传按形态默认（movie、tv → tmdb，video → local）。与 kind 一起定位库的能力档案，创建后不可改
  source?: string | null
  /// 缺图时是否从视频抓帧生成缩略图：本地来源内容的封面、剧集库里 TMDB 没有剧照的分集（网络挂载库抓帧等于全量下载，可关）；不传表示不改动，新建时默认开启
  generate_thumbnails?: boolean | null
  /// 是否生成并展示视频章节：场景图在后台低优先级作业里抓（每个文件按章节数 seek 若干次），详情页章节横排、图廊章节图与 Jellyfin 合成章节都随它开关；关闭时文件自带的内嵌章节仍供播放器跳章，已生成的图保留。从关改为开会立即在后台补齐库内已有视频的章节，从开改为关会停掉进行中的章节生成。不传表示不改动，新建时默认关闭
  extract_chapter_images?: boolean | null
  /// 是否识别剧集的片头片尾（只对剧集库起作用）：每集入库时算一次音频指纹、整季比对，播放时给「跳过片头」与提前的「下一集」。从关改为开会在后台补齐库内已有剧集，从开改为关会停掉进行中的识别、播放时不再给按钮（已算的结果保留）。不传表示不改动，新建时默认开启
  detect_media_segments?: boolean | null
  /// 是否从首页「最近添加」等汇总里排除该库；不传表示不改动，新建时默认关闭
  exclude_from_home?: boolean | null
  /// 是否按作品系列自动生成合集（《哈利·波特》这种）。这是**展示**偏好：关掉之后系列信息照常落库、NFO 的 <set> 照常写，只是合集页不自动多出几十个系列；重新打开会把已有的系列补齐，不重新联网刮削。不传表示不改动，新建时默认开启
  auto_series_collections?: boolean | null
  /// 可见范围：everyone=对全部成员自动开放（含以后新建的成员）/ selected=只对 member_ids 里显式授权的成员开放；不传表示不改动，新建时默认 everyone
  access_mode?: string | null
  /// 超管本人是否可浏览本库内容（管理权不受影响）；不传表示不改动，新建时默认可浏览
  admin_visible?: boolean | null
  /// 显式授权的成员 id（整体覆盖式；与成员管理页的可见库白名单是同一份数据）；不传表示不改动
  member_ids?: number[] | null
  /// 根路径列表（绝对路径），第一个为主根——新入库落在这里
  root_paths: string[]
  /// 收藏范围条件（条件间 AND、条件内任一匹配）；genres 存 TMDB 类型 ID，origin_countries 存国家码；空=未声明
  match_rules?: Record<string, JsonValue>[] | null
  /// 扫描后自动清理已确认丢失的库存记录（只删台账不动磁盘，不可恢复）；不传表示不改动，新建时默认关闭
  auto_clear_missing?: boolean | null
  /// 库级刮削偏好覆盖（语言/选图/命名/目录写入，即「刮削与整理」的全部字段）；不传=不改动，空对象=清空覆盖回到全跟全局。语言与选图这类产物挂全局条目的设置，按条目的**刮削归属库**生效
  scrape_overrides?: Record<string, JsonValue> | null
  /// 是否启用实时文件监控（关闭后该库不建 watchdog 监听，靠定期对账与手动扫描发现新文件——SMB/NFS 网络挂载建议关闭）；不传表示不改动，新建时默认开启
  realtime_watch?: boolean | null
}

/** 一个库的完整入库链路结论。 */
export interface LibraryPipelineView {
  library_id: number
  library_name: string
  kind: string
  is_default: boolean
  mode: string
  /// 投递基底目录（movieclaw 视角）
  path?: string | null
  /// 库主根（入库节点的落点）
  library_root?: string | null
  /// 命中自定义目录规则时的整理落点（非空时转移段不直接入库，外部流转后回库根入账）
  staging_path?: string | null
  /// 全链路最坏状态
  status: string
  /// 「订阅命中本库会发生什么」的一句话叙事（正向可预期）
  narrative: string
  checks: HealthCheckView[]
}

/** 让条目进入「最近添加」的最后一批剧集的紧凑摘要。 */
export interface LibraryRecentAdditionView {
  season_count: number
  episode_count: number
  /// 仅涉及一季时的季号；跨季为 NULL
  season_number?: number | null
  /// 同季连续批次的起始集；否则 NULL
  first_episode_number?: number | null
  /// 同季连续批次的结束集；否则 NULL
  last_episode_number?: number | null
  /// 本批是否完整覆盖该季 TMDB 已知集数
  complete_season: boolean
}

/** 筛空之后的出路。 */
/** 不渲染空墙，而是告诉用户「放宽哪一条能救回多少部」。**只列救得回内容的 */
/** 条件**——多维交叉时经常出现"去掉它还是 0 部"的剔除项，把它们摆出来是 */
/** 噪音不是建议；一条都救不回时 suggestions 为空，前端只留「清空全部条件」。 */
export interface LibraryRelaxView {
  /// 当前条件下的命中数（调用方通常在它为 0 时才用本接口）
  total: number
  /// 按能救回的数量倒序，最多三条
  suggestions: RelaxSuggestionView[]
}

/** 媒体库重排的请求体：必须一次给全所有库的 id（漏/多/重复都拒绝）。 */
export interface LibraryReorderPayload {
  /// 全部媒体库 id 的目标顺序（越靠前展示越靠前）
  ordered_ids: number[]
}

/** 命中证据：这条结果为什么被搜出来（保留原始名称，前端无需知道拼音索引的实现）。 */
export interface LibrarySearchMatch {
  type: string
  source_field: string
  matched_name: string
  label: string
  person_id?: number | null
}

/** 库内搜索的一条影片命中（条目 + 拥有它的库 id 列表）。 */
export interface LibrarySearchHit {
  item: LibraryItemView
  library_ids: number[]
  match: LibrarySearchMatch
}

/** 库内搜索命中的人物：tmdb_person_id 有值时前端链到库内影人页（与演职员入口同一页）。 */
export interface LibrarySearchPerson {
  id: number
  /// TMDB 影人 ID；连旧服务端（还没有这个字段）时为空，画成不可点的静态块
  tmdb_person_id?: number | null
  name: string
  profile_path?: string | null
  /// 头像地址：本地已下载给本地，否则给 TMDB 图床；没有照片为空
  avatar_url?: string | null
  item_count: number
  match: LibrarySearchMatch
}

/** 库内搜索的联想词（title / person 两类）。 */
export interface LibrarySearchSuggestion {
  type: string
  text: string
  /// 为什么联想到它，与结果卡片同一份命中原因（如「演员：李一桐」）
  label?: string | null
  media_item_id?: number | null
  person_id?: number | null
}

/** `GET /search/library`：名称、别名、拼音及人物混合搜索（相关度排序，稳定分页）。 */
export interface LibrarySearchView {
  query: string
  person_id?: number | null
  items: LibrarySearchHit[]
  people: LibrarySearchPerson[]
  suggestions: LibrarySearchSuggestion[]
  next_cursor?: string | null
  /// 名称索引尚有待更新实体；查询已合并最新名称
  index_pending: boolean
}

/** 库存统计快照（台账变化时重算，查询时直接读取 library 表）。 */
/** **扫描进行中读到的是中间态，不是结论**：扫描按事务分批落账，文件先入账、 */
/** 随后才识别，所以 ``unidentified_count`` 在扫描途中会先冲高再回落（一次 */
/** 上万文件的扫描中途读到两千多、扫完是 0，两个数都是真的）。要判断"这个库 */
/** 还有多少待识别"，先看同一响应里的 ``scanning``：为 true 时这几个数只能当 */
/** 进度看。刻意不把统计改成"只在扫描结束后更新"——那会让扫描期间完全看不到 */
/** 进展，比抖动更糟。 */
export interface LibraryStats {
  /// 在位且已识别的媒体条目数
  item_count: number
  /// 在位文件总数（含待识别）
  file_count: number
  /// 在位文件总大小（字节）
  total_size_bytes: number
  /// 在位待识别文件数（不含已忽略）；scanning=true 时是中间态，扫完才是结论
  unidentified_count: number
  /// 标记 missing 的文件数（缺失清单入口）
  missing_count: number
  /// 在位且被用户忽略的文件数（不再参与识别，可在已忽略清单恢复）
  ignored_count: number
}

export interface LibraryView {
  id: number
  name: string
  kind: MediaKind
  /// 身份来源：tmdb / local
  source: string
  capabilities: LibraryCapabilitiesView
  /// 缺图时是否抓帧生成缩略图（本地内容封面、TMDB 无剧照的分集）
  generate_thumbnails: boolean
  /// 是否生成并展示视频章节（默认关，按库打开）
  extract_chapter_images: boolean
  /// 是否识别剧集的片头片尾（默认开，只对剧集库起作用）
  detect_media_segments: boolean
  /// 是否从首页汇总里排除
  exclude_from_home: boolean
  /// 是否按作品系列自动生成合集（展示偏好）
  auto_series_collections: boolean
  /// 可见范围：everyone=所有成员 / selected=指定成员
  access_mode: string
  /// 超管本人是否可浏览本库内容
  admin_visible: boolean
  /// 显式授权的成员 id（仅管理员可见，成员端恒空）
  member_ids: number[]
  /// 当前请求主体能否浏览本库内容。成员端恒 true（看不到的库根本不在列表里）；超管端为 false 时表示只有管理权：首页显示带锁的管理卡片，海报墙/详情/播放不可用
  viewer_access: boolean
  root_paths: string[]
  /// 主根路径（root_paths 第一项）
  primary_root?: string | null
  is_default: boolean
  /// 收藏范围条件
  match_rules: Record<string, JsonValue>[]
  /// 扫描后自动清理已确认丢失的库存记录
  auto_clear_missing: boolean
  /// 是否启用实时文件监控
  realtime_watch: boolean
  /// 任一根路径落在网络挂载（NFS/SMB/fuse）上。这种库实时监控收不到远端变更，新文件靠定期对账发现——界面据此把话说清楚，而不是让开关看起来有效
  network_mount: boolean
  /// 封面是用户上传的自定义图（而非自动拼贴）。前端据此决定「恢复自动拼贴」按钮的形态，以及空库要不要照样出图
  custom_cover: boolean
  /// 库级刮削偏好覆盖；空对象 = 全跟全局设置
  scrape_overrides: Record<string, JsonValue>
  stats: LibraryStats
  /// 是否正在扫描
  scanning: boolean
  /// 扫描实时进度
  scan_progress?: ScanProgressView | null
  /// 最近一次扫描结论
  last_scan?: LastScanView | null
  /// 是否正在整理文件名
  organizing: boolean
  /// 整理实时进度（与扫描进度同构）
  organize_progress?: ScanProgressView | null
  /// 最近一次整理结论
  last_organize?: LastOrganizeView | null
  /// 整库元数据刷新状态；没在刷为 null
  metadata_refresh?: MetadataRefreshView | null
  /// 整库生成章节的作业状态（排队/进行中）；没在生成为 null
  chapter_job?: ChapterJobView | null
  created_at: string
  updated_at: string
}

/** 保存 AI 设定：各用途的默认模型引用（取自 llm.models 的 ref），传 null 清除。 */
export interface LlmDefaultsPayload {
  /// 智能体默认模型引用
  agent_model?: string | null
  /// 字幕处理默认模型引用
  subtitle_model?: string | null
}

/** AI 设定（各用途默认模型）的对外视图。 */
/** ``*_model`` 是存下来的引用：首次接入供应商时自动设为其目录里第一个模型， */
/** 之后由用户改；一个实例都没有时为 null。``effective_*`` 是运行时实际生效的 */
/** 引用，正常与前者一致，只在预设目录变动等漂移场景下按最早实例兜底。 */
export interface LlmDefaultsView {
  /// 智能体默认模型引用（null = 未设置）
  agent_model?: string | null
  /// 字幕处理默认模型引用（null = 未设置）
  subtitle_model?: string | null
  /// 智能体实际生效的引用
  effective_agent_model?: string | null
  /// 字幕处理实际生效的引用
  effective_subtitle_model?: string | null
}

/** 对话框模型选择器的一个选项（口径见 services.llm_config 模块说明）。 */
export interface LlmModelOptionView {
  /// 提交给 session.start 的模型引用：裸模型 id，或同 id 在多个实例时的「实例名/模型id」
  ref: string
  /// 展示文案：裸模型 id，冲突时为「模型id（实例名）」
  label: string
  /// 模型 id
  model_id: string
  /// 所属实例 id
  provider_id: number
  /// 所属实例名
  provider_name: string
  /// 是否为智能体默认模型（AI 设定），清单里恰有一个
  is_default: boolean
  /// 该模型的思考档位菜单；空 = 隐藏档位选择器
  thinking_levels: string[]
}

/** 供应商预设的对外视图：设置页用它渲染类型选项与模型目录。 */
export interface LlmPresetView {
  id: string
  display_name: string
  base_url?: string | null
  requires_base_url: boolean
  default_user_agent: string
  models: ModelInfo[]
}

/** 新增 / 编辑 LLM 供应商实例的请求体。 */
/** API Key 出于安全不回显，编辑时需要重新填写。 */
export interface LlmProviderPayload {
  /// 实例名（全局唯一，不含斜杠），如「官方 OpenAI」
  name: string
  /// 供应商类型：openai / bailian / openai_compat
  provider_type: string
  /// API 端点（留空用预设默认）
  base_url?: string | null
  /// 自定义 User-Agent 请求头（留空使用 openai SDK 自带 UA）
  user_agent?: string | null
  /// API Key
  api_key: string
  /// 连接测试用的模型 id；留空取目录里第一个（预设目录或自定义目录）
  default_model?: string | null
  /// 自定义模型目录 JSON 数组，元素形如 {"id":"模型id","context_window":131072,"max_output_tokens":8192}（openai_compat 端点至少一条）
  extra_models?: ModelInfoInput[] | null
}

/** LLM 供应商实例的对外视图（**脱敏**：绝不回传 API Key）。 */
export interface LlmProviderView {
  id: number
  /// 实例名（全局唯一，路由键）
  name: string
  provider_type: string
  base_url?: string | null
  /// 自定义 User-Agent；null 表示用 SDK 默认 UA
  user_agent?: string | null
  /// 连接测试用的模型 id（目录里第一个）
  default_model: string
  status: ConfigStatus
  /// 是否可用 = 连接测试通过（status=active）
  usable: boolean
  /// 最近测试失败原因（清晰中文）
  last_error?: string | null
  last_checked_at?: string | null
  /// 最近验证成功时端点上报的可用模型列表
  available_models?: string[] | null
  /// 用户补录的自定义模型目录（含参数）
  extra_models: ModelInfo[]
  created_at: string
  updated_at: string
}

/** 跨库「按类型找」的一格：某类型下的部数与封面（`GET /libraries/kinds/{kind}/genres`）。 */
export interface LibraryKindGenreView {
  /// TMDB 类型 id；点进去带 g=value 开墙
  value: string
  /// 类型中文名
  label: string
  /// 跨库去重后的部数
  count: number
  /// 封面那部片的条目 id；没有可用剧照时为空
  cover_item_id?: number | null
  /// 封面那部片的片名
  cover_title?: string | null
  /// 封面剧照（横版）；本地资产优先，回落 TMDB 图床
  cover_url?: string | null
}

/** 条目的展示元数据：本地 NFO > 库内刮削档案 > TMDB 实时兜底； */
/** 三个来源都拉不到时整体为 null（docs/design/metadata.md 第 5 节）。 */
export interface LocalMetaView {
  plot?: string | null
  rating?: number | null
  runtime_minutes?: number | null
  genres: string[]
  directors: string[]
  /// 从 person 关系表读取的结构化导演；空列表时前端回退 directors 姓名
  director_credits: DirectorView[]
  actors: ActorView[]
  /// 来源 NFO 文件名（source=nfo 时给出）
  nfo_name: string
  /// 信息出处：nfo=本地刮削 / db=库内档案 / tmdb=实时兜底
  source: string
}

/** 某天的日志内容（可能只是末尾片段，truncated 标记是否被截断）。 */
export interface LogContent {
  day: string
  lines: string[]
  total_lines: number
  truncated: boolean
  size_bytes: number
}

/** 一个可查看的日志日期（对应磁盘上的一个日志文件）。 */
export interface LogDay {
  day: string
  size_bytes: number
}

export interface LogDayList {
  days: LogDay[]
}

/** 「我的设备」列表里的一台设备（登录设备或 Jellyfin 播放器）。 */
export interface LoginDeviceView {
  /// 设备 id：登录设备为 ld-<n>，Jellyfin 播放器为 jf-<n>
  id: string
  /// web / ios / tvos / android / cli / worker / manual / jellyfin
  kind: string
  /// 给人看的类型名：浏览器、iOS App、命令行、Infuse……
  kind_label: string
  /// login=用密码登录的（改密即下线）；paired=配对或手工创建的（改密默认保留）
  family: string
  name: string
  /// full=与主人相同的权限；transcode=只能转码
  scope: string
  platform?: string | null
  client_version?: string | null
  created_at: string
  last_seen_at?: string | null
  last_seen_ip?: string | null
  /// 网页会话的过期时间
  expires_at?: string | null
  /// 是不是发起本次请求的这台设备
  current: boolean
  /// 此刻是否有一条活着的转码控制连接（只有转码器有长连接；其余设备恒为 false，在不在用看 last_seen_at）
  connected: boolean
  /// 能否改名（Jellyfin 播放器的名字由客户端上报，不能改）
  renamable: boolean
  /// 主人：成员 id；0 = 超管
  owner_id: number
  owner_username: string
  owner_nickname: string
}

export interface LoginRequest {
  username: string
  password: string
  /// 记住我：会话有效期 7 天 → 30 天
  remember?: boolean | null
}

/** 退出登录。默认只退当前账号并切到袋子里的下一个；all=True 清空全部。 */
export interface LogoutRequest {
  /// true=退出本浏览器里的全部账号
  all?: boolean | null
}

/** 预检未收敛时留给用户确认的 TMDB 候选。 */
export interface ManualDownloadCandidateView {
  tmdb_id: number
  kind: string
  title: string
  year?: number | null
  episode_count?: number | null
  poster_url?: string | null
}

/** 手动下载的识别预检输入：搜索结果已解析出的身份线索 + 用户的搜索词。 */
/** 种子身份（kind/title/year）三件套齐全时先按它自动收敛；收敛失败或种子 */
/** 根本没解析出身份时，改用 ``hint``（用户在搜索框里输入的关键词，或在弹窗 */
/** 里「换个词搜」的输入）检索 TMDB，把结果作为候选请用户点选确认——乱码/ */
/** 拼音命名的种子，用户自己输入的片名往往才是最可靠的线索。 */
export interface ManualDownloadTargetPayload {
  /// 搜索结果识别出的媒体类型；未解析出身份时缺省
  kind?: string | null
  /// 搜索结果识别出的主标题；未解析出身份时缺省
  title?: string | null
  /// 搜索结果识别出的发行/首播年份
  year?: number | null
  /// 种子副标题（中文别名等识别补强）
  subtitle?: string | null
  /// 搜索关键词：自动识别失败时据此检索 TMDB 给出候选
  hint?: string | null
  /// 预检指定下载器；缺省用默认下载器
  downloader_id?: number | null
  /// 用户从本次识别候选中确认的 TMDB 条目 ID
  selected_tmdb_id?: number | null
  /// 确认候选的媒体类型；缺省同 kind
  selected_kind?: string | null
}

/** 手动下载的「识别 → 路由 → 投递目录」预检结论。 */
export interface ManualDownloadTargetView {
  status: string
  tmdb_id?: number | null
  kind?: string | null
  title?: string | null
  year?: number | null
  candidates: ManualDownloadCandidateView[]
  library_id?: number | null
  library_name?: string | null
  mode?: string | null
  /// movieclaw 视角的实际投递目录
  path?: string | null
  /// 条目目录的完整路径预览（按生效的命名模板渲染）；前端展示投递落点时用它，不要自己拼「标题 (年份)」
  entry_dir?: string | null
  /// 自定义目录规则的整理落点
  staging_path?: string | null
  /// 是否命中媒体库收藏范围
  route_matched?: boolean | null
  /// 媒体库路由理由
  route_reason?: string | null
  /// 当前选择的下载器和投递配置能否自动入库
  ok: boolean
  /// 不可自动入库时的中文指引
  warning?: string | null
}

/** MKV 精简索引（docs/design/playback-qoe.md §9.12）：只含视频轨索引点的 Cues 元素。 */
/** App 的播放引擎在解复用器读 SeekHead 登记的 Cues 位置时直接给这份，不必再下载原索引 */
/** （字幕轨多的片子原索引有几百 KB 到几 MB，外网慢时要单独下好几秒）。 */
/** 索引点的数值与原文件逐位一致。 */
export interface MatroskaCuesView {
  offset: number
  data: string
  original_bytes: number
}

/** 播放会话 / 文件下载指向的媒体条目摘要。 */
export interface MediaActivityTarget {
  media_item_id: number
  library_id?: number | null
  browsable: boolean
  kind: MediaKind
  title: string
  year?: number | null
  poster_url?: string | null
  season_number: number
  episode_number: number
  episode_title?: string | null
}

/** 活动页「观看」视角的实时快照：正在播放与正在下载。 */
/** 历史（每场一行的播放记录）走 ``PlaybackHistoryView``，本载荷只装页面 8 秒 */
/** 轮询真正要刷新的实时部分。 */
export interface MediaActivityView {
  sessions: ActivePlaybackSessionView[]
  downloads: ActiveFileDownloadView[]
  /// 不在你可见范围内的正在播放数
  hidden_session_count: number
  /// 不在你可见范围内的正在下载数
  hidden_download_count: number
}

/** 弹层与列表共用的条目摘要。 */
export interface MediaBrief {
  media_item_id: number
  kind: MediaKind
  tmdb_id: number
  douban_id?: string | null
  title: string
  original_title: string
  year?: number | null
  /// 完整海报 URL（按配置的图床基址拼好）
  poster_url?: string | null
  /// 宽幅剧照 URL（w1280，沉浸场景可换 original 档）
  backdrop_url?: string | null
  /// 片名 Logo URL（透明底 PNG）；没有时前端显示文字片名
  logo_url?: string | null
  status?: string | null
}

/** 演职员表的一位人物：姓名 + 可选角色 + 头像。 */
/** 发现页详情要按「演职员横滚条」呈现（与媒体库条目详情同一套版式）， */
/** 导演与演员都需要结构化头像和人物 ID；演员额外携带角色名。头像在数据源 */
/** 里常常缺失（小众条目、配音演员），前端按占位渲染， */
/** 不必为此过滤掉这个人——名字与角色本身就是有效信息。 */
export interface MediaCastMember {
  /// 人物姓名
  name: string
  /// 饰演角色；数据源未提供为空
  role?: string | null
  /// 头像地址；数据源未提供为空
  avatar_url?: string | null
  /// TMDB 影人 ID；有值时前端把这一格链到人物页。豆瓣来源没有此 id
  tmdb_person_id?: number | null
}

/** 一张剧照/海报：横滚条用预览图，灯箱看原图。 */
export interface MediaImage {
  /// 缩略预览（剧照 w780 / 海报 w342）
  preview_url: string
  /// 原图（original，灯箱全屏用）
  full_url: string
  width: number
  height: number
}

/** 内容形态：电影 / 剧集 / 其他视频 / 图片（docs/design/library-other-kind.md 3.1、 */
/** library-photo-kind.md 2.1）。 */
/** ``movie`` 与 ``tv`` 的取值与 TMDB 的路径段一致，在 ``source=tmdb`` 的 */
/** 识别/刮削路径里可直接拼接 URL；``video`` 是没有结构假设的单本视频 */
/** （家庭录像、自录内容），``photo`` 是单张图片（照片、截图），两者都只在 */
/** 本地来源下出现，永远不会进 TMDB 请求。形态描述结构，不描述题材也不 */
/** 描述来源。 */
export type MediaKind = string;

/** 发现详情跳转到一个本地媒体库条目所需的最小身份信息。 */
export interface MediaLibraryLink {
  /// 媒体库 id
  library_id: number
  /// 媒体库展示名称
  library_name: string
  /// 本地媒体条目 id
  media_item_id: number
}

/** 发现卡片对应的轻量库存摘要。 */
/** 这是发现页与本地库存之间唯一共享的列表级契约：只表达是否存在在位 */
/** 文件及其聚合数量，不携带文件路径、介质规格或探测 JSON，避免海报墙 */
/** 查询扩大为逐条目明细读取。 */
export interface MediaLibraryStatus {
  /// 本地媒体条目 id，用于详情深链
  media_item_id: number
  /// 包含在位文件的媒体库数量
  library_count: number
  /// 在位文件数量
  file_count: number
}

/** 媒体数据来源；ID 只在同一来源内部唯一。 */
export type MediaSource = string;

/** 标注弹窗预览的一行：将被标注的文件（片源未知或此前人工标注）。 */
export interface MediaSourceAnnotationCandidateView {
  file_id: number
  file_name: string
  episode_number: number
  size_bytes: number
  /// 当前片源；null=未知
  media_source?: string | null
  /// 当前值是否为此前的人工标注
  media_source_manual: boolean
}

/** 整季片源人工标注（docs/design/media-source-annotation.md §4）。 */
/** 值域与洗版片源档阶梯对齐；``user-lowest`` 是「不确定，按最低档处理」 */
/** 的显式哨兵（T0，会触发整季自动洗版重下）。 */
export interface MediaSourceAnnotationPayload {
  /// 媒体条目 id
  media_item_id: number
  /// 季号；电影固定 0
  season_number: number
  /// 标注的片源档
  media_source: string
}

/** 详情页的一段预告片/花絮。 */
/** TMDB 只给出 YouTube 的视频 key，**不提供可直接播放的视频流**，因此播放这一步 */
/** 依赖浏览器自身能连上 YouTube——服务端配的代理帮不上忙。封面图则不同：它是 */
/** 普通图片，前端统一走 /images/proxy 由服务端回源缓存，所以只要服务端能出网， */
/** 即使浏览器连不上 YouTube，预告片卡片也照样完整展示并给出外链入口。 */
export interface MediaVideo {
  /// YouTube 视频 ID（前端当作不透明键使用）
  key: string
  /// 视频标题，TMDB 原样给出（多为英文）
  name: string
  /// 中文类型标签：预告片 / 先导预告 / 片段 / 花絮 / 幕后
  kind: string
  /// YouTube 封面图；4:3 带上下黑边，前端按 cover 裁切即得 16:9 画面
  thumbnail_url: string
  /// 内嵌播放地址（youtube-nocookie，不落跟踪 cookie）
  embed_url: string
  /// YouTube 站内地址，供无法内嵌时外链打开
  watch_url: string
}

/** 新建成员：用户名 + 初始密码（前端默认一键生成随机密码）。 */
export interface MemberCreateRequest {
  /// 登录名，创建后不可改
  username: string
  /// 初始密码，至少 8 位
  password: string
  /// 展示昵称，可留空
  nickname?: string | null
}

/** 重置密码的返回体：新密码明文仅此一次，请立即复制发给成员。 */
export interface MemberPasswordResetView {
  id: number
  username: string
  /// 新密码明文；服务端只存哈希，之后无法再次查看
  password: string
}

/** 启用 / 停用成员。停用即时踢下线，数据全部保留。 */
export interface MemberStatusRequest {
  enabled: boolean
}

/** 编辑成员：None 字段不改动；白名单为整体覆盖式保存。 */
export interface MemberUpdateRequest {
  nickname?: string | null
  allow_subscribe?: boolean | null
  allow_search?: boolean | null
  allow_direct_download?: boolean | null
  /// True=全部库可见（含未来新建）；False=按 library_ids 白名单
  all_libraries?: boolean | null
  /// 可见库白名单（整体覆盖）；仅 all_libraries=False 时生效
  library_ids?: number[] | null
  /// True=全部站点可用；False=按 site_ids 白名单
  all_sites?: boolean | null
  /// 可用站点白名单（整体覆盖）；仅 all_sites=False 时生效
  site_ids?: string[] | null
  /// 内容年龄上限（岁）。设了之后，超过这个年龄分级的作品在海报墙、搜索、合集、Jellyfin、条目详情与起播六处一律不可见。**传 -1 表示取消上限**（传 null 是「不改动」，两者不是一回事）
  content_age_limit?: number | null
  /// 设了年龄上限时，未分级的作品是否仍可见。默认关闭——大量中文影片在 TMDB 上没有分级信息，「我不确定的一律不给看」才是家长要的默认值
  allow_unrated?: boolean | null
}

/** 成员详情（管理页列表与详情共用）。 */
export interface MemberView {
  id: number
  username: string
  nickname: string
  avatar_url?: string | null
  status: string
  /// 最近登录时间；None=从未登录
  last_login_at?: string | null
  allow_subscribe: boolean
  allow_search: boolean
  allow_direct_download: boolean
  all_libraries: boolean
  library_ids: number[]
  all_sites: boolean
  site_ids: string[]
  /// 内容年龄上限（岁）；null=不限
  content_age_limit?: number | null
  /// 设了上限时未分级的作品是否可见
  allow_unrated: boolean
  created_at: string
  /// 登录着这个账号的设备数（网页、App、命令行、播放器）
  device_count: number
}

/** 整库刷新的实时状态——全量重刷很慢，用户要看到"到哪部了、在做什么"。 */
/** 随库列表一并返回（见 LibraryView.metadata_refresh），媒体库首页的库卡片 */
/** 因此不必额外请求就能显示刷新进度；单库页另有专用端点做 2 秒级的阶段 */
/** 刷新（首页 10 秒一轮的节奏跟不上阶段变化）。 */
export interface MetadataRefreshView {
  refreshing: boolean
  /// 已完成条目数（含失败）
  processed: number
  total: number
  /// 刮削失败的条目数（多为 TMDB 不可达）
  failed: number
  /// 已请求停止，正在收尾
  stopping: boolean
  /// 正在处理的条目及其阶段
  active: RefreshActiveView[]
}

/** 刮削管线的用户偏好。所有字段的默认值即当前写死的行为。 */
export interface MetadataScrapeSetting {
  /// 元数据语言优先级（1~3 项）；首位为主语言（请求语言），空 = 跟随环境变量 TMDB_LANGUAGE + en-US 兜底
  language_priority: string[]
  /// 内容分级的地区优先级：按顺序取第一个有分级数据的地区
  cert_country_priority: string[]
  /// 海报选择：default=TMDB 默认（与发现页一致）；language=按语言优先级挑选
  poster_mode: string
  /// 海报语言优先级（poster_mode=language 时生效）
  poster_language_priority: string[]
  /// 背景图语言优先级；「无文字」排首位即无文字优先（现状）
  backdrop_language_priority: string[]
  /// 海报最低宽度门槛；0 = 不限制
  poster_min_width: number
  /// 背景图最低宽度门槛；0 = 不限制
  backdrop_min_width: number
  /// 海报档位；空 = 跟随环境变量
  poster_size: string
  /// 背景档位；空 = 跟随环境变量
  backdrop_size: string
  /// 分集剧照档位；空 = 跟随环境变量
  still_size: string
  /// 条目目录模板；空 = 默认 {title} ({year})
  naming_entry_dir: string
  /// 电影文件名模板；空 = 默认 {title} ({year})
  naming_movie_file: string
  /// 季目录模板；空 = 默认 Season {season:02d}
  naming_season_dir: string
  /// 剧集文件名模板；空 = 默认 {title} ({year}) - S{season:02d}E{episode:02d}
  naming_episode_file: string
  /// 镜像条目图片到媒体目录（poster/fanart/clearlogo/季海报）
  mirror_images: boolean
  /// 镜像 NFO 元数据到媒体目录
  mirror_nfo: boolean
  /// 镜像分集剧照（长剧集写入量最大，可单独关）
  mirror_episode_thumbs: boolean
}

/** 刮削管线的用户偏好。所有字段的默认值即当前写死的行为。 */
export interface MetadataScrapeSettingInput {
  /// 元数据语言优先级（1~3 项）；首位为主语言（请求语言），空 = 跟随环境变量 TMDB_LANGUAGE + en-US 兜底
  language_priority?: string[] | null
  /// 内容分级的地区优先级：按顺序取第一个有分级数据的地区
  cert_country_priority?: string[] | null
  /// 海报选择：default=TMDB 默认（与发现页一致）；language=按语言优先级挑选
  poster_mode?: string | null
  /// 海报语言优先级（poster_mode=language 时生效）
  poster_language_priority?: string[] | null
  /// 背景图语言优先级；「无文字」排首位即无文字优先（现状）
  backdrop_language_priority?: string[] | null
  /// 海报最低宽度门槛；0 = 不限制
  poster_min_width?: number | null
  /// 背景图最低宽度门槛；0 = 不限制
  backdrop_min_width?: number | null
  /// 海报档位；空 = 跟随环境变量
  poster_size?: string | null
  /// 背景档位；空 = 跟随环境变量
  backdrop_size?: string | null
  /// 分集剧照档位；空 = 跟随环境变量
  still_size?: string | null
  /// 条目目录模板；空 = 默认 {title} ({year})
  naming_entry_dir?: string | null
  /// 电影文件名模板；空 = 默认 {title} ({year})
  naming_movie_file?: string | null
  /// 季目录模板；空 = 默认 Season {season:02d}
  naming_season_dir?: string | null
  /// 剧集文件名模板；空 = 默认 {title} ({year}) - S{season:02d}E{episode:02d}
  naming_episode_file?: string | null
  /// 镜像条目图片到媒体目录（poster/fanart/clearlogo/季海报）
  mirror_images?: boolean | null
  /// 镜像 NFO 元数据到媒体目录
  mirror_nfo?: boolean | null
  /// 镜像分集剧照（长剧集写入量最大，可单独关）
  mirror_episode_thumbs?: boolean | null
}

/** 清理缺失记录（只删台账行，绝不动磁盘）。media_item_id 缺省 = 清整库。 */
export interface MissingClearPayload {
  /// 所属媒体库 id
  library_id: number
  /// 只清理该条目的缺失记录；不传=清理整库
  media_item_id?: number | null
}

/** 缺失清单里的一个文件。 */
export interface MissingFileView {
  id: number
  file_path: string
  season_number: number
  episode_number: number
  size_bytes: number
}

/** 缺失清单的一行：按媒体条目聚合（一个条目可能缺多个文件）。 */
export interface MissingItemView {
  media_item_id: number
  kind: MediaKind
  /// TMDB 条目 ID；本地来源条目为 null
  tmdb_id?: number | null
  title: string
  year?: number | null
  poster_url?: string | null
  /// 该条目已有订阅时给出——清理记录前提示用户（订阅可能重新下回来）
  subscription_id?: number | null
  files: MissingFileView[]
}

/** 模型目录条目：agent 做上下文预算 / 能力判断的依据。 */
/** token 三元组的语义（None 一律表示官方未单独公布）： */
/** - context_window     输入+输出共享的总上下文； */
/** - max_input_tokens   单独的输入上限（百炼公布，OpenAI 不单独公布）； */
/** - max_output_tokens  单次响应的输出上限，agent 设 max_tokens 的依据。 */
export interface ModelInfo {
  id: string
  context_window?: number | null
  max_input_tokens?: number | null
  max_output_tokens?: number | null
  supports_tools: boolean
  supports_parallel_tool_calls: boolean
  supports_thinking: boolean
  max_thinking_tokens?: number | null
  thinking_control?: ThinkingControl | null
  modalities: string[]
  /// 本模型的思考档位菜单（服务端推导，前端不必理解方言）。
  /// 空列表 = 无菜单，UI 隐藏选择器。budget 制未声明预算上限时退化为
  /// 仅开关（没有预算可分段）。
  thinking_levels: string[]
}

/** 模型目录条目：agent 做上下文预算 / 能力判断的依据。 */
/** token 三元组的语义（None 一律表示官方未单独公布）： */
/** - context_window     输入+输出共享的总上下文； */
/** - max_input_tokens   单独的输入上限（百炼公布，OpenAI 不单独公布）； */
/** - max_output_tokens  单次响应的输出上限，agent 设 max_tokens 的依据。 */
export interface ModelInfoInput {
  id: string
  context_window?: number | null
  max_input_tokens?: number | null
  max_output_tokens?: number | null
  supports_tools?: boolean | null
  supports_parallel_tool_calls?: boolean | null
  supports_thinking?: boolean | null
  max_thinking_tokens?: number | null
  thinking_control?: ThinkingControlInput | null
  modalities?: string[] | null
}

/** 「检查模型更新」的结果（NER 模型独立于代码更新，见设计文档）。 */
export interface ModelUpdateCheckView {
  current_tag?: string | null
  latest_tag: string
  update_available: boolean
  installable: boolean
  published_at: string
}

/** 侧边栏主导航的个人排序。 */
/** 只存**顺序**（导航项 id 的列表），不存导航项本身——导航有哪些项、叫什么、 */
/** 什么权限可见，全部由前端与权限决定，这里存下来的仅仅是"这个人希望它们按 */
/** 什么次序排"。 */
/** 因此本字段是提示而非契约，前端按"排过的按此顺序在前，没排过的按内置默认 */
/** 顺序追加在后"合并（见 apps/web/lib/sidebar-nav.ts）： */
/** - 版本升级新增的导航入口，在存过排序的老用户那里也一定会出现（追加在后）， */
/** 不会因为不在这个列表里而永远消失——这是这类"存死一份顺序"功能最常见的事故； */
/** - 已经不存在的 id（导航项被删）读取时直接忽略，无需迁移。 */
/** 上限 32 只是防脏数据无限增长的安全阀，不是产品限制（主导航实际只有个位数项）。 */
export interface NavUiPrefs {
  /// 侧栏主导航的展示顺序（导航项 id）；空列表 = 用内置默认顺序
  order: string[]
}

/** 侧边栏主导航的个人排序。 */
/** 只存**顺序**（导航项 id 的列表），不存导航项本身——导航有哪些项、叫什么、 */
/** 什么权限可见，全部由前端与权限决定，这里存下来的仅仅是"这个人希望它们按 */
/** 什么次序排"。 */
/** 因此本字段是提示而非契约，前端按"排过的按此顺序在前，没排过的按内置默认 */
/** 顺序追加在后"合并（见 apps/web/lib/sidebar-nav.ts）： */
/** - 版本升级新增的导航入口，在存过排序的老用户那里也一定会出现（追加在后）， */
/** 不会因为不在这个列表里而永远消失——这是这类"存死一份顺序"功能最常见的事故； */
/** - 已经不存在的 id（导航项被删）读取时直接忽略，无需迁移。 */
/** 上限 32 只是防脏数据无限增长的安全阀，不是产品限制（主导航实际只有个位数项）。 */
export interface NavUiPrefsInput {
  /// 侧栏主导航的展示顺序（导航项 id）；空列表 = 用内置默认顺序
  order?: string[] | null
}

/** 保存请求体：与配置域字段一一对应。 */
/** 整体覆盖语义：保存会替换全部字段（未传字段按默认值处理）， */
/** 建议先读取当前配置、改动后整体写回。 */
export interface NetworkConfigPayload {
  /// 代理模式：off=全部直连；env=代理地址取自环境变量；manual=手动填写（需同时给 proxy_url）
  proxy_mode?: string | null
  /// manual 模式的代理地址，如 http://127.0.0.1:7890 或 socks5://…（可含账号密码）
  proxy_url?: string | null
  /// 走代理的服务 id 列表：tmdb / image / douban / llm / telegram / discord / webhook / github / site:<站点id>；不在列表内的服务直连
  proxy_services?: string[] | null
  /// TMDB 接口镜像地址；留空用默认（见读取接口的 mirror_defaults）
  tmdb_api_base_url?: string | null
  /// TMDB 图床镜像地址；留空用默认
  tmdb_image_base_url?: string | null
  /// 豆瓣接口镜像地址；留空用默认
  douban_api_base_url?: string | null
}

/** 读取响应：配置本体 + 前端渲染所需的目录与默认值。 */
export interface NetworkConfigView {
  /// 代理模式：off=全部直连；env=代理地址取自环境变量；manual=手动填写（需同时给 proxy_url）
  proxy_mode: string
  /// manual 模式的代理地址，如 http://127.0.0.1:7890 或 socks5://…（可含账号密码）
  proxy_url: string
  /// 走代理的服务 id 列表：tmdb / image / douban / llm / telegram / discord / webhook / github / site:<站点id>；不在列表内的服务直连
  proxy_services: string[]
  /// TMDB 接口镜像地址；留空用默认（见读取接口的 mirror_defaults）
  tmdb_api_base_url: string
  /// TMDB 图床镜像地址；留空用默认
  tmdb_image_base_url: string
  /// 豆瓣接口镜像地址；留空用默认
  douban_api_base_url: string
  services: EgressServiceOption[]
  /// 三个镜像地址的生效默认值（设置为空时的回落）
  mirror_defaults: Record<string, string>
  /// 环境变量中探测到的代理地址；env 模式下供用户确认
  env_proxy_detected: string
}

export interface NetworkTestPayload {
  /// 要测试连通性的服务 id：tmdb / image / douban / llm / telegram / discord / webhook / github / site:<站点id>
  service: string
}

export interface NetworkTestResult {
  ok: boolean
  latency_ms?: number | null
  message: string
}

/** 一条待处理事项（面板列表行）。 */
export interface NoticeView {
  id: number
  severity: string
  source: string
  title: string
  message: string
  payload: Record<string, JsonValue>
  created_at: string
  updated_at: string
}

/** 整理预览：完整的「将要发生什么」清单，用户确认后才执行。 */
export interface OrganizePreviewView {
  /// 台账在位文件总数（= 改名 + 已规范 + 跳过）
  total: number
  /// 已符合规范命名的文件数
  already_ok: number
  renames: OrganizeRenameView[]
  skips: OrganizeSkipView[]
  /// 条目目录改名时跟着搬的镜像资产（poster.jpg / fanart.jpg / clearlogo.png / seasonNN-poster.jpg / movie.nfo / tvshow.nfo）——不搬走旧目录就清不掉
  entry_assets: OrganizeSidecarView[]
}

/** 预览里的一条改名计划：旧路径 → 规范路径。 */
export interface OrganizeRenameView {
  file_id: number
  /// 所属条目——前端按条目分组展示
  media_item_id: number
  title: string
  year?: number | null
  source_path: string
  target_path: string
  /// 相对所在库根的旧路径（展示用）
  source_rel: string
  /// 相对所在库根的规范路径（展示用）
  target_rel: string
  size_bytes: number
  sidecars: OrganizeSidecarView[]
}

/** 跟随主文件改名的附属文件（字幕等）。 */
export interface OrganizeSidecarView {
  source_path: string
  target_path: string
}

/** 预览里的一条跳过说明：哪个文件、为什么不动它。 */
export interface OrganizeSkipView {
  file_path: string
  reason: string
}

/** 整理启动响应。 */
export interface OrganizeStartView {
  started: boolean
  message: string
  /// 持久化后台作业 ID，可在活动页继续观察
  job_id: string
  /// false 表示复用了仍在进行的同一作业
  created: boolean
}

/** 一条路径映射：movieclaw 视角的目录前缀 → 下载器视角的对应前缀。 */
/** 跨容器/跨主机部署时同一块盘两边挂载路径不同（movieclaw 看到 */
/** ``/data/downloads``，下载器容器里是 ``/downloads``），提交下载前 */
/** 按最长前缀把保存目录翻译成下载器视角。视角一致的部署无需配置。 */
export interface PathMapping {
  /// movieclaw 上的路径前缀
  local: string
  /// 下载器上的对应路径前缀
  remote: string
}

/** 一条路径映射的可达性体检结论（services.downloader_paths.PathProbe）。 */
export interface PathProbeView {
  /// movieclaw 视角路径
  local: string
  /// 下载器视角路径
  remote: string
  /// ok / empty / not_dir / missing / unmapped
  state: string
  /// 结论与该做什么（中文）
  detail: string
}

/** 历史根路径迁移修复的范围：旧前缀与当前配置中的目标前缀。 */
export interface PathReconcilePayload {
  /// 已移除、需要收口的旧根路径（绝对路径）
  old_root: string
  /// 当前媒体库配置中的目标根路径（绝对路径）
  new_root: string
}

/** 路径迁移修复预览：所有数字均只涉及数据库台账，磁盘文件永不删除。 */
export interface PathReconcilePreviewView {
  library_id: number
  old_root: string
  new_root: string
  same_path_candidates: number
  safe_merges: number
  marked_missing: number
  conflicts: string[]
  unconfirmed: string[]
  old_rows_to_delete_from_ledger: number
  disk_files_to_delete: number
}

/** 待更新快照：最近一次检查（定时或手动）留下的结论，读它不触网。 */
/** 前端的更新提醒完全建立在这个视图上——侧栏常驻徽标据此点亮，「设置 → */
/** 应用」进页即用它直接渲染出新版本卡片，用户不必再手点一次「检查更新」。 */
export interface PendingUpdateView {
  app_version?: string | null
  app_compatible: boolean
  app_changelog: string
  app_published_at: string
  model_tag?: string | null
  checked_at?: string | null
}

/** 人物页作品列表的一格：一部我库里的片 + 这个人在其中的身份。 */
export interface PersonCreditView {
  media_item_id: number
  kind: MediaKind
  tmdb_id: number
  title: string
  year?: number | null
  /// 海报（优先本地刮削资产，回落 TMDB 图床）；都没有为 NULL
  poster_url?: string | null
  /// 任一拥有该条目文件的库 id，供前端跳条目详情页；文件已全部删除、只剩档案时为 NULL，前端渲染为不可点
  library_id?: number | null
  /// 身份：cast=演员 / director=导演（剧集为主创）
  department: string
  /// 饰演角色（仅 cast）
  character?: string | null
}

/** 人物页的完整数据。 */
export interface PersonView {
  tmdb_person_id: number
  name: string
  original_name?: string | null
  /// 头像（TMDB 图床，经前端缓存代理）；TMDB 无照片为 NULL
  avatar_url?: string | null
  /// 库内作品，主演在前、同档按剧组主次顺序与年份倒序（见 PersonRepository）
  credits: PersonCreditView[]
}

/** PGS 自动转 SRT 的候选轨道与当前设备能力。 */
export interface PgsConversionView {
  candidate_key: string
  language?: string | null
  available: boolean
  engine?: string | null
  platform: string
  architecture: string
  cached: boolean
  message: string
  suggestions: string[]
  ocr_language?: string | null
  ocr_language_label?: string | null
  language_confirmation_required: boolean
  language_reason: string
  language_options: PgsOcrLanguageOptionView[]
}

/** 当前设备可用的一种 PGS 图片语言。 */
export interface PgsOcrLanguageOptionView {
  code: string
  label: string
}

/** 连接自检结果。 */
export interface PingResult {
  ok: boolean
  app_name: string
}

/** 订阅链路体检的整体结论（订阅设定页与订阅列表警示横幅共用）。 */
export interface PipelineHealthView {
  /// 整体状态：库链路 + 全局段（站点/下载器）的最坏值
  status: string
  /// 链路有 error 的库数
  error_count: number
  warn_count: number
  /// 资源搜索段（全局，链路第一环）
  site_check: HealthCheckView
  /// 是否有可用的默认下载器
  downloader_ok: boolean
  /// 是否配置过站点（无论当前可用与否）——开局清单只看它，配置过但失效的老用户看到的是体检红项而非新手清单
  sites_configured: boolean
  /// 是否配置过下载器（同上语义）
  downloaders_configured: boolean
  /// 按根因聚合的问题卡（error 在前）——前端置顶展示为「需要处理 N 件事」
  issues: HealthIssueView[]
  libraries: LibraryPipelineView[]
}

/** 远程 Worker 最近一次产物上传的脱敏记录。 */
export interface PlaybackArtifactUploadView {
  name: string
  status: number
  received_bytes: number
  content_length?: number | null
  transfer_encoding?: string | null
  occurred_at_ms: number
}

/** 一次播放的完整记录与时间线（docs/design/playback-qoe.md §5.5）。 */
export interface PlaybackAttemptView {
  attempt_id: string
  status: string
  outcome: string
  client: string
  origin: string
  lab_scenario: string
  member_id: number
  media_item_id?: number | null
  season_number?: number | null
  episode_number?: number | null
  library_file_id?: number | null
  tier: number
  degraded_from?: number | null
  engine: string
  route: string
  source_class: string
  network_class: string
  interface: string
  app_version: string
  first_frame_ms?: number | null
  playing_ms?: number | null
  user_wait_ms: number
  seek_in_count: number
  seek_in_p90_ms?: number | null
  seek_in_max_ms?: number | null
  seek_out_count: number
  seek_out_p90_ms?: number | null
  seek_out_max_ms?: number | null
  rebuffer_count: number
  rebuffer_ms: number
  freeze_count: number
  freeze_ms: number
  reconnect_count: number
  reconnect_ms: number
  interrupt_count: number
  error_kind: string
  error_category: string
  error_stage: string
  avoidable_loss?: boolean | null
  misguess_count: number
  undisturbed?: boolean | null
  watched_ms: number
  created_at: string
  ended_at?: string | null
  detail: Record<string, JsonValue>
  log_tail: string
}

/** 进度条上的章节刻度（docs/design/player-feel.md §2.C1）。 */
/** 只有起点与标题：预览图由 trickplay 雪碧图负责，章节图片再塞一份会把 */
/** 起播响应撑大好几倍，而进度条上根本画不下。 */
export interface PlaybackChapterMarkView {
  start_ms: number
  title?: string | null
}

/** 播放器客户端事件上报：把浏览器侧的现场（MediaError 详情、播放器状态） */
/** 落进服务端日志。iPhone 上的播放故障没有任何本地可看的控制台，服务端 */
/** 日志是唯一能拿到客户端真相的地方。 */
export interface PlaybackClientLogPayload {
  event: string
  detail?: Record<string, JsonValue> | null
}

/** 一次播放决策请求。``file_id`` 与播放单元二选一——给单元时服务端会在 */
/** 该单元的全部版本文件里择优（能直通的 1080p 胜过要转码的 2160p）。 */
export interface PlaybackDecideRequest {
  file_id?: number | null
  media_item_id?: number | null
  season_number?: number | null
  episode_number?: number | null
  capability: ClientCapabilityIn
  failed_tiers?: number[] | null
  audio_track?: string | null
  subtitle_track?: string | null
  max_height?: number | null
  device_id?: string | null
  downlink_bps?: number | null
}

/** 决策结果的三态并集。``outcome`` 决定其余字段哪些有值。 */
/** - ``plan``    —— 可以播，按 ``tier`` 走； */
/** - ``consent`` —— 需要用户同意开启软件转码（§3.6）； */
/** - ``rejected``—— 放不了，``reason`` / ``suggestion`` 面向用户。 */
export interface PlaybackDecisionView {
  outcome: string
  tier?: number | null
  file_id?: number | null
  container?: string | null
  video?: VideoPlanView | null
  audio?: AudioPlanView | null
  audio_tracks: AudioTrackView[]
  subtitles: SubtitlePlanView[]
  degraded_from?: number | null
  disc?: string | null
  disc_playlist?: string | null
  cost_hint?: string | null
  can_self_enable?: boolean | null
  setting_namespace?: string | null
  setting_key?: string | null
  reason: string
  suggestion?: string | null
}

/** 这台设备此刻是怎么在播的：直连原文件，还是经服务器重封装 / 转码（活动页的播放方式标识）。 */
export interface PlaybackDeliveryView {
  /// direct=直连原文件；remux=重封装（音视频都不重编码）；audio=只转音频（视频直通）；transcode=视频转码
  mode: string
  /// 简短中文标识：直连 / 重封装 / 音频转码 / 硬件转码 / 软件转码 / 远程转码
  label: string
  /// 转码输出规格，如「1080p · H.264 · 8 Mbps」；直连 / 重封装为 null
  target?: string | null
  /// 在哪转、用什么转，如「NAS · Intel 核显（QSV）」「远程 Worker「studio」· Apple 芯片（VideoToolbox）」
  executor?: string | null
  /// 服务端为什么选这个播放方式（中文）
  reason?: string | null
}

/** 播放器诊断面板使用的会话快照，不包含任何签名 URL 或令牌。 */
export interface PlaybackDiagnosticsView {
  session_state: string
  session_error?: string | null
  processing_mode: string
  execution_location: string
  backend?: string | null
  encoder?: string | null
  worker_id?: string | null
  worker_version?: string | null
  worker_platform?: string | null
  worker_arch?: string | null
  ffmpeg_version?: string | null
  worker_online?: boolean | null
  worker_last_seen_seconds?: number | null
  job_id?: string | null
  attempt_id?: string | null
  job_state?: string | null
  job_out_time_ms?: number | null
  job_speed?: string | null
  job_phase?: string | null
  job_exit_code?: number | null
  job_error?: string | null
  job_stderr_tail?: string | null
  head_segment?: number | null
  highest_produced_segment?: number | null
  requested_segment?: number | null
  served_segment?: number | null
  segment_wait_ms?: number | null
  segment_status?: number | null
  pending_segments: number[]
  failed_segments: number[]
  historical_failed_segments: number[]
  recent_uploads: PlaybackArtifactUploadView[]
  cache_bytes: number
  total_segments?: number | null
  lead_seconds?: number | null
  pause_reasons: string[]
  cache_hit: boolean
  cached_segments: number
  timeline: Record<string, JsonValue>[]
}

/** 原盘目录里可直推的一个文件（disc-direct-play.md §2.3）。 */
export interface PlaybackDiscFileView {
  path: string
  size: number
  url: string
}

/** 原盘目录清单：自研引擎据此在本机解析播放列表、拼接剪辑，服务端只按文件供字节。 */
export interface PlaybackDiscListingView {
  files: PlaybackDiscFileView[]
  playlist?: string | null
}

/** 正在播放文件的技术规格（来自 library_file 台账）。 */
export interface PlaybackFileSpec {
  resolution?: string | null
  video_codec?: string | null
  hdr?: string | null
  container?: string | null
  bit_rate?: number | null
  size_bytes?: number | null
}

/** ASS 字幕依赖的内嵌字体地址（已带签名 token）。 */
export interface PlaybackFontsView {
  fonts: string[]
}

/** 清除观看记录的结果：删掉了多少条状态与多少条播放质量指标。 */
export interface PlaybackHistoryClearView {
  /// 删除的观看状态行数（续播点/已看/播放次数）
  deleted_states: number
  /// 删除的播放质量指标行数
  deleted_metrics: number
}

export interface PlaybackHistoryView {
  entries: PlaybackLogEntryView[]
  /// 不在你可见范围内的记录数
  hidden_count: number
  has_more: boolean
  next_cursor?: number | null
}

/** 播放页要的条目信息，只有播放器用得上的那几样。 */
/** 播放路由只带 ``media_item_id``——它以 ``(kind, tmdb_id)`` 为锚、幂等复用， */
/** 比库自增 id 稳定得多，分享出去的地址不会因删库重建而失效（§6.10）。库归 */
/** 属由服务端按成员可见性解析，前端只在「退出播放跳回条目页」时用到它。 */
export interface PlaybackItemView {
  media_item_id: number
  library_id: number
  kind: string
  title: string
  year?: number | null
  poster_url?: string | null
}

/** 一场播放（playback_log 的一行）。 */
export interface PlaybackLogEntryView {
  id: number
  member_name: string
  media: MediaActivityTarget
  client: string
  device_name: string
  started_at: string
  ended_at?: string | null
  /// 实际观看时长（毫秒）
  watched_ms: number
  start_position_ms: number
  end_position_ms: number
  duration_ms?: number | null
  progress_percent?: number | null
  /// 本场是否看完
  completed: boolean
}

/** 一次标记：目标 + 要改成什么。 */
/** 目标的表达与 Jellyfin 的 Series / Season / Episode 三级一一对应：不带季集 */
/** = 整个条目（电影，或整剧级联到全部集）；只带季 = 整季；季集都带 = 单集。 */
/** 电影也可以像播放接口那样带哨兵 ``(0, 0)``，落到同一个单元。 */
/** ``played`` 与 ``favorite`` 至少给一个，没给的那个保持原值。 */
export interface PlaybackMarksRequest {
  media_item_id: number
  season_number?: number | null
  episode_number?: number | null
  played?: boolean | null
  favorite?: boolean | null
  device_id?: string | null
}

/** 目标在当前成员名下的已看 / 收藏状态。读接口与写接口同一形状， */
/** 写完直接拿它刷新按钮，不必再查一次。 */
export interface PlaybackMarksView {
  played: boolean
  is_favorite: boolean
  unplayed_count?: number | null
}

/** 一次播放结束时上报的记录。指标口径按 CTA-2066，不自创。 */
/** 带 ``attempt_id`` 的是 docs/design/playback-qoe.md 口径的收尾上报：按编号合并进服务端在 */
/** 会话接口建好的那一行，**所有结局都报**（看完、中途退出、出画前退出、失败、异常退出）。 */
/** 不带编号的是网页播放器的旧口径整行快照，原样落库。 */
/** 数值超出上下界会被夹住、列表与明细超限会被截断（记一行警告），不拒收。 */
export interface PlaybackMetricPayload {
  library_file_id?: number | null
  tier: number
  degraded_from?: number | null
  engine?: string | null
  hw_backend?: string | null
  ttff_ms?: number | null
  rebuffer_ms?: number | null
  rebuffer_count?: number | null
  seek_count?: number | null
  dropped_frames?: number | null
  total_frames?: number | null
  watched_ms?: number | null
  attempt_id?: string | null
  outcome?: string | null
  media_item_id?: number | null
  season_number?: number | null
  episode_number?: number | null
  origin?: string | null
  client?: string | null
  lab_scenario?: string | null
  route?: string | null
  network_class?: string | null
  interface?: string | null
  app_version?: string | null
  first_frame_ms?: number | null
  playing_ms?: number | null
  user_wait_ms?: number | null
  error_kind?: string | null
  error_category?: string | null
  error_stage?: string | null
  detail?: Record<string, JsonValue> | null
  log_tail?: string | null
}

/** 策略保存请求。**全字段可选，None = 不动这一项**——同意弹窗只翻 */
/** software_transcode_enabled 一个开关。 */
export interface PlaybackPolicyPayload {
  software_transcode_enabled?: boolean | null
  trickplay_enabled?: boolean | null
  transcode_cache_enabled?: boolean | null
}

/** 播放策略的当前取值。字段与 PlaybackPolicySetting 一一对应。 */
/** 数字上限（并发、输出高度、缓存配额）不在这里——它们已改为按机器规格 */
/** 自动推导（services/playback/limits.py），不再是配置项。 */
export interface PlaybackPolicyView {
  software_transcode_enabled: boolean
  trickplay_enabled: boolean
  transcode_cache_enabled: boolean
  hardware_available: boolean
  hw_backends: string[]
}

/** 一次观看状态上报。三种事件同一入口，与 Jellyfin 的 Playing / */
/** Playing/Progress / Playing/Stopped 一一对应。 */
export interface PlaybackProgressRequest {
  media_item_id: number
  season_number?: number | null
  episode_number?: number | null
  event?: string | null
  position_ms?: number | null
  audio_track?: string | null
  subtitle_track?: string | null
  file_id?: number | null
  device_id?: string | null
  paused?: boolean | null
}

/** 播放体验统计（docs/design/playback-qoe.md §5.5）：北极星、快 / 稳 / 对、打扰原因、 */
/** 最差的播放。 */
export interface PlaybackQoeStatsView {
  days: number
  since: string
  include_lab: boolean
  group_by?: string | null
  overall: QoeGroupStatsView
  groups: QoeGroupView[]
  reasons: QoeReasonView[]
  worst: QoeAttemptBriefView[]
}

/** 可跳过的一段（docs/design/skip-intro.md）：服务端整季比对认出来的，客户端只管用。 */
/** - ``intro`` 片头：在区间里显示「跳过片头」，点了跳到 ``end_ms``； */
/** - ``outro`` 片尾：到 ``start_ms`` 就提前显示「即将播放下一集」；``to_end`` 为假时 */
/** 片尾后面还有内容（下集预告、彩蛋），按钮是「跳过片尾」； */
/** - ``other`` 其他重复段（片头前的冠名广告、发行许可）：显示「跳过」。 */
export interface PlaybackSegmentView {
  type: string
  start_ms: number
  end_ms: number
  to_end: boolean
}

/** 开会话请求：在决策请求上多一个起播位置。 */
export interface PlaybackSessionRequest {
  file_id?: number | null
  media_item_id?: number | null
  season_number?: number | null
  episode_number?: number | null
  capability: ClientCapabilityIn
  failed_tiers?: number[] | null
  audio_track?: string | null
  subtitle_track?: string | null
  max_height?: number | null
  device_id?: string | null
  downlink_bps?: number | null
  start_ms?: number | null
  attempt_id?: string | null
  client?: string | null
}

/** 开会话的结果。 */
/** 三态里只有 ``plan`` 才会真的起会话；``consent`` / ``rejected`` 原样把 */
/** 决策带回前端，由它渲染弹窗或错误说明。 */
export interface PlaybackSessionView {
  decision: PlaybackDecisionView
  session_id?: string | null
  stream_url?: string | null
  start_ms: number
  timeline: string
  subtitle_urls: string[]
  master_url?: string | null
  hw_backend?: string | null
  watch?: PlaybackStateView | null
  source?: PlaybackSourceView | null
  chapters: PlaybackChapterMarkView[]
  segments?: PlaybackSegmentView[] | null
  matroska_cues?: MatroskaCuesView | null
}

/** 源文件的客观规格（台账真值），诊断面板「源 → 处理」层次的左半边。 */
/** Emby 式面板的关键是把「源是什么」与「我们对它做了什么」摆在一起—— */
/** 只报处理结果，用户看不出「1080p H264 明明能直通为什么在转码」这类问题。 */
export interface PlaybackSourceView {
  container?: string | null
  resolution?: string | null
  video_codec?: string | null
  hdr?: string | null
  bit_rate?: number | null
  frame_rate?: number | null
  size_bytes?: number | null
}

/** 一个播放单元在当前成员名下的观看状态。续播与上报共用同一形状。 */
export interface PlaybackStateView {
  position_ms: number
  played: boolean
  play_count: number
  duration_ms?: number | null
  audio_track?: string | null
  subtitle_track?: string | null
  ended_by_admin: boolean
}

export interface PlaybackStatsClientRow {
  client: string
  plays: number
  watched_ms: number
}

export interface PlaybackStatsDayRow {
  /// 按浏览器时区的日期 YYYY-MM-DD
  date: string
  plays: number
  watched_ms: number
  completed: number
  /// 当天有播放的成员数
  members: number
}

export interface PlaybackStatsMemberRow {
  member_id: number
  member_name: string
  plays: number
  watched_ms: number
  completed: number
}

/** 网页播放按档位的分解（直连 / 重封装 / 音频转码 / 硬件转码 / 软件转码）。 */
export interface PlaybackStatsTierRow {
  tier: number
  label: string
  plays: number
}

export interface PlaybackStatsTitleRow {
  media: MediaActivityTarget
  plays: number
  watched_ms: number
  /// 看过这部作品的成员数
  members: number
}

/** 一个周期的四个汇总数。 */
export interface PlaybackStatsTotals {
  /// 播放场次
  plays: number
  /// 观看总时长（毫秒）
  watched_ms: number
  /// 看完的场次
  completed: number
  /// 有播放的成员数
  active_members: number
}

/** 播放质量汇总。样本不足时各项为 null——不编数字。 */
/** `direct_ratio` 是**北极星指标**：档 0 + 档 1 占全部播放的比例。这一个数 */
/** 同时代表画质（没重编码）、速度（秒开）和服务器负担（不烧 GPU）。 */
export interface PlaybackStatsView {
  sessions: number
  direct_ratio?: number | null
  degraded_ratio?: number | null
  ttff_p50_ms?: number | null
  ttff_p95_ms?: number | null
  rebuffer_ratio?: number | null
  dropped_ratio?: number | null
  tier_counts: Record<string, number>
}

/** 一段时间内的观看统计（docs/design/activity.md「观看统计」）。 */
/** 当前周期与**上一周期**成对返回：没有参照系的数字只是数据，不是洞察。 */
/** ``by_day`` 与 ``previous_by_day`` 按天对齐（同为 days+1 行），主图把两条线画在 */
/** 同一坐标系里。``by_hour`` 是星期 × 小时的观看时长矩阵（周一为 0 行），按浏览器 */
/** 时区分桶，回答「家里什么时候有人在看」。 */
export interface PlaybackWatchStatsView {
  days: number
  current: PlaybackStatsTotals
  previous: PlaybackStatsTotals
  /// 上一周期有没有日志（日志刚开始记时没有）
  previous_available: boolean
  by_day: PlaybackStatsDayRow[]
  previous_by_day: PlaybackStatsDayRow[]
  /// 7×24 观看时长（毫秒），行=星期（0=周一），列=小时
  by_hour: number[][]
  by_member: PlaybackStatsMemberRow[]
  by_client: PlaybackStatsClientRow[]
  /// 网页播放按档位；Jellyfin 客户端恒为直连，不在内
  by_tier: PlaybackStatsTierRow[]
  top_titles: PlaybackStatsTitleRow[]
  /// 作品榜里不在你可见范围内的条数
  hidden_title_count: number
  /// 本期最受欢迎前三：看过的成员最多，并列取时长长的；与作品榜（按时长）口径不同
  favorites: PlaybackStatsTitleRow[]
  /// 上一周期的前三，用来标「蝉联 / 上期第 n / 新上榜」
  previous_favorites: PlaybackStatsTitleRow[]
}

/** 预检里的一个成员：它会落到哪、多大、是否冲突。 */
export interface PreflightMemberView {
  media_item_id: number
  title: string
  target_paths: string[]
  size_bytes: number
  /// true=需要完整复制（耗时且断开硬链接）
  cross_device: boolean
  /// same_anchor=目标已有这部作品的其他版本 / different_anchor=目录撞名但不是同一部片 / unknown=目标位置有内容但媒体库没有记录；null=不冲突
  conflict?: string | null
  conflict_path: string
  /// 跨盘后会断开硬链接、且源盘不会释放的字节数
  hardlinked_bytes: number
  /// 下载器里有同名落盘根——搬走可能让做种任务失效
  seeding_in_place: boolean
  /// 没有可搬内容时的中文说明
  reason: string
}

/** 预检结果三态：ready 可直接渲染弹层；ambiguous 先让用户选候选； */
/** not_found 提示该条目暂无法订阅。 */
export interface PrepareView {
  status: string
  media?: MediaBrief | null
  seasons: SeasonOverview[]
  /// 该条目已有订阅时给出，前端展示「已订阅」态
  existing_subscription_id?: number | null
  /// 电影：媒体库里已有本片（弹层提示，不拦订阅）
  movie_owned: boolean
  /// 建议预勾选的季号。豆瓣把剧集按季拆条目，用户点进「中餐厅 第十季」要订的就是那一季；这里给出收敛通路用首播日期定案的 TMDB 季号（与豆瓣季号未必相同）。为空表示无可信结论，前端按原默认规则勾选
  suggested_seasons: number[]
  candidates: ResolveCandidateView[]
}

/** 标签栏里的自定义分类标签：命名的「分类组合 × 站点组合」预设。 */
export interface PresetTabItem {
  type: string
  /// 预设标识（创建时生成）
  id: string
  /// 展示名称（1~16 字）
  name: string
  visible: boolean
  /// 勾选的一级分类；空 = 不限分类
  categories: TorrentCategory[]
  /// 勾选的站点；空 = 全部可用站点
  site_ids: string[]
  /// 图览模式：用该分类搜索时，结果页默认以图墙展示（结果页可临时切换）
  poster_mode: boolean
  /// 无痕搜索：用该分类搜索时不写入搜索历史（隐私敏感场景的开关）
  skip_history: boolean
}

/** 标签栏里的自定义分类标签：命名的「分类组合 × 站点组合」预设。 */
export interface PresetTabItemInput {
  type?: string | null
  /// 预设标识（创建时生成）
  id: string
  /// 展示名称（1~16 字）
  name: string
  visible: boolean
  /// 勾选的一级分类；空 = 不限分类
  categories?: TorrentCategory[] | null
  /// 勾选的站点；空 = 全部可用站点
  site_ids?: string[] | null
  /// 图览模式：用该分类搜索时，结果页默认以图墙展示（结果页可临时切换）
  poster_mode?: boolean | null
  /// 无痕搜索：用该分类搜索时不写入搜索历史（隐私敏感场景的开关）
  skip_history?: boolean | null
}

/** 试算：给定服务集合与模式，返回将暴露的工具清单。 */
export interface PreviewRequest {
  services?: string[] | null
  expand_tools?: boolean | null
}

export interface PreviewView {
  tool_count: number
  command_count: number
  approx_bytes: number
  tools: ToolPreview[]
}

/** 列表页进度：total = 工单总数，wanted 子集是缺口，imported 是已入库终态。 */
export interface ProgressView {
  total: number
  wanted: number
  grabbed: number
  downloaded: number
  imported: number
  upgrading: number
}

/** 测试推送文本(缺省用默认文案)。 */
export interface PushTestPayload {
  text?: string | null
}

/** 一次播放的摘要（统计里的「最差 N 条」与小样本明细）。 */
export interface QoeAttemptBriefView {
  attempt_id?: string | null
  created_at?: string | null
  status?: string | null
  outcome?: string | null
  client?: string | null
  media_item_id?: number | null
  season_number?: number | null
  episode_number?: number | null
  library_file_id?: number | null
  tier?: number | null
  source_class?: string | null
  route?: string | null
  network_class?: string | null
  first_frame_ms?: number | null
  seek_max_ms?: number | null
  interrupt_count?: number | null
  error_kind?: string | null
  avoidable_loss?: boolean | null
  misguess_count?: number | null
  undisturbed?: boolean | null
}

/** 一组播放的体验统计。样本少于 30 条时各项为 null，改列 ``samples`` 明细——不编数字。 */
export interface QoeGroupStatsView {
  attempts: number
  reported: number
  unreported: number
  in_progress: number
  small_sample: boolean
  undisturbed_rate?: number | null
  first_frame_ms?: QoePercentilesView | null
  seek_in_buffer_ms?: QoePercentilesView | null
  seek_out_buffer_ms?: QoePercentilesView | null
  interrupts_per_hour?: number | null
  failure_rate?: number | null
  exit_before_start_rate?: number | null
  abnormal_exit_rate?: number | null
  avoidable_loss_rate?: number | null
  misguess_rate?: number | null
  samples?: QoeAttemptBriefView[] | null
}

export interface QoeGroupView {
  attempts: number
  reported: number
  unreported: number
  in_progress: number
  small_sample: boolean
  undisturbed_rate?: number | null
  first_frame_ms?: QoePercentilesView | null
  seek_in_buffer_ms?: QoePercentilesView | null
  seek_out_buffer_ms?: QoePercentilesView | null
  interrupts_per_hour?: number | null
  failure_rate?: number | null
  exit_before_start_rate?: number | null
  abnormal_exit_rate?: number | null
  avoidable_loss_rate?: number | null
  misguess_rate?: number | null
  samples?: QoeAttemptBriefView[] | null
  key: string
  label: string
}

/** 一组毫秒数的分位（最近秩法）。 */
export interface QoePercentilesView {
  p50?: number | null
  p90?: number | null
  p99?: number | null
  count: number
}

/** 打扰原因的帕累托：一种原因打扰了多少次播放。 */
export interface QoeReasonView {
  reason: string
  label: string
  count: number
}

/** 「刚刚入库」一批里的一个季集单元（电影是哨兵 0/0）。 */
export interface RecentArrivalUnitView {
  season_number: number
  episode_number: number
}

/** 订阅首页「刚刚入库」的一张卡：一部作品最近入库、当前账号还没看完的那一批。 */
/** 同一部作品只出一张卡；整批看完即不再返回（规则见 */
/** ``services/subscription/recent_arrivals.py``）。播放入口是这一批里第一个 */
/** 没看完的单元，客户端直接按 ``media.media_item_id`` + 季集起播。 */
export interface RecentArrivalView {
  subscription_id: number
  media: MediaBrief
  /// 播放入口：这一批里第一个没看完的单元；电影=0
  season_number: number
  /// 播放入口的集号；电影=0
  episode_number: number
  /// 播放入口那一集的集名；电影或缺档案为空
  episode_name?: string | null
  /// 播放入口那一集的剧照；电影或缺剧照为空（客户端改用 media.backdrop_url）
  still_url?: string | null
  /// 这一批里还没看完、文件在位的全部单元（季集正序，第一个即播放入口）
  units: RecentArrivalUnitView[]
  /// 播放入口看了一半时的进度（1~99）；没看过为空
  progress_percent?: number | null
  /// 这一批最近一次整理入库的时间
  imported_at: string
}

/** 重新下载：把某条目的缺失单元交回订阅管线。 */
export interface RedownloadPayload {
  /// 所属媒体库 id
  library_id: number
  /// 要重新下载缺失内容的条目 id
  media_item_id: number
}

export interface ReelByteRangeView {
  /// 起始字节
  offset: number
  /// 长度
  length: number
  /// head 文件头 / index 索引 / start 起点后约 4 秒
  purpose: string
}

export interface ReelEpisodeView {
  /// 季号
  season: number
  /// 集号
  episode: number
  /// 集名
  name?: string | null
  /// 分集简介
  overview?: string | null
}

export interface ReelEventBatch {
  /// 一批事件
  events: ReelEventIn[]
}

export interface ReelEventIn {
  /// 片段标识
  reel_id: string
  /// impression 曝光 / first_frame 出画面 / leave 滑走 / complete 看完 / continue 接着看 / open 看正片 / fullscreen 全屏观看 / detail 看详情 / fail 放不出
  kind: string
  /// 当时的放法
  mode?: string | null
  media_item_id?: number | null
  file_id?: number | null
  /// 原片上的位置
  position_ms?: number | null
  /// 这一条累计看了多久
  watched_ms?: number | null
  /// 滑到这一条到出画面等了多久
  wait_ms?: number | null
  /// 补充信息
  detail?: Record<string, JsonValue> | null
}

export interface ReelEventResult {
  /// 落库条数
  accepted: number
}

/** 刷片筛选菜单的候选值与计数（与 ``GET /reels`` 同一组筛选参数）。 */
/** 维度与取值沿用媒体库筛选（docs/design/library-filtering.md）：类型是 TMDB genre id、 */
/** 地区是国家码、年代 / 片长是档名、评分是下限。每一维的计数都排除本维自身的条件 */
/** （否则勾了「动画」其他类型全变 0，多选就废了）；为 0 的照常返回，App 置灰不可点。 */
export interface ReelFacetsView {
  /// 当前条件下能刷到几部
  total: number
  /// 类型 / 地区 / 年代 / 评分 / 片长这几维筛选是否可用。False = 当前池子是「其他」（选了「其他」，或库里只有其他视频）：它没有 TMDB 档案，只剩观看状态可筛，App 收起那几个菜单
  filterable: boolean
  /// 电影 / 剧集 / 其他；空 = 没有可切换的类型（只有「其他」库），App 不显示这一行
  kinds: FacetValueView[]
  /// 类型，按数量倒序
  genres: FacetValueView[]
  /// 地区，按数量倒序
  countries: FacetValueView[]
  /// 年代，按时间倒序
  decades: FacetValueView[]
  /// 评分下限，高的在前
  ratings: FacetValueView[]
  /// 片长档，短的在前
  runtimes: FacetValueView[]
  /// 观看状态：只有「没看过」（unwatched）一项
  watch: FacetValueView[]
}

export interface ReelFeedView {
  /// 这次刷片的随机种子，翻页时原样带回
  seed: number
  /// 下一页的 offset
  next_offset: number
  /// 后面还有没有
  has_more: boolean
  items: ReelItemView[]
}

export interface ReelItemView {
  /// 片段标识（事件上报用）
  id: string
  title: ReelTitleView
  /// 封面：起点那一帧；没有时是剧照
  cover_url?: string | null
  segment: ReelSegmentView
  play: ReelPlayView
}

export interface ReelPersonView {
  /// 姓名
  name: string
  /// TMDB 影人 ID（打开人物页用）；只有姓名时为空
  tmdb_person_id?: number | null
  /// 头像（TMDB 图床地址）
  avatar_url?: string | null
}

/** 怎么放这一条。mode=seek：自研引擎打开原片、从 segment.start_ms 起播。 */
export interface ReelPlayView {
  /// 放法：seek=从原片中间起播（一期仅此一种）
  mode: string
  /// seek：原片取流地址（带 /api/v1 的相对路径，含令牌）
  stream_url?: string | null
  /// seek：原片大小（片源字节缓存的键要用）
  size_bytes?: number | null
  /// seek：起播音轨的同类型序号
  audio_ordinal?: number | null
  /// seek：要显示的中文字幕；None 不开
  subtitle?: ReelSubtitleView | null
  /// seek：上一条播放期间应预取的字节范围
  prefetch: ReelByteRangeView[]
}

/** 放原片的哪一段（原片时间轴，与怎么放无关）。 */
export interface ReelSegmentView {
  /// 原片文件（台账行 id）
  file_id: number
  /// 起点（落在关键帧上）
  start_ms: number
  /// 终点（落在两句对白之间）
  end_ms: number
  /// 原片总长（剧集是这一集）
  duration_ms?: number | null
  /// 挑法：bitrate 码率最高段 / chapter 章节起点 / position 固定位置
  method: string
}

export interface ReelSubtitleView {
  /// 内封字幕的同类型序号（embedded:<k> 的 k）
  ordinal: number
  language?: string | null
  title?: string | null
  codec?: string | null
  /// 只含这一段（前后各留几秒）的字幕文件地址（带 /api/v1 的相对路径，含令牌），时间戳是文件时间。放转码流、全屏片段模式用：读不到内封轨时靠它出字幕，不必等 NAS 通读整个文件抽整轨。只有能原样拷贝的文字轨才有（srt / ass），否则为 None
  url?: string | null
  /// url 那份字幕的格式：srt / ass
  format?: string | null
}

/** 这一条属于哪部片：展示用的信息。图片地址都是不带 /api/v1 的相对路径或完整外链。 */
export interface ReelTitleView {
  /// 条目 id
  media_item_id: number
  /// 这一条的文件所在的媒体库（分享要用）
  library_id: number
  /// 电影 / 剧集 / 其他
  kind: string
  /// 片名
  name: string
  /// 年份
  year?: number | null
  /// 评分（0～10）
  rating?: number | null
  /// 片长；剧集是这一集的时长
  runtime_minutes?: number | null
  /// 类型，最多 3 个
  genres: string[]
  /// 宣传语
  tagline?: string | null
  /// 简介（剧集是整剧的，分集简介在 episode 里）
  overview?: string | null
  /// 本人收藏了没有（电影 / 整剧）
  favorite: boolean
  /// 本人看过没有（电影看整部，剧集看这一集）
  played: boolean
  /// 看了一半时的进度（1～99，同「继续观看」口径）；没看过、已看完为空
  progress_percent?: number | null
  /// 电影是导演、剧集是主创，最多两位
  directors: ReelPersonView[]
  /// 海报
  poster_url?: string | null
  /// 横版剧照
  backdrop_url?: string | null
  /// 片名 Logo（本地资产）
  logo_url?: string | null
  /// 剧集：这一段出自哪一集
  episode?: ReelEpisodeView | null
}

/** 整库刷新中正在处理的一部片（并发若干路，故是列表）。 */
export interface RefreshActiveView {
  media_item_id: number
  title: string
  /// 当前阶段：拉取 TMDB 档案 / 写入元数据 / 下载图片 / …
  phase: string
}

/** 预览的一组：识别结论相同的文件聚成一条，用户按组拍板。 */
export interface ReidentifyGroupView {
  key: string
  outcome: ReidentifyOutcomeView
  file_ids: number[]
  file_count: number
  total_size_bytes: number
  /// 前几个文件名
  sample_names: string[]
}

/** 预览里一组文件的识别结论：命中某条目，或没命中（带原因与候选）。 */
export interface ReidentifyOutcomeView {
  media_item_id?: number | null
  tmdb_id?: number | null
  title?: string | null
  year?: number | null
  poster_url?: string | null
  /// 身份来源：path_tag=目录名标记 / nfo / resolved=名称收敛
  source?: string | null
  /// 结论与条目现有身份一致
  same_as_current: boolean
  /// 没命中时的中文原因
  reason?: string | null
  /// 没命中时的失败分类
  code?: string | null
  candidates: UnidentifiedCandidateView[]
}

/** 「修正识别结果」第一阶段：重跑识别链给出的结论，**尚未落库**。 */
/** 用户在此拍板：采纳某组结论 / 自己搜一个条目 / 把这些文件标为非独立 */
/** 作品；关掉面板则台账零改动。 */
export interface ReidentifyPreviewView {
  /// 条目当前挂着的身份
  current: ReviewItemView
  /// 本库是电影库（搜索与文案按类型走）
  movie: boolean
  groups: ReidentifyGroupView[]
  /// missing 文件数（无磁盘实体，不参与）
  skipped_missing: number
  /// 身份被目录名 tmdbid 标记或 NFO 钉死——改了还会被扫描改回去
  pinned_identity: boolean
  /// 有文件因 TMDB 不通而无结论，此刻不宜拍板
  unreachable: boolean
  /// 「自己搜」的预填词（解析出的片名）
  search_seed: string
}

/** 单条目重新识别的结论。 */
export interface ReidentifyResultView {
  /// 参与重识别的在位文件数
  total: number
  identified: number
  unidentified: number
  /// missing 文件数（无磁盘实体，保持原身份）
  skipped_missing: number
  /// TMDB 网络类失败、保留原身份的文件数（修复网络后可重试）
  kept_on_error: number
  /// 识别结果与原身份是否不同
  changed: boolean
  /// 全部文件收敛到的新条目；识别失败或分裂为多个条目时为 null
  new_media_item_id?: number | null
  new_title?: string | null
  /// 身份由目录名 tmdbid 标记或 NFO 钉死——结果不满意需先改标记/NFO 或人工认领
  pinned_identity: boolean
  /// 面向用户的结论文案
  message: string
}

/** 筛空时的一条放宽建议（docs/design/library-filtering.md 3.3）。 */
export interface RelaxSuggestionView {
  /// 维度：genres / countries / decades / watch
  dim: string
  /// 维度展示名：类型 / 地区 / 年代 / 观看
  dim_label: string
  /// 要去掉的那个取值
  value: string
  /// 该取值的展示名
  label: string
  /// 去掉它之后能找回多少部（恒 > 0）
  count: number
}

/** 网页保存的远程转码配置。 */
/** 没有令牌字段：Worker 的凭证在「设置 → 设备」里配对签发与吊销 */
/** （docs/design/device-auth.md §5.4）。 */
export interface RemoteTranscodeConfigPayload {
  /// 是否启用远程硬件转码
  enabled?: boolean | null
  /// 取源/回传根地址的覆盖项；null=保持，空字符串=清除并回到自动推断
  base_url?: string | null
  /// 单个 HLS 产物上传的最大字节数
  max_artifact_bytes?: number | null
}

/** 网页展示的远程转码配置。 */
export interface RemoteTranscodeConfigView {
  enabled: boolean
  /// 静态配置出的根地址；空表示自动使用 Worker 连上来的地址
  base_url: string
  /// 网页配置的覆盖地址；空表示不覆盖
  base_url_override: string
  base_url_source: string
  max_artifact_bytes: number
  /// 开关已开，且填过的覆盖地址（如果填了）合法
  ready: boolean
  /// 覆盖地址的格式问题；地址留空不算问题，不包含任何令牌内容
  issues: string[]
}

export interface RenameDeviceRequest {
  /// 新的设备名
  name: string
}

/** 豆瓣收敛歧义时的确认候选。 */
export interface ResolveCandidateView {
  tmdb_id: number
  /// 选定候选后用于订阅的稳定引用
  title_ref: string
  title: string
  original_title: string
  year?: number | null
  poster_url?: string | null
}

/** 一集最近一次成功投递所使用资源的发布→发现→提交时间链。 */
export interface ResourceTimingView {
  site_id: string
  torrent_id: string
  publish_time?: string | null
  first_seen_at?: string | null
  submitted_at: string
  publish_to_seen_seconds?: number | null
  seen_to_submit_seconds?: number | null
  publish_to_submit_seconds?: number | null
  dry_run: boolean
}

/** 恢复已忽略的文件：清掉忽略标记，重新参与识别。 */
export interface RestorePayload {
  /// 要恢复识别的已忽略文件 id 数组
  file_ids: number[]
}

/** 按季清理时被有意保留的跨季种子（整季包覆盖到仍在追的季）。 */
export interface RetainedTorrentView {
  /// 下载任务名
  title: string
  /// 该种子覆盖到的季号；空=无从按季定位的存量数据
  seasons: number[]
}

/** 身份复核清单的一组：同一条目目录下、现身份与建议都一致的文件聚成一条。 */
/** 识别器升级后扫描复核发现新旧结论不一致的行进入本清单——身份未被改动， */
/** 由用户拍板：采纳建议（改挂新条目）或维持现状。两种拍板都转为人工身份， */
/** 此后对账永不再打扰。 */
export interface ReviewGroupView {
  /// 分组键：条目目录路径 + 现身份 + 建议身份
  key: string
  /// 展示名：条目目录名（裸文件为文件名）
  label: string
  library_id: number
  library_name: string
  file_count: number
  total_size_bytes: number
  file_ids: number[]
  /// 现挂身份
  current: ReviewItemView
  /// 新识别器给出的建议身份
  suggestion: ReviewItemView
}

/** 身份复核里的一方（现身份 / 建议身份）的条目信息。 */
export interface ReviewItemView {
  media_item_id: number
  tmdb_id?: number | null
  title: string
  year?: number | null
  poster_url?: string | null
}

/** 复核拍板：采纳识别器建议，或明确维持当前身份。 */
/** 两种拍板都把这些文件的身份来源转为 manual——用户已经看过并做了决定， */
/** 后续识别器升级不再对它们提复核建议。 */
export interface ReviewResolvePayload {
  /// 同一复核组内的文件 id 数组
  file_ids: number[]
  /// accept_suggestion=采纳建议；keep_current=维持当前身份
  decision: IdentityReviewDecision
}

/** 回退选择器的数据：候选版本列表 + 保留策略现状。 */
export interface RollbackOptionsView {
  targets: RollbackTargetView[]
  versions_dir_bytes: number
  keep_versions: number
}

/** 执行回退的请求体。空 target 走旧语义（切回上一版本/基线）。 */
export interface RollbackPayload {
  target?: string | null
  restore_backup?: boolean | null
}

/** 一个可回退（或切换）的目标版本。 */
export interface RollbackTargetView {
  kind: string
  version?: string | null
  changelog?: string | null
  installed_at?: string | null
  size_bytes?: number | null
  schema_action: string
  backup_taken_at?: string | null
}

export interface RuleSetPayload {
  /// 规则组名称（订阅列表与选择器里的展示名）
  name: string
  /// 过滤规则 JSON（全部键可缺省=不限）：resolutions 分辨率偏好序（如 ["2160p","1080p"]，顺序即优先级）、media_sources 片源档白名单兼偏好序（值域 remux/blu-ray/web-dl/rip/tv，顺序即优先级；与 resolutions 一样参与候选选优，空=不限片源）、video_codecs 编码白名单（按编码族匹配：写 x265 即接受 H.265/HEVC）、platforms/platforms_block 流媒体平台白/黑名单（规范值如 netflix、disney_plus、iqiyi；词表外的值读取时丢弃不报错）、release_groups_allow/release_groups_block 制作组白/黑名单、hdr_levels/hdr_block HDR 白/黑名单（值域 DV/HDR10+/HDR10/HLG/SDR，SDR=资源未标注 HDR，资源只标注泛指 HDR 时按 HDR10 计；白名单任一命中即过、顺序即偏好，黑名单命中即排除；旧的 hdr/dv 三态字段仍可写入，读取时自动换算并反向回填）、free_only 只要免费种、min_seeders 做种数下限、size_min_mb/size_max_mb 体积区间（整季包按每集均摊）、exclude_hr 排除 H&R、hr_unknown_policy 决定 H&R 状态未知时宽松/严格处理、未填写的条件均不限制。
  /// subtitle_languages_require：要求的字幕语言（BCP 47，任一命中即通过）。
  /// audio_languages_require：要求的音轨语言（BCP 47，任一命中即通过）。
  /// upgrade_source 洗版目标片源档（web-dl/blu-ray/remux，缺省=不洗版）、cutoff_resolution 洗版目标分辨率（缺省=resolutions 首选，必须在 resolutions 允许范围内；同理 upgrade_source 必须在 media_sources 允许范围内）、upgrade_ladder 参与洗版比较的维度及优先级（顺序即位次，值域 resolution/source/video_codec/platform，缺省 [resolution, source] 即只比分辨率与片源；偏好列表为空的维度自动跳过）。
  /// 示例：{"resolutions":["2160p"],"free_only":true,"upgrade_source":"remux"}
  spec?: Record<string, JsonValue> | null
  /// 适用范围（新订阅未指定规则组时据此自动选组）：条件列表，条件间为「且」，每条形如 {"field": ..., "op": "any_of", "values": [...]}。field 取值：kind（movie/tv）、genres（TMDB 类型 ID）、origin_countries（国家码如 JP、KR）。多个规则组同时命中时条件多者优先，都不命中用默认规则组。创建时缺省=不声明；更新时缺省=不改，传 [] 清空。示例：[{"field":"kind","op":"any_of","values":["tv"]},{"field":"origin_countries","op":"any_of","values":["JP","KR"]}]
  match_rules?: Record<string, JsonValue>[] | null
}

export interface RuleSetView {
  id: number
  name: string
  is_default: boolean
  spec: Record<string, JsonValue>
  /// 适用范围条件；空=未声明（只能手选或作默认兜底）
  match_rules: Record<string, JsonValue>[]
  /// 正在引用本规则组的订阅数；>0 时不可删除
  reference_count: number
}

/** 进行中扫描/整理的实时进度（前端在库封面上画进度环，两种任务共用）。 */
/** ``phase`` 是必填的：一次"扫描"内部分好几段（盘点 → 逐文件入账 → */
/** 补齐图片资产），分子分母各段各算。前端**必须**按阶段选文案，否则 */
/** 进度走完文件数后还要跑几分钟资产，界面就会僵在"已处理 = 总数"上 */
/** 对用户撒谎（见 library_scan.ScanPhase）。 */
export interface ScanProgressView {
  /// 进行中的阶段，取值见 library_scan.ScanPhase / organizing
  phase: string
  processed: number
  /// 总数；0 表示分母未知，前端画不确定态转圈
  total: number
}

/** 扫描启动响应。 */
export interface ScanResultView {
  started: boolean
  message: string
  /// 持久化后台作业 id，可用于等待、取消和查看时间线
  job_id: string
  /// 本次是否新建作业；false 表示复用同库进行中的扫描
  created: boolean
}

export interface ScheduledTaskUpdate {
  enabled: boolean
  trigger_type: TriggerType
  interval_seconds?: number | null
  cron_expr?: string | null
}

export interface ScheduledTaskView {
  key: string
  title: string
  description: string
  enabled: boolean
  trigger_type: TriggerType
  interval_seconds?: number | null
  cron_expr?: string | null
  last_run_at?: string | null
  next_run_at?: string | null
}

export interface ScrapeConfigView {
  setting: MetadataScrapeSetting
  effective: ScrapeEffectiveView
}

/** "跟随环境变量"字段当前的生效值（前端展示"跟随中：xxx"用）。 */
export interface ScrapeEffectiveView {
  language_priority: string[]
  cert_country_priority: string[]
  poster_size: string
  backdrop_size: string
  still_size: string
}

/** 全站背景蒙版（.page-scrim）的样式偏好。 */
/** 蒙版是铺在背景大图之上、页面内容之下的一层深色模糊层，压住背景、 */
/** 突出内容（见 apps/web/app/globals.css 的 .page-scrim）。全站只有这 */
/** 一档蒙版（除「新任务」首页大图直出外，所有页面统一），两个可调项 */
/** 分别驱动前端 CSS 变量 ``--scrim-blur`` / ``--scrim-dark``： */
/** - ``blur``：高斯模糊半径（px）。0 = 不模糊、背景大图清晰透出；越大背景 */
/** 越朦胧。 */
/** - ``dark``：压暗程度（蒙版底色的不透明度）。0 = 完全不压暗，1 = 全黑。 */
/** 默认值是实际调校后确定的出厂观感：中等模糊 + 近七成压暗，背景大图化为 */
/** 朦胧色块托住内容、又不至于抢走注意力；必须与前端 DEFAULT_UI_PREFS */
/** 以及 globals.css 里 .page-scrim 的变量兜底值保持一致。 */
export interface ScrimUiPrefs {
  /// 蒙版高斯模糊半径（px）：0 不模糊，越大背景越朦胧
  blur: number
  /// 蒙版压暗程度：0 完全不压暗，1 全黑
  dark: number
}

/** 全站背景蒙版（.page-scrim）的样式偏好。 */
/** 蒙版是铺在背景大图之上、页面内容之下的一层深色模糊层，压住背景、 */
/** 突出内容（见 apps/web/app/globals.css 的 .page-scrim）。全站只有这 */
/** 一档蒙版（除「新任务」首页大图直出外，所有页面统一），两个可调项 */
/** 分别驱动前端 CSS 变量 ``--scrim-blur`` / ``--scrim-dark``： */
/** - ``blur``：高斯模糊半径（px）。0 = 不模糊、背景大图清晰透出；越大背景 */
/** 越朦胧。 */
/** - ``dark``：压暗程度（蒙版底色的不透明度）。0 = 完全不压暗，1 = 全黑。 */
/** 默认值是实际调校后确定的出厂观感：中等模糊 + 近七成压暗，背景大图化为 */
/** 朦胧色块托住内容、又不至于抢走注意力；必须与前端 DEFAULT_UI_PREFS */
/** 以及 globals.css 里 .page-scrim 的变量兜底值保持一致。 */
export interface ScrimUiPrefsInput {
  /// 蒙版高斯模糊半径（px）：0 不模糊，越大背景越朦胧
  blur?: number | null
  /// 蒙版压暗程度：0 完全不压暗，1 全黑
  dark?: number | null
}

/** 搜索历史的单条记录，供前端渲染「最近搜索」快捷入口。 */
/** ``label`` / ``categories`` / ``site_ids`` 是搜索发生时的快照：点历史重搜时 */
/** 按快照原样再搜，预设后来改名/删除都不影响。 */
export interface SearchHistoryItem {
  id: number
  keyword: string
  vertical: string
  label?: string | null
  categories: string[]
  site_ids: string[]
  poster_mode: boolean
  search_count: number
  last_searched_at: string
  has_snapshot: boolean
}

/** 立即搜索缺失资源的结果。 */
export interface SearchNowView {
  /// 跳过冷却、重新排队的缺口工单数
  reset_count: number
}

/** 资源搜索预设：全量内置分类（含隐藏项）+ 全部自定义组合。 */
export interface SearchPresetListView {
  presets: JsonValue[]
}

/** 整体保存资源搜索预设；缺失的内置分类由后端按默认补齐。 */
export interface SearchPresetUpdate {
  presets: JsonValue[]
}

/** 跨站点聚合搜索的返回结构。 */
/** ``items`` 是所有站点结果的合并列表（每条自带 ``site_id`` / ``site_name``）， */
/** ``sites`` 给出逐站执行状态。前端既能直接铺一个大列表，也能按站点分组、或单独 */
/** 提示失败站点。``label`` / ``categories`` 是请求参数的回显，供结果页直接标注 */
/** 本次搜索的范围。 */
export interface SearchResponse {
  keyword: string
  label?: string | null
  categories: string[]
  total: number
  items: TorrentHit[]
  sites: SiteSearchStatus[]
}

/** 清理已移出订阅范围的那几季的内容（减季后的可选收尾）。 */
export interface SeasonCleanupPayload {
  /// 要清理的季号；必须都已移出订阅范围
  seasons: number[]
  /// 从下载器删除这几季的种子任务及其数据文件（不可恢复）
  delete_torrents?: boolean | null
  /// 把这几季在媒体库里的文件移入回收站（保留期内可恢复）
  delete_library_files?: boolean | null
}

/** 一季的分集清单（分集横滚区数据源）。 */
export interface SeasonEpisodesView {
  season_number: number
  episodes: EpisodeView[]
}

/** 弹层季选择器的一行：季号 + 播出进度 + 库存进度。 */
export interface SeasonOverview {
  season_number: number
  name: string
  air_date?: string | null
  episode_count?: number | null
  /// 已播集数（air_date<=今天）
  aired_count: number
  /// 媒体库已有的集数（库存 H）
  owned_count: number
}

/** 自检结果：这个端点现在能不能用，断在哪一环。 */
export interface SelfCheckView {
  ok: boolean
  message: string
  protocol_version: string
  tool_count: number
  elapsed_ms: number
  /// 被试调的只读工具；空=没有可安全试调的工具
  probe_tool: string
  probe_ok: boolean
  probe_message: string
  warnings: string[]
}

/** 系列里的一部作品：库里有没有、在追没在追。 */
export interface SeriesPartView {
  tmdb_id: number
  title: string
  release_date?: string | null
  poster_url?: string | null
  /// 库里已有的那条；null=缺这一部
  media_item_id?: number | null
  /// 已经在追（有订阅工单）
  subscribed: boolean
}

/** 一个可勾选的服务：给管理页算「选了它会多几个工具」用。 */
export interface ServiceView {
  /// 服务域名，如 subscriptions
  domain: string
  /// 这个服务能做什么（一行）
  description: string
  /// 该服务的命令数 = 展开模式下的工具数
  command_count: number
  /// 展开模式下这些工具定义的大致体积（字节）
  expanded_bytes: number
  /// 折叠模式下这一个工具的描述体积（字节）
  collapsed_bytes: number
}

/** 当前主体的能力开关快照（前端据此裁剪入口；安全边界仍在后端 403）。 */
export interface SessionCapabilities {
  allow_subscribe: boolean
  allow_search: boolean
  allow_direct_download: boolean
}

/** 完整轨迹中的上下文压缩记录，不属于 message。 */
export interface SessionCompactionEntryView {
  /// 轨迹类型判别值
  type: string
  /// 这条上下文压缩记录的稳定编号
  compaction_id: string
  /// 上一条轨迹 entry 的编号
  parent_id?: string | null
  /// 压缩记录写入时间（ISO 8601 UTC）
  timestamp: string
  /// 模型生成的历史交接摘要
  summary: string
  /// 后续模型请求实际采用的压缩后历史，不包含 system 消息
  replacement_history: SessionMessageView[]
  /// 压缩前的估算 token 数
  tokens_before?: number | null
  /// 压缩后的估算 token 数
  tokens_after?: number | null
}

/** 手动压缩的回执：摘要与前后 token 估算（bytes/4 启发式，非精确值）。 */
export interface SessionContextCompactionView {
  /// 模型生成的历史交接摘要
  summary: string
  /// 压缩前的估算 token 数
  tokens_before: number
  /// 压缩后的估算 token 数
  tokens_after: number
  /// 写入完整轨迹的 compaction 记录编号
  compaction_id: string
}

/** 新会话的来源快照；replacement_history 是后续请求实际继承的上下文。 */
export interface SessionHandoffEntryView {
  /// 轨迹类型判别值
  type: string
  /// 交接记录的稳定编号
  handoff_id: string
  /// 上一条轨迹 entry 的编号
  parent_id?: string | null
  /// 创建快照的时间（ISO 8601 UTC）
  timestamp: string
  /// 源会话稳定编号
  source_session_id: string
  /// 源会话快照时的链尾编号
  source_leaf_id?: string | null
  /// 快照时的源会话标题
  source_title?: string | null
  /// 新会话后续模型请求继承的完整上下文（不含 system 消息）。仅在 session.fork 的创建响应中携带；session.get-transcript 固定返回空列表——快照已持久化在服务端，每次读取会话都重复下发整份历史太浪费
  replacement_history: SessionMessageView[]
}

/** 用户消息已持久化并开始处理的回执。 */
export interface SessionMessageAcceptedView {
  /// 会话稳定编号，后续 session 操作都使用它
  session_id: string
  /// 本次新建的 user message 稳定编号，可作为 retry 的定位锚点
  message_id: string
}

/** 完整轨迹中的一条消息记录；message_id 是可寻址的持久化身份。 */
export interface SessionMessageEntryView {
  /// 轨迹类型判别值
  type: string
  /// 这条持久化消息的稳定编号
  message_id: string
  /// 上一条轨迹 entry 的编号
  parent_id?: string | null
  /// 消息写入时间（ISO 8601 UTC）
  timestamp: string
  /// LLM 协议格式的完整消息
  message: SessionMessageView
  /// assistant 行：实际使用的模型 id；user 行：本轮请求的模型引用（null = 默认模型）
  model?: string | null
  /// assistant 消息的 token 用量
  usage?: TokenUsage | null
  /// assistant 消息的模型结束原因
  finish_reason?: string | null
  /// user 消息生效的思维链档位；null = 模型默认
  thinking_level?: string | null
}

/** 会话中的一条协议消息。 */
/** user 是用户输入；assistant 是模型输出；tool 是工具执行回执；system 通常 */
/** 只在运行时组装而不写入 transcript，但保留在完整消息定义中。 */
export interface SessionMessageView {
  /// 消息角色：用户输入、模型输出、工具回执或系统消息
  role: string
  /// 消息正文；可能是纯文本或 text/thinking/image 内容块
  content?: JsonValue | null
  /// assistant 发起的工具调用；其他角色通常为空
  tool_calls?: ToolCall[] | null
  /// tool 消息所回应的工具调用编号
  tool_call_id?: string | null
  /// tool 消息对应的工具名称
  name?: string | null
}

/** 重命名会话的请求体。 */
/** 标题只存索引表（元数据不入转录文件，见 agent_sessions 模块的 */
/** append-only 约定）；索引整体重建时非空标题会被保留。 */
export interface SessionRenamePayload {
  /// 新的会话标题
  title: string
}

/** 从指定用户消息处重试，可用新内容替换原问题。 */
export interface SessionRetryPayload {
  /// 要重新提问的 user message 编号
  message_id: string
  /// 替换后的用户消息正文；留空时原文重试
  content?: string | null
  /// 重试消息携带的图片附件编号：不传（null）沿用原消息的附件，空数组显式去掉图片，非空数组替换为新附件
  attachments?: string[] | null
  /// 模型引用（同 session.start）；传 default 清回默认模型，留空沿用原消息的模型
  model?: string | null
  /// 思维链强度档位；传 default 清回模型默认，不传沿用原消息的档位
  thinking_level?: string | null
}

/** 提交一条用户消息；有 session_id 时继续已有会话，否则开始新会话。 */
/** 图片以 attachment_id 引用（先经 ``session.attachments.upload`` 上传）； */
/** 协议永不接受调用方直接提交内容块——ContentPart 由服务端组装，杜绝注入 */
/** 任意 url 或内联 base64（docs/design/agent-image-input.md §8.1）。 */
export interface SessionStartPayload {
  /// 用户消息正文；带图片时允许为空
  content?: string | null
  /// 随消息发送的图片附件编号列表（上传接口返回的 attachment_id）
  attachments?: string[] | null
  /// 已有会话编号；留空时创建新会话
  session_id?: string | null
  /// 模型引用：裸模型 id，或同 id 在多个实例时的「实例名/模型id」（见 llm.models）；传 default 显式用默认实例的默认模型；留空时沿用会话最近一条消息的模型（新会话即默认）
  model?: string | null
  /// 思维链强度档位（off/minimal/low/medium/high/xhigh/max），传 default 显式清回模型默认；不传时沿用会话最近一条消息的档位
  thinking_level?: string | null
}

/** 会话列表项（索引表投影 + 派生的运行状态）。 */
export interface SessionSummary {
  /// 会话稳定编号（session_id）
  id: string
  /// 会话标题；未命名时为空
  title?: string | null
  /// 最近一条用户消息的短预览
  last_prompt?: string | null
  /// 完整轨迹的 entry 数量，包含 message 与 compaction
  entry_count: number
  /// 当前是否有仍在处理的用户消息
  running: boolean
  /// 会话创建时间（ISO 8601 UTC）
  created_at: string
  /// 会话最近活动时间（ISO 8601 UTC）
  updated_at: string
}

/** 会话详情：列表项字段 + 完整轨迹回放。 */
/** message / compaction / handoff 是三种明确的 entry；各自使用自己的稳定 */
/** 编号，parent_id 只描述同一会话内跨 entry 的线性轨迹链。 */
export interface SessionTranscriptView {
  /// 会话摘要与当前运行状态
  session: SessionSummary
  /// 按写入顺序排列的完整 message/compaction 轨迹
  entries: JsonValue[]
}

/** 当前登录状态（GET /auth/me 与登录成功后的返回体）。 */
export interface SessionView {
  username: string
  nickname: string
  /// 头像相对 URL（含版本号）；未上传过头像时为空
  avatar_url?: string | null
  /// admin=超级管理员；member=成员
  role: string
  /// 能力开关快照；管理员恒为全开
  capabilities: SessionCapabilities
  /// 本次请求所用的登录设备；升级前签发的旧网页会话为空
  device?: DeviceBrief | null
}

/** 创建分享。有效期只有四档，没有「永久」。 */
export interface ShareCreateRequest {
  /// 有效期（天）：1 / 3 / 7 / 30
  expires_in_days?: number | null
  /// 访问密码；空 = 不设密码
  password?: string | null
}

/** 访客打开链接时的探针：只说「要不要密码」，不露片名海报。 */
export interface SharePublicView {
  requires_password: boolean
  /// 无密码恒为 true；有密码时表示本浏览器已解锁
  unlocked: boolean
  expires_at: string
  /// 被分享的条目 id；解锁之前、或分享的是合集时为 null
  media_item_id?: number | null
  /// 被分享的合集 id；解锁之前、或分享的是条目时为 null
  collection_id?: number | null
}

export interface ShareUnlockRequest {
  password: string
}

/** 一条分享（创建者视角）。 */
export interface ShareView {
  id: number
  slug: string
  /// 分享链接；未配置外部访问地址时为相对路径 /s/{slug}
  url: string
  media_item_id?: number | null
  collection_id?: number | null
  library_id?: number | null
  title: string
  /// 被分享条目的形态；合集分享为 null
  kind?: MediaKind | null
  year?: number | null
  poster_url?: string | null
  /// 合集分享此刻有几部；条目分享为 null
  item_count?: number | null
  /// 访问密码原文；无密码为 null
  password?: string | null
  expires_at: string
  created_at: string
  view_count: number
  last_accessed_at?: string | null
}

/** 合集分享页上的一格：只有认得出这部片所需的最少信息。 */
export interface SharedCollectionItemView {
  media_item_id: number
  title: string
  year?: number | null
  kind: MediaKind
  poster_url?: string | null
}

/** 分享页的合集信息：名字 + 此刻的成员卡片。 */
/** 成员是**每次访问现算**的（走 resolve_members）：规则驱动的合集会自己长， */
/** 分享出去之后新入库的片也会出现在里面——这正是分享一个合集而不是一串 */
/** 条目的意义。反过来，被移出去的片立刻打不开，不需要任何撤销动作。 */
export interface SharedCollectionView {
  name: string
  item_count: number
  items: SharedCollectionItemView[]
}

/** 访客能看到的一个文件：只有规格与章节，没有路径、文件名、生命周期细节。 */
export interface SharedFileView {
  id: number
  size_bytes: number
  container?: string | null
  resolution?: string | null
  video_codec?: string | null
  hdr?: string | null
  bit_depth?: number | null
  duration_seconds?: number | null
  media_source?: string | null
  season_number: number
  episode_number: number
  missing: boolean
  state: string
  audio_streams?: AudioStreamView[] | null
  subtitle_streams: SubtitleStreamView[]
  chapters?: ChapterView[] | null
}

/** 分享页的影片信息：详情视图的浏览面投影。 */
export interface SharedItemView {
  media_item_id: number
  kind: MediaKind
  tmdb_id?: number | null
  imdb_id?: string | null
  douban_id?: string | null
  title: string
  original_title: string
  year?: number | null
  poster_url?: string | null
  backdrop_url?: string | null
  primary_aspect: number
  local_meta?: LocalMetaView | null
  files: SharedFileView[]
  seasons: number[]
  expires_at: string
}

/** 侧边栏（液态玻璃面板）的样式偏好。 */
/** 两个值直接对应前端 WebGL 着色器的参数（见 apps/web/lib/glass.ts）： */
/** 侧栏玻璃的基底是 LiquidGlassCard 同款材质（见 apps/web/lib/glass.ts）， */
/** 三个值是在其上微调的滑杆，默认值即 Card 出厂观感： */
/** - ``transparency``：玻璃透明程度。0 = Card 标准玻璃，1 = 玻璃完全 */
/** 隐去；对应 shader 的 u_opacity（材质整体淡出）。 */
/** - ``brightness``：玻璃明暗。-1 最暗 ~ 1 最亮，0 = 不加暗不提亮； */
/** 对应 shader 的 tint 参数。 */
/** - ``depth``：玻璃厚度（边缘曲率带宽度，px）。越大越像厚玻璃、边缘折射带 */
/** 越宽；对应 shader 的 u_zRadius，过小会使高度场退化，故下限取 10。 */
/** 默认值是实际调校后确定的出厂观感（半透 + 略压暗 + 偏薄的边缘折射带）， */
/** 而非 Card 材质的原始参数；必须与前端 DEFAULT_UI_PREFS 保持一致。 */
export interface SidebarUiPrefs {
  /// 玻璃透明程度：0 标准玻璃，1 完全隐去
  transparency: number
  /// 玻璃明暗：-1 最暗，1 最亮
  brightness: number
  /// 玻璃厚度（边缘曲率带宽度，px）
  depth: number
}

/** 侧边栏（液态玻璃面板）的样式偏好。 */
/** 两个值直接对应前端 WebGL 着色器的参数（见 apps/web/lib/glass.ts）： */
/** 侧栏玻璃的基底是 LiquidGlassCard 同款材质（见 apps/web/lib/glass.ts）， */
/** 三个值是在其上微调的滑杆，默认值即 Card 出厂观感： */
/** - ``transparency``：玻璃透明程度。0 = Card 标准玻璃，1 = 玻璃完全 */
/** 隐去；对应 shader 的 u_opacity（材质整体淡出）。 */
/** - ``brightness``：玻璃明暗。-1 最暗 ~ 1 最亮，0 = 不加暗不提亮； */
/** 对应 shader 的 tint 参数。 */
/** - ``depth``：玻璃厚度（边缘曲率带宽度，px）。越大越像厚玻璃、边缘折射带 */
/** 越宽；对应 shader 的 u_zRadius，过小会使高度场退化，故下限取 10。 */
/** 默认值是实际调校后确定的出厂观感（半透 + 略压暗 + 偏薄的边缘折射带）， */
/** 而非 Card 材质的原始参数；必须与前端 DEFAULT_UI_PREFS 保持一致。 */
export interface SidebarUiPrefsInput {
  /// 玻璃透明程度：0 标准玻璃，1 完全隐去
  transparency?: number | null
  /// 玻璃明暗：-1 最暗，1 最亮
  brightness?: number | null
  /// 玻璃厚度（边缘曲率带宽度，px）
  depth?: number | null
}

/** 刷流暂停/恢复请求体。 */
export interface SiteBoostPauseUpdate {
  /// true=暂停（做种压到极低上传限速、停止汰换与拉新种，任务与数据保留）/ false=恢复（解除限速，回到正常刷流节奏）
  paused: boolean
}

/** 单个站点的刷流运行统计（数据来源见 RatioBoostTask 台账）。 */
export interface SiteBoostStatsView {
  /// 在池刷流任务数
  active_count: number
  /// 在池任务占用的预算（字节）
  used_bytes: number
  /// 当前预算（字节）
  budget_bytes: number
  /// 刷流累计上传量（含已汰换任务的历史贡献，字节）
  uploaded_bytes_total: number
  /// 累计汰换任务数
  evicted_count: number
  /// 近 24 小时上传量（字节）
  uploaded_bytes_24h: number
  /// 近 24 小时平均在池体积（字节）
  avg_used_bytes_24h: number
  /// 近 7 天上传量（字节）
  uploaded_bytes_7d: number
  /// 近 7 天平均在池体积（字节）
  avg_used_bytes_7d: number
}

/** 配置/更新站点的请求体。 */
/** 按所选 auth_type 填写对应字段；未用到的字段留空即可（服务端会校验必填项）： */
/** - cookie      → cookie 字符串 */
/** - apikey      → api_key */
/** - credential  → username + password */
export interface SiteConfigCreate {
  /// 要配置的站点标识，须来自站点目录（CLI：mclaw site catalog）
  site_id: string
  /// 选用的授权类型，须在该站点 supported 列表内
  auth_type: AuthType
  /// COOKIE 模式：浏览器 cookie 字符串
  cookie?: string | null
  /// APIKEY 模式：API 密钥
  api_key?: string | null
  /// CREDENTIAL 模式：用户名
  username?: string | null
  /// CREDENTIAL 模式：密码
  password?: string | null
  /// 是否启用（默认启用）
  enabled?: boolean | null
}

/** 更新站点授权信息的请求体（site_id 走路径参数，故此处不含）。 */
export interface SiteConfigUpdate {
  /// 选用的授权类型，须在该站点 supported 列表内
  auth_type: AuthType
  /// COOKIE 模式：浏览器 cookie 字符串
  cookie?: string | null
  /// APIKEY 模式：API 密钥
  api_key?: string | null
  /// CREDENTIAL 模式：用户名
  username?: string | null
  /// CREDENTIAL 模式：密码
  password?: string | null
  /// true=启用 / false=停用
  enabled?: boolean | null
}

/** 站点保护开关请求体（语义见 docs/design/site-protection-ratio-boost.md）。 */
export interface SiteProtectionUpdate {
  /// true=保护（订阅链路绕开该站，手动搜索/下载不受影响）/ false=取消保护
  protected: boolean
}

/** 自动刷分享率设置请求体。 */
export interface SiteRatioBoostUpdate {
  /// true=开启自动刷分享率 / false=关闭
  enabled: boolean
  /// 刷流存储预算（字节，≥1 GiB）；None=不修改现有预算
  budget_bytes?: number | null
  /// 汰换最低保留天数（0～30；0=站点无 H&R、不设保护）；None=不修改
  hold_days?: number | null
}

/** 单个站点在本次搜索中的执行情况。 */
export interface SiteSearchStatus {
  site_id: string
  site_name: string
  count: number
  error?: string | null
  elapsed_ms?: number | null
}

/** 启用/停用请求体。 */
export interface SiteStatusUpdate {
  /// true=启用 / false=停用（停用后不再参与搜索与同步）
  enabled: boolean
}

/** 站点种子缓存与同步节奏的对外视图（数据来源见 SiteTorrent / SiteSyncCursor）。 */
/** 供站点配置页展示「本地缓存了多少、上次/下次什么时候同步」。可空语义： */
/** - ``last_sync_at`` 为 None = 从未同步过； */
/** - ``next_sync_at`` 为 None = 立即到期（新站等待首刷）； */
/** - ``last_error`` 为 None = 上次同步成功。 */
export interface SiteSyncStatsView {
  /// 该站点已缓存的种子数
  torrent_count: number
  /// 开始跟踪时间(t0)
  tracking_since?: string | null
  /// 上次同步完成时间
  last_sync_at?: string | null
  /// 上次同步成功时间；None=从未成功
  last_success_at?: string | null
  /// 下次同步到期时刻；None=立即到期
  next_sync_at?: string | null
  /// 当前自适应轮询间隔（秒）
  sync_interval_seconds?: number | null
  /// 上次同步新增种子数
  last_new_count?: number | null
  /// 上次同步失败原因；成功为 None
  last_error?: string | null
  /// 连续同步失败次数；成功清零
  consecutive_failures: number
}

/** 站点用户资料快照的对外视图（数据来源见 SiteUserProfile 模型）。 */
/** 上传/下载量只回传字节数，由前端统一格式化；``ratio`` 为 None 表示站点 */
/** 未提供（与 0.0 —— 真实无上传 —— 含义不同，前端应显示为"—"）。 */
export interface SiteUserProfileView {
  username: string
  user_class: string
  uploaded_bytes: number
  downloaded_bytes: number
  ratio?: number | null
  bonus?: number | null
  seeding_count: number
  leeching_count: number
  fetched_at: string
}

/** 一个可显式调用的 Agent 技能（composer 加号菜单的数据源）。 */
export interface SkillView {
  /// 技能名，也是 /skill:名字 占位符里的名字
  name: string
  /// 技能用途描述（菜单项的提示文案）
  description: string
  /// 来源层级：builtin=随产品内置，user=用户技能目录
  scope: string
}

export interface SourceCandidateView {
  kind: string
  key: string
  language?: string | null
  format?: string | null
  provenance: string
  excluded?: string | null
  reasons: string[]
  selectable: boolean
  requires_ocr: boolean
}

/** 分区首屏需要的一切：总开关、端点、可选服务目录。 */
export interface StatusView {
  /// MCP 总开关
  enabled: boolean
  /// 端点地址的公共前缀
  base_url: string
  /// 是否已配置外部访问地址；否则上面的地址只在局域网可用
  external_url_configured: boolean
  endpoints: EndpointView[]
  services: ServiceView[]
}

/** 面板读取占用时拿到的状态：统计很慢，所以接口给的是「上次结果 + 是否在算」。 */
export interface StorageStateView {
  /// 上一次统计的结果；进程内还没统计过时为空
  usage?: StorageUsageView | null
  /// 后台是否正在统计，前端据此显示进行中并轮询
  computing: boolean
  /// 上一次统计失败的原因，旧结果仍然可用
  error?: string | null
}

export interface StorageUsageView {
  data_root: string
  disk_total: number
  disk_used: number
  disk_free: number
  cache_bytes: number
  data_bytes: number
  dirs: DirUsageView[]
  unregistered: UnregisteredEntryView[]
  /// 统计时刻（Unix 秒）
  computed_at: number
}

/** 从 Discover 条目创建订阅的公开请求。 */
/** 调用方只传递上游返回的稳定引用；来源识别、豆瓣到 TMDB 的锚定、媒体 */
/** 建档和初始工单生成均由服务端完成。豆瓣发生歧义时，错误详情会返回可重试 */
/** 的 TMDB ``title_ref`` 候选。 */
export interface SubscriptionCreatePayload {
  /// Discover 搜索、片单或详情返回的影视条目稳定引用
  title_ref: string
  /// 可选的原始来源引用；从豆瓣歧义候选改选 TMDB 条目时原样回传，用于保留豆瓣身份
  source_title_ref?: string | null
  /// 剧集要订阅的季号数组，如 [1,2]；剧集至少要给一季，只想追以后播出的新集就留空并把 follow_future 设为 true；电影留空
  selected_seasons?: number[] | null
  /// 自动续订：未来新集与新季自动纳入订阅
  follow_future?: boolean | null
  /// 缺省按规则组适用范围自动选组，都不命中用默认规则组
  rule_set_id?: number | null
  /// 入库目标库；缺省用该类型默认库
  library_id?: number | null
}

/** 完整创建工作流结果：订阅本身以及管理员可见的下载路由预检。 */
export interface SubscriptionCreateView {
  subscription: SubscriptionDetailView
  /// 管理员可见的下载与入库路由预检；成员调用时为空
  download_routing?: DispatchPreviewView | null
}

/** 删除订阅的结果；勾了联动清理时带上后台任务 id 供任务中心跟进。 */
export interface SubscriptionDeleteView {
  /// 联动清理任务 id；没有可清理内容或未勾选时为空
  cleanup_job_id?: string | null
}

export interface SubscriptionDetailView {
  id: number
  media: MediaBrief
  status: string
  selected_seasons: number[]
  follow_future: boolean
  rule_set_id: number
  /// 入库目标库；null=该类型默认库
  library_id?: number | null
  progress: ProgressView
  /// 剧集按季收录统计；电影或无需展示时为空
  season_collection: SeasonOverview[]
  created_at: string
  updated_at: string
  wanted: WantedView[]
  /// 当前观看者能否调整这条订阅（改季、暂停、立即搜索、洗版、手动选种）：超管与发起人为 true；只关注不发起的成员为 false，只能取消关注
  can_manage: boolean
  /// 资源发布时间预测正在后台刷新（订阅创建/调整/恢复后的几秒内）；为 true 时 wanted[].release_forecast 可能还是旧值或空值，稍后重取即可
  forecast_pending: boolean
}

/** 订阅在途种子的实时下载快照（详情页轮询展示）。 */
/** state 词表与 TorrentStatus.state 一致，另加 missing——种子已不在任何 */
/** 可用下载器中（可能被手动删除，救援巡检稍后会退回工单重新找资源）。 */
export interface SubscriptionDownloadView {
  info_hash: string
  /// 下载器中的任务名；missing 时为空
  name?: string | null
  /// 0.0~1.0；missing 时为空
  progress?: number | null
  size_bytes?: number | null
  dlspeed_bytes?: number | null
  eta_seconds?: number | null
  /// downloading / stalled / paused / completed / error / missing / unknown
  state: string
  /// state 为 error 时下载器给出的可读原因；其余为空
  error_message?: string | null
  downloader_name?: string | null
  units: DownloadUnitView[]
}

/** 自动续订是详情页上的独立动作，不与选季等批量调整耦合。 */
export interface SubscriptionFollowFuturePayload {
  /// 是否持续追踪之后播出的新集与新一季
  enabled: boolean
}

/** 清理确认弹窗的预览：勾上开关会连带处理掉多少东西。 */
/** 体积只给媒体库那一侧——它来自台账、是准确值；种子体积要连下载器才知道， */
/** 不值得让一个确认弹窗等网络往返，也不该拿估算值吓唬用户。 */
export interface SubscriptionRemovalPreviewView {
  /// 范围内、仍可定位的下载任务数
  torrent_count: number
  /// 下载任务名（最多前 5 条，供弹窗举例）
  torrent_titles: string[]
  /// 其中处于 H&R 考核或考核状态未知的任务数；删除可能影响站点考核
  hit_and_run_count: number
  /// 范围内的媒体库文件数（含缺失记录）
  library_file_count: number
  /// 上述文件的台账体积合计（字节）
  library_bytes: number
  /// 媒体库文件删除后在回收站的保留天数，期间可恢复
  recycle_retention_days: number
  /// 按季清理时不会删除的跨季种子（仍被保留的季使用）；整条退订时为空
  retained_cross_season: RetainedTorrentView[]
}

/** 订阅表单打开前的内部预览请求。 */
/** ``title_ref`` 必须直接来自 Discover；服务端负责识别来源、解析豆瓣候选并 */
/** 建立 TMDB 锚点，Web 不再拼装 ``source/kind/external_id`` 组合。 */
export interface SubscriptionTargetPreviewPayload {
  /// Discover 返回的影视条目稳定引用
  title_ref: string
}

/** 用户可显式设置的追踪状态；完成态仍由工单自动派生。 */
export type SubscriptionTrackingState = string;

export interface SubscriptionTrackingStatePayload {
  /// 目标追踪状态：active 恢复追踪，paused 暂停搜索与投递
  state: SubscriptionTrackingState
}

/** 部分更新语义：不传的字段一律保持不变。 */
export interface SubscriptionUpdatePayload {
  /// 新的季选择，如 [1,2]；不传=不变
  selected_seasons?: number[] | null
  /// 是否自动续订（未来新集与新季自动纳入）；不传=不变
  follow_future?: boolean | null
  /// 换绑规则组 id；不传=不变
  rule_set_id?: number | null
  /// 换入库目标库；显式传 null=清除指定、改回按默认库路由；不传=不变
  library_id?: number | null
}

export interface SubscriptionView {
  id: number
  media: MediaBrief
  status: string
  selected_seasons: number[]
  follow_future: boolean
  rule_set_id: number
  /// 入库目标库；null=该类型默认库
  library_id?: number | null
  progress: ProgressView
  /// 剧集按季收录统计；电影或无需展示时为空
  season_collection: SeasonOverview[]
  created_at: string
  updated_at: string
}

/** 字幕预览中的一条对白；时间统一使用毫秒，前端只负责格式化。 */
export interface SubtitleCueView {
  start_ms: number
  end_ms: number
  text: string
}

/** 删除一个外挂字幕文件后的回执（路径回显，便于用户核对删的是哪一个）。 */
export interface SubtitleDeleteResultView {
  /// 已删除的字幕文件完整路径
  path: string
  /// 释放的磁盘空间
  freed_bytes: number
}

export interface SubtitlePlanView {
  track_ref: string
  kind: string
  language?: string | null
  is_default: boolean
  is_ai: boolean
}

/** 详情页字幕预览：格式元数据 + 已去样式的时间轴对白。 */
export interface SubtitlePreviewView {
  /// 本次预览的中性轨引用
  track: string
  format?: string | null
  event_count: number
  cues: SubtitleCueView[]
  /// 等待文案；为空表示已就绪
  pending?: string | null
  /// 建议的下次轮询间隔
  retry_after_ms: number
}

/** 一条字幕：内封轨（ffprobe）或外挂文件（目录发现）。 */
export interface SubtitleStreamView {
  /// 内封轨编码（subrip/ass/pgs…）；外挂为文件扩展名
  codec?: string | null
  language?: string | null
  title?: string | null
  forced: boolean
  /// 是否外挂字幕文件
  external: boolean
  /// 外挂字幕的文件名
  file_name?: string | null
}

/** 切换到浏览器已保存的某个账号（按用户名，用户名在超管与成员间全局唯一）。 */
export interface SwitchAccountRequest {
  username: string
}

/** 同步令牌的对外视图。 */
export interface SyncTokenView {
  /// 是否已启用同步（令牌是否存在）
  enabled: boolean
  /// 当前令牌明文，供复制进插件；未启用为 None
  token?: string | null
  /// 令牌生成时间
  created_at?: string | null
}

export interface TextPart {
  type: string
  text: string
}

/** 模型的思考控制方言声明（能力事实，不是功能承诺）。 */
/** 三种 kind 覆盖已知端点： */
/** - ``effort``：档位原词直传（请求体 reasoning_effort），levels 声明该模型 */
/** 的原生档位子集 = 用户菜单；off 编码为 reasoning_effort="none"； */
/** - ``budget``：enable_thinking + thinking_budget，档位按模型 */
/** max_thinking_tokens 比例分段（低 25% / 中 50% / 高 100%）；未声明 */
/** 预算上限的模型退化为仅开关； */
/** - ``toggle``：仅开/关（如 GLM 的 thinking.type），菜单只有「关」。 */
/** 未声明本字段的模型没有菜单、档位永不落请求（fail-closed）。 */
export interface ThinkingControl {
  kind: string
  levels: string[]
  supports_off: boolean
}

/** 模型的思考控制方言声明（能力事实，不是功能承诺）。 */
/** 三种 kind 覆盖已知端点： */
/** - ``effort``：档位原词直传（请求体 reasoning_effort），levels 声明该模型 */
/** 的原生档位子集 = 用户菜单；off 编码为 reasoning_effort="none"； */
/** - ``budget``：enable_thinking + thinking_budget，档位按模型 */
/** max_thinking_tokens 比例分段（低 25% / 中 50% / 高 100%）；未声明 */
/** 预算上限的模型退化为仅开关； */
/** - ``toggle``：仅开/关（如 GLM 的 thinking.type），菜单只有「关」。 */
/** 未声明本字段的模型没有菜单、档位永不落请求（fail-closed）。 */
export interface ThinkingControlInput {
  kind: string
  levels?: string[] | null
  supports_off?: boolean | null
}

/** 模型的思考过程（如 deepseek-r1 的 reasoning_content）。 */
/** 仅出现在响应侧的历史消息里；发回供应商时协议层会将其丢弃—— */
/** 各家 API 均不接受思考内容作为输入。 */
export interface ThinkingPart {
  type: string
  text: string
}

/** 一次历史影视条目搜索保存的完整结果（`GET /search/history/{id}/results`，`vertical=media`）。 */
export interface TitleSearchHistoryResultsView {
  history_id: number
  keyword: string
  snapshot_at: string
  total: number
  items: DiscoveredTitleView[]
}

/** 执行一次影视条目搜索。 */
export interface TitleSearchPayload {
  /// 要搜索的影视片名
  query: string
  /// 搜索来源：all 同时搜索 TMDB 和豆瓣，也可只指定 tmdb / douban
  provider?: DiscoveryProviderSelection | null
  /// 是否把本次搜索及结果快照写入当前账号的搜索历史
  save_history?: boolean | null
}

/** 多来源搜索中单个来源的执行状态。 */
export interface TitleSearchProviderStatus {
  provider: MediaSource
  success: boolean
  result_count: number
  message?: string | null
}

/** 一次统一影视搜索的结果；单个来源失败不会丢掉其他来源的结果。 */
export interface TitleSearchView {
  query: string
  titles: DiscoveredTitleView[]
  providers: TitleSearchProviderStatus[]
  /// 已记录历史时返回其 ID
  history_id?: number | null
}

/** 订阅首页的单集待入库摘要；不携带海报和下载进度等重复信息。 */
export interface TodayArrivalView {
  subscription_id: number
  wanted_id: number
  media_title: string
  media_kind: string
  season_number: number
  episode_number: number
  status: string
  air_date?: string | null
  /// 预计入库/播出的站点日历日，用于展示日期
  expected_day: string
  /// expected_day 距今天几天（0=今天）；站点日历口径，前端据此切换今日/预告文案
  days_ahead: number
  release_forecast?: Record<string, JsonValue> | null
  /// 按站点游标与礼貌间隔换算后的下一次有效预测探测时间
  next_probe_at?: string | null
  info_hash?: string | null
  grabbed_at?: string | null
  downloaded_at?: string | null
  /// 预计出种后到入库的分钟数；优先使用本订阅历史中位数
  estimated_release_to_import_minutes: number
  /// 下载完成后到入库的分钟数；优先使用本订阅历史中位数
  estimated_download_to_import_minutes: number
}

export interface ToggleRequest {
  enabled: boolean
}

export interface TokenUsage {
  prompt_tokens: number
  completion_tokens: number
  total_tokens: number
  cache_read_tokens: number
}

/** 模型发起的一次工具调用。 */
export interface ToolCall {
  id: string
  name: string
  arguments: Record<string, JsonValue>
  raw_arguments: string
  parse_error?: string | null
}

/** 折叠模式下一个服务工具覆盖的一条命令。 */
/** 折叠模式把整个服务压成一个工具，命令清单本来只以自然语言写在 description */
/** 里给模型看。管理页要是照搬那段文本，用户面对的就是一堵几百行的散文墙—— */
/** 所以这里把同一份元数据结构化再给一遍，页面按表格渲染。 */
export interface ToolCommand {
  /// 命令名，即 command 参数的取值
  name: string
  summary: string
  /// params 里可填的字段名，必填的带 * 后缀
  params: string[]
  /// confirm | destructive | 空
  dangerous: string
  /// 提交后台任务，返回 job_id
  is_job: boolean
}

/** 工具的一个参数。管理页要展示它，用户才能判断「这个工具好不好用」。 */
export interface ToolParameter {
  name: string
  /// JSON Schema 类型，如 integer / string[]
  type: string
  required: boolean
  description: string
  /// 落点：path / query / body
  location: string
  /// 枚举取值。折叠模式下 command 的取值就靠它列出该服务覆盖了哪些命令
  options: string[]
}

export interface ToolPreview {
  name: string
  summary: string
  description: string
  /// 所属服务域，详情页按它分组
  service: string
  read_only: boolean
  destructive: boolean
  parameters: ToolParameter[]
  /// 仅折叠模式：这个服务工具覆盖的命令清单
  commands: ToolCommand[]
}

/** 从种子标题/副标题推导出的结构化属性。 */
/** 空值语义： */
/** - 标量字段 ``None`` / 列表字段 ``[]`` = 未提取到； */
/** - ``remux`` 例外地用 ``False`` 当默认：种子名里不写 REMUX 基本就是非 Remux， */
/** 这是行业命名惯例里少数"缺席即否定"的标记； */
/** - ``complete`` 三态：True=明确标注全集/合集，None=没有标注（≠不是全集）。 */
export interface TorrentAttrs {
  media_type?: string | null
  content_type?: string | null
  titles_zh: string[]
  titles_en: string[]
  title_candidates: string[]
  year?: number | null
  seasons: number[]
  episodes: number[]
  episodes_total?: number | null
  complete?: boolean | null
  resolution?: string | null
  video_codec?: string | null
  hdr: string[]
  media_source?: string | null
  remux: boolean
  audio: string[]
  subtitle_languages: string[]
  subtitle_carriers: string[]
  audio_languages: string[]
  platforms: string[]
  release_group?: string | null
}

/** 应用级一级分类枚举。 */
export type TorrentCategory = string;

/** 搜索结果里的单条种子——在 ``TorrentListItem`` 基础上补上来源站点与扩充属性。 */
export interface TorrentHit {
  torrent_id: string
  title: string
  subtitle: string
  category?: TorrentCategory | null
  site_category_id?: string | null
  site_category_name?: string | null
  size?: string | null
  size_bytes: number
  seeders: number
  leechers: number
  snatched: number
  upload_time?: string | null
  uploader: string
  poster_url?: string | null
  image_urls: string[]
  free: boolean
  free_deadline?: string | null
  download_volume_factor: number
  upload_volume_factor: number
  hit_and_run?: boolean | null
  detail_url?: string | null
  download_url?: string | null
  site_id: string
  site_name: string
  attrs?: TorrentAttrs | null
}

/** 一次历史 PT 资源搜索保存的完整结果。 */
/** 结构与 ``SearchResponse`` 同构（items/sites/total 直接复用前端结果页的渲染 */
/** 管线），外加历史行的范围回显与快照时间——前端据 ``snapshot_at`` 渲染 */
/** 「这是 X 分钟前的快照」提示条。 */
export interface TorrentSearchHistoryResultsView {
  vertical: string
  history_id: number
  keyword: string
  label?: string | null
  categories: string[]
  site_ids: string[]
  snapshot_at: string
  total: number
  elapsed_ms?: number | null
  items: TorrentHit[]
  sites: SiteSearchStatus[]
}

/** 不经用户操作时会放的音轨 / 字幕（与起播同一口径：本集记着的 > 沿用同剧上一集 > */
/** 默认轨策略，见 services/playback/track_defaults）。详情页据此标「默认」并说明原因。 */
export interface TrackDefaultsView {
  /// 将要放的音轨（中性引用 embedded:<k>）；没有音轨为 null
  audio_track?: string | null
  /// remembered 上次换的 / series 沿用上一集 / original_language 影片原声 / default_flag 片源标注的默认 / first 第一条 / none 没有音轨
  audio_reason: string
  /// 音轨原因的一句中文，界面直接展示
  audio_note: string
  /// 将要开的字幕（embedded:<k> / external:<文件名>）；null = 不开字幕
  subtitle_track?: string | null
  /// remembered / series / library_language 媒体库语言 / forced 强制字幕 / same_language_off 原声就是库语言 / no_language_match 没有库语言字幕 / external / default_flag / forced_only / none（后四个是没有库语言可比时的旧规则）
  subtitle_reason: string
  /// 字幕原因的一句中文，界面直接展示
  subtitle_note: string
}

/** 转移预览里的一个搬运单元。 */
export interface TransferMoveView {
  source_path: string
  target_path: string
  /// true=整个条目目录搬走；false=只搬这一个文件
  is_dir: boolean
  size_bytes: number
  /// 本单元随迁的台账行数
  file_count: number
}

/** 条目转移的请求体：只需要目标库。 */
export interface TransferPayload {
  /// 转移目标库 id（必须与当前库同类型）
  target_library_id: number
}

/** 转移预览：完整的「将要发生什么」，用户确认后才执行。 */
export interface TransferPreviewView {
  target_library_id: number
  target_library_name: string
  /// 目标库主根——条目目录会搬到这里
  target_root: string
  moves: TransferMoveView[]
  /// 不参与转移的路径与中文原因
  skips: TransferSkipView[]
  total_bytes: number
  /// 缺失文件数（磁盘无实体，只随迁台账归属）
  missing_count: number
  /// 目标与源不在同一块盘——将退化为完整复制（耗时，且断开与做种目录的硬链接）
  cross_device: boolean
  /// 阻断性问题（如目标已有同名目录）；非空则不给执行
  blocked: string[]
}

/** 预览里的一条跳过说明：哪个路径、为什么不搬它。 */
export interface TransferSkipView {
  file_path: string
  reason: string
}

/** 转移启动响应。 */
export interface TransferStartView {
  started: boolean
  message: string
  /// 持久化后台作业 ID，可在活动页继续观察
  job_id: string
  /// false 表示复用了仍在进行的同一作业
  created: boolean
}

/** 转移进度 / 最近一次结论（前端弹窗轮询这一个接口收尾）。 */
export interface TransferStatusView {
  running: boolean
  media_item_id?: number | null
  title?: string | null
  target_library_id?: number | null
  processed: number
  total: number
  finished_at?: string | null
  target_library_name?: string | null
  moved_paths: string[]
  files_relocated: number
  bytes_moved: number
  removed_dirs: number
  /// 该片的订阅是否一并改挂到目标库（后续剧集直接投新库）
  subscription_moved: boolean
  /// 成功搬运的条目数（批量/归并）
  moved_items: number
  /// 按策略跳过的条目数（如同名冲突）
  skipped_items: number
  /// 执行时出错的条目数
  failed_items: number
  /// 逐条跳过的中文原因
  skips: string[]
  errors: string[]
}

export interface TrashedBatchFailureView {
  id: number
  file_name: string
  error: string
}

/** 批量结果：逐文件执行、单独提交，失败不回滚已成功的。 */
export interface TrashedBatchResultView {
  /// 成功处理的文件数
  done: number
  failed: TrashedBatchFailureView[]
  /// 按筛选清理时超出单次上限、尚未处理的文件数
  remaining: number
}

/** 回收站里的一个待回收文件（一集 / 一个旧版本）。 */
/** 品质字段来自台账行的 ffprobe 探测列；``audio_label`` 由服务端从首条音轨拼 */
/** 「编码 声道」（与条目详情页文件区同一读法），前端不再解析音轨数组。 */
export interface TrashedFileView {
  id: number
  file_name: string
  /// 当前物理位置（已移入回收站时是回收站内路径）
  file_path: string
  /// 移入回收站前的原路径；NULL=原地待回收（移动失败降级），file_path 即原位
  trash_original_path?: string | null
  /// 原地待回收形态（trash_original_path 为空）
  kept_in_place: boolean
  size_bytes: number
  resolution?: string | null
  media_source?: string | null
  hdr?: string | null
  video_codec?: string | null
  bit_depth?: number | null
  /// 首条音轨的「编码 声道」，如 DTS-HD MA 5.1；未探测为 null
  audio_label?: string | null
  release_group?: string | null
  /// 季号；电影=0
  season_number: number
  /// 集号；电影=0
  episode_number: number
  /// 集名（media_episode 表）；电影或未刮到为 null
  episode_title?: string | null
  trashed_at?: string | null
  /// 预计自动清理时间；null=不自动清理
  purge_after?: string | null
  /// 审计快照 reason：upgrade_replaced / upgrade_refuted / manual …
  reason?: string | null
  /// 审计快照 note（中文整句，如「洗版替换：1080p WEB-DL → 2160p Remux」）
  note?: string | null
  /// 上次批量清理失败的中文原因；成功或恢复后清掉
  last_error?: string | null
}

/** 回收站列表响应：聚合口径 + 本页条目。 */
/** ``total_*`` / ``due_within_24h`` / ``kept_in_place`` 按全部筛选（搜索 + 库 + */
/** 原因）计算，与摘要行、「立即清理全部」的作用域是同一份数字；``by_library`` */
/** 不受库筛选影响、``by_reason`` 不受原因筛选影响（分面计数，切换胶囊时其他 */
/** 胶囊的数字不归零）。 */
export interface TrashedFilesData {
  total_files: number
  total_items: number
  total_bytes: number
  /// 24 小时内将被自动清理的文件数
  due_within_24h: number
  /// 原地待回收（移入回收站失败）的文件数
  kept_in_place: number
  by_library: TrashedLibraryCountView[]
  by_reason: TrashedReasonCountView[]
  items: TrashedItemView[]
}

/** 「立即清理全部」的作用域：与列表接口同一组筛选参数，服务端重新查一遍 id。 */
export interface TrashedFilter {
  q?: string | null
  library_id?: number | null
  reason?: string | null
}

/** 分组所属的媒体条目（片名、年份、海报）。 */
export interface TrashedItemRefView {
  id: number
  title: string
  year?: number | null
  kind: MediaKind
  poster_url?: string | null
}

/** 回收站列表的一行：一个条目（电影 / 剧）及其全部待回收文件。 */
export interface TrashedItemView {
  /// 分组键：条目 id；未识别文件按行各自成组（前端 React key）
  key: string
  library: TrashedLibraryRefView
  /// 未识别的待回收文件为 null，前端以文件名代标题
  media_item?: TrashedItemRefView | null
  /// 涉及的季号（电影为空）
  seasons: number[]
  file_count: number
  total_bytes: number
  /// 组内最早到期；全组不自动清理时为 null
  earliest_purge_after?: string | null
  latest_purge_after?: string | null
  /// 组内按 reason 计数
  reasons: Record<string, number>
  /// 组内 note 一致时的整句；混合时为 null，前端按 reasons 拼计数
  note?: string | null
  /// 触发方快照文案，如「《九门》订阅洗版」
  trigger_label?: string | null
  latest_trashed_at?: string | null
  quality: TrashedQualityView
  files: TrashedFileView[]
}

export interface TrashedLibraryCountView {
  library_id: number
  name: string
  count: number
}

export interface TrashedLibraryRefView {
  id: number
  name: string
}

/** 批量清理：``ids``（所选 / 条目行 / 单个文件）与 ``filter``（全部）二选一。 */
export interface TrashedPurgePayload {
  /// 待清理的文件 id 列表
  ids?: number[] | null
  /// 按筛选清理全部（一次最多 500 个）
  filter?: TrashedFilter | null
}

/** 组内品质汇总：``tiers`` 按「分辨率 片源」计数，其余字段去重列表。 */
export interface TrashedQualityView {
  tiers: Record<string, number>
  hdr: string[]
  video_codecs: string[]
  audio_labels: string[]
  release_groups: string[]
}

export interface TrashedReasonCountView {
  reason: string
  count: number
}

export interface TrashedRestorePayload {
  /// 待恢复的文件 id 列表
  ids: number[]
}

/** 进度条缩略图索引。 */
/** `ready=false` 表示还在生成（或这部片生成不了）——前端表现为「暂无预览」， */
/** 不影响播放。前端据 `interval_ms` 与格子尺寸算「第 t 秒在哪张图的哪一格」。 */
export interface TrickplayView {
  ready: boolean
  interval_ms: number
  tile_width: number
  tile_height: number
  columns: number
  rows: number
  count: number
  sheets: string[]
}

/** 定时任务的触发方式。 */
/** - ``INTERVAL``：固定间隔重复（如每 300 秒一次），配 ``interval_seconds``。 */
/** - ``CRON``：按 cron 表达式在具体时刻触发（如每天 03:00），配 ``cron_expr``。 */
/** 两种方式覆盖了绝大多数周期性任务场景，且都能被 APScheduler 原生表达。 */
export type TriggerType = string;

/** 全站界面样式偏好，按页面分组。新页面的设定加嵌套模型字段即可。 */
export interface UiPreferencesSetting {
  /// 主题 id，取值见前端 lib/themes.ts 的注册表（silver / netflix）。存纯字符串并放宽校验：未知值由前端 normalizeThemeId 兜底为默认主题，老后端读到新主题 id 也不会整体拒绝（前向兼容）。
  theme: string
  /// 桌面端（≥768px 视口）的主题 id 覆盖；空 = 跟随 theme。校验口径与 theme 相同（纯字符串、前端兜底未知值），2026-09 起桌面 / 移动端可分别选主题，见前端 lib/ui-prefs.tsx 的 resolveThemeId。
  theme_desktop?: string | null
  /// 移动端（<768px 视口）的主题 id 覆盖；空 = 跟随 theme。
  theme_mobile?: string | null
  /// 侧边栏玻璃面板
  sidebar: SidebarUiPrefs
  /// 全站背景蒙版
  scrim: ScrimUiPrefs
  /// 侧边栏主导航排序
  nav: NavUiPrefs
  /// 媒体库首页的行清单
  home: HomeUiPrefs
}

/** 全站界面样式偏好，按页面分组。新页面的设定加嵌套模型字段即可。 */
export interface UiPreferencesSettingInput {
  /// 主题 id，取值见前端 lib/themes.ts 的注册表（silver / netflix）。存纯字符串并放宽校验：未知值由前端 normalizeThemeId 兜底为默认主题，老后端读到新主题 id 也不会整体拒绝（前向兼容）。
  theme?: string | null
  /// 桌面端（≥768px 视口）的主题 id 覆盖；空 = 跟随 theme。校验口径与 theme 相同（纯字符串、前端兜底未知值），2026-09 起桌面 / 移动端可分别选主题，见前端 lib/ui-prefs.tsx 的 resolveThemeId。
  theme_desktop?: string | null
  /// 移动端（<768px 视口）的主题 id 覆盖；空 = 跟随 theme。
  theme_mobile?: string | null
  /// 侧边栏玻璃面板
  sidebar?: SidebarUiPrefsInput | null
  /// 全站背景蒙版
  scrim?: ScrimUiPrefsInput | null
  /// 侧边栏主导航排序
  nav?: NavUiPrefsInput | null
  /// 媒体库首页的行清单
  home?: HomeUiPrefsInput | null
}

/** 收敛器判不了时留下的一个候选（用户点一下即可认领）。 */
export interface UnidentifiedCandidateView {
  tmdb_id: number
  title: string
  year?: number | null
  /// 该候选对应季的集数——同名双版本靠它一眼区分
  episode_count?: number | null
  /// 本地证据对它的佐证（年份相同/本地 N 集吻合…）
  reasons: string[]
}

/** 批量忽略整库的待识别文件（只打忽略标记，绝不动磁盘）。 */
export interface UnidentifiedClearPayload {
  /// 要批量忽略待识别文件的媒体库 id
  library_id: number
}

/** 待识别清单的一行。 */
export interface UnidentifiedFileView {
  id: number
  library_id: number
  library_name: string
  file_path: string
  size_bytes: number
  season_number: number
  episode_number: number
  /// 识别失败原因整句（展开/悬停查看；清单上只显示标签）
  reason?: string | null
  /// 失败分类：unparsable / tmdb_unreachable / ambiguous / no_match / kind_mismatch / unit_unresolved
  code?: string | null
  candidates: UnidentifiedCandidateView[]
}

/** 待识别清单的一组：同一条目目录下的文件聚成一条。 */
/** 一部剧几十集全认不出时，逐集列出来会把清单刷爆、也让人无从下手； */
/** 按条目目录聚合后一次认领整组（各文件沿用自己已解析的季集号）。 */
export interface UnidentifiedGroupView {
  /// 分组键：条目目录绝对路径；裸文件用文件自身路径
  key: string
  /// 展示名：条目目录名（裸文件为文件名）
  label: string
  library_id: number
  library_name: string
  file_count: number
  total_size_bytes: number
  /// 组内共同的识别失败原因整句
  reason?: string | null
  /// 组内共同的失败分类（决定标签与配色）
  code?: string | null
  /// 组内共同的候选：点一下整组认领
  candidates: UnidentifiedCandidateView[]
  files: UnidentifiedFileView[]
}

export interface UnregisteredEntryView {
  path: string
  bytes: number
}

/** 媒体库首页「接下来继续」的一张卡片。 */
/** 卡片指向的**永远是还没看完的那个单元**——电影是它自己，剧集是从最近播放 */
/** 那一集起往后第一个没看完的。看完的作品不出卡，所以这里没有"已看完"态。 */
export interface UpNextItemView {
  media_item_id: number
  library_id: number
  kind: MediaKind
  title: string
  year?: number | null
  poster_url?: string | null
  /// 海报宽高比（同海报墙 primary_aspect）
  poster_aspect: number
  backdrop_url?: string | null
  episode_still_url?: string | null
  season_number: number
  episode_number: number
  episode_title?: string | null
  unwatched_ahead_count: number
  position_ms: number
  duration_ms?: number | null
  progress_percent?: number | null
  /// 指向的是下一集，而不是上次那一个
  advanced: boolean
  last_played_at: string
}

/** 「接下来继续」横排的数据载荷。 */
export interface UpNextView {
  items: UpNextItemView[]
}

/** 「检查更新」的结果。 */
export interface UpdateCheckView {
  current_version: string
  latest_version: string
  update_available: boolean
  compatible: boolean
  requires_runtime: number
  changelog: string
  published_at: string
  latest_known_bad: boolean
}

/** 修改个人信息（当前只有昵称；登录用户名不可改）。 */
export interface UpdateProfileRequest {
  /// 展示昵称
  nickname: string
}

/** 更新执行进度（前端轮询）。 */
export interface UpdateProgressView {
  phase: string
  detail: string
  percent?: number | null
  error?: string | null
  target_version?: string | null
}

/** 保存本地版本保留数的请求体。 */
export interface UpdateRetentionPayload {
  /// 本地保留的版本目录数（含当前版本）
  keep_versions: number
}

/** 「设置 → 关于与更新」的状态区。 */
export interface UpdateStatusView {
  current_version: string
  code_source: string
  overlay_version?: string | null
  runtime_version?: number | null
  can_update: boolean
  has_previous: boolean
  previous_version?: string | null
  bad_versions: string[]
  model_tag?: string | null
  inactive_overlay_version?: string | null
  inactive_overlay_reason?: string | null
  last_abnormal_exit?: LastAbnormalExitView | null
}

/** 「一轮洗版」请求（docs/design/quality-upgrade.md §13.2）。 */
export interface UpgradeRunPayload {
  /// 可选：先换用该规则组再触发（组必须已配置洗版目标）；缺省用当前组
  rule_set_id?: number | null
}

/** 一轮洗版的逐集体检结果。 */
export interface UpgradeRunUnitView {
  season_number: number
  episode_number: number
  /// 可洗已排期 / 已达目标 / 洗版在途 / 无法识别当前版本 / 缺失走补缺
  state: string
  /// 当前版本档位标签；未入库/无法识别为 null
  current_label?: string | null
  /// 洗版目标档位标签
  target_label: string
}

/** 一轮洗版的体检报告（同步返回的一次性快照，不落库）。 */
export interface UpgradeRunView {
  target_label: string
  /// 本轮实际生效的规则组（换组后为新组）
  rule_set_id: number
  /// 中文摘要句，前端直接展示
  summary: string
  counts: Record<string, number>
  units: UpgradeRunUnitView[]
}

export interface VideoPlanView {
  action: string
  codec?: string | null
  height?: number | null
  tone_map: boolean
  bitrate_cap_bps?: number | null
  burn_subtitle?: string | null
}

/** 前端 ``MediaCapabilities.decodingInfo()`` 的一项视频探测结果。 */
export interface VideoSupportIn {
  codec: string
  max_height?: number | null
  smooth?: boolean | null
  power_efficient?: boolean | null
}

/** 单元的洗版派生状态（docs/design/quality-upgrade.md §8.3/§9）。 */
/** 只在"已入库且规则组配置了洗版目标"的单元上出现；标签由后端用统一的 */
/** 档位阶梯生成，前端零拼接直接展示。 */
export interface WantedUpgradeView {
  /// 是否洗版中（可证明低于目标且未熔断）
  active: boolean
  /// 当前版本档位标签（如「1080p WEB-DL」）
  current_label: string
  /// 洗版目标档位标签（如「1080p Remux」）
  target_label: string
  /// 已洗版搜索次数
  search_attempts: number
  /// 无法确认档位：证明不了低于目标也证明不了已达标——不参与自动洗版，可手动选种替换（§13.8）
  indeterminate: boolean
}

export interface WantedView {
  id: number
  season_number: number
  episode_number: number
  status: string
  air_date?: string | null
  priority: number
  info_hash?: string | null
  next_search_at?: string | null
  search_attempts: number
  last_search_at?: string | null
  release_forecast?: Record<string, JsonValue> | null
  resource_timing?: ResourceTimingView | null
  grabbed_at?: string | null
  downloaded_at?: string | null
  imported_at?: string | null
  last_reject_reason?: string | null
  grab_title?: string | null
  upgrade?: WantedUpgradeView | null
}

/** 对外端口的保存请求体（PUT /app/port）。 */
export interface WebPortPayload {
  /// 要监听的对外端口（1~65535）；null 或 0 = 清除设置、恢复默认
  port?: number | null
}

export interface WebhookConfigPayload {
  enabled?: boolean | null
  endpoints?: WebhookEndpointPayload[] | null
}

export interface WebhookConfigView {
  enabled: boolean
  endpoints: WebhookEndpointView[]
  catalog: EventCatalogEntry[]
}

/** 保存配置时的单个 endpoint。``id`` 为空 = 新建（服务端生成 id 与 secret）。 */
export interface WebhookEndpointPayload {
  id?: string | null
  name?: string | null
  url?: string | null
  format?: string | null
  enabled?: boolean | null
  events?: string[] | null
  template?: string | null
  headers?: Record<string, string> | null
  egress_scope?: string | null
}

export interface WebhookEndpointView {
  id: string
  name: string
  url: string
  format: string
  enabled: boolean
  events: string[]
  template: string
  headers: Record<string, string>
  egress_scope: string
  secret_masked: string
  /// secret 明文——仅在新建/轮换的响应里一次性返回，此后只给打码值
  secret?: string | null
  last_delivery?: DeliveryView | null
}

/** 已绑定账号(绑定页列表项)。 */
export interface WeixinAccountView {
  account_id: string
  bound_user_id?: string | null
  status: string
  running: boolean
  last_error?: string | null
  bound_at: string
}

/** 发起绑定的返回:前端渲染二维码并开始 poll。 */
export interface WeixinBindingStartView {
  challenge_id: string
  qrcode_url: string
  qrcode_image: string
  message: string
}

/** 绑定状态快照(前端每 1-2 秒 poll 一次,后端只读内存,毫秒级返回)。 */
/** status 取值: */
/** pending / scanned / need_verify_code / confirmed / already_bound / */
/** expired / failed。confirmed 时通道已启动,account 字段附带账号信息。 */
export interface WeixinBindingStatusView {
  challenge_id: string
  status: string
  message: string
  qrcode_url: string
  qrcode_image: string
  account?: WeixinAccountView | null
}

/** 提交手机微信上显示的配对数字。 */
export interface WeixinVerifyCodePayload {
  /// 配对码
  code: string
}

/** 人工认领请求：把条目钉到指定 TMDB 条目并恢复后台入库作业。 */
export interface MovieclawApiApiRoutesImportWatchClaimPayload {
  /// TMDB 条目 id（类型按规则先验：库类型或规则声明）
  tmdb_id: number
  /// 电影合集按文件认领：取 unresolved_files 里的一项；普通条目或只剩一个待认领文件时可省略
  entry_file?: string | null
}

/** 人工指定文件身份：把文件关联到 Discover 返回的影视条目。 */
export interface MovieclawApiSchemasLibraryClaimPayload {
  /// Discover 返回的 TMDB 影视条目稳定引用，如 tmdb:tv:1396
  title_ref: string
  /// 季号；电影固定 0
  season_number?: number | null
  /// 集号；电影固定 0
  episode_number?: number | null
}
