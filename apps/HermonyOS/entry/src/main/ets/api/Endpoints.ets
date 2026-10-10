// 由 tools/gen_api_arkts.py 从 MovieClaw iOS 端 Endpoints.swift 自动转译，勿手改。
// 源文件：MovieClaw/apps/apple/MovieClaw/Core/API/Generated/Endpoints.swift
// 方法名、路径、查询参数与 iOS 端逐字一致；路径相对 /api/v1。
import { ApiClient, ApiQuery, QueryPair } from './ApiClient';
import { JsonValue } from './JsonValue';
import {
  AccountView,
  ActiveBackdropUpdate,
  ActivityView,
  ApiTokenCreateRequest,
  ApiTokenCreatedView,
  AppConfigPayload,
  AppConfigView,
  AppearanceView,
  ArtworkCandidatesView,
  ArtworkSelectPayload,
  BatchTransferPayload,
  BatchTransferPreviewView,
  BoostCleanupRequest,
  BoostCleanupResult,
  BoostPoolView,
  BootstrapRequest,
  BootstrapStatus,
  CalibratePayload,
  CalibrateResultView,
  CatalogItem,
  ChangePasswordRequest,
  ChannelPushConfigView,
  ClaimBatchPayload,
  CleanPayload,
  CleanResultView,
  CollectionItemsPayload,
  CollectionPayload,
  CollectionSeriesView,
  CollectionView,
  ConfiguredSite,
  ConsolidateRootsPayload,
  ConsolidateRootsPreviewView,
  CookiePushRequest,
  CookieSyncResult,
  CountryOption,
  DeliveryView,
  DetachPayload,
  DeviceAuthorizeRequest,
  DeviceAuthorizeView,
  DeviceCleanupItem,
  DeviceCleanupRequest,
  DeviceCleanupView,
  DeviceLoginRequest,
  DeviceLoginView,
  DeviceRequestView,
  DeviceTokenRequest,
  DeviceTokenView,
  DiscoverRegionPayload,
  DiscoverRegionView,
  DiscoveredPersonDetailsView,
  DiscoveredTitleDetailsView,
  DiscoveryCollectionListView,
  DiscoveryCollectionTitlesView,
  DiscoveryFilterOptionsView,
  DiscoveryPageView,
  DiscoverySort,
  DiscoveryTitlePageView,
  DispatchPreviewView,
  DownloadSubmitPayload,
  DownloadSubmitView,
  DownloadTargetPrefView,
  DownloadTaskDeleteView,
  DownloadTaskListView,
  DownloadTaskReplaceView,
  DownloaderLimitsUpdate,
  DownloaderLimitsView,
  DownloaderPayload,
  DownloaderStatusUpdate,
  DownloaderView,
  DuplicateFilesData,
  DuplicateResolveAllPayload,
  DuplicateResolvePayload,
  EndpointCreateRequest,
  EndpointCreatedView,
  EndpointUpdateRequest,
  EndpointView,
  ExtensionSiteView,
  FavoritesView,
  FeishuBindPayload,
  FsBrowseView,
  GenPreviewView,
  GenStartPayload,
  GithubTokenPayload,
  GithubTokenView,
  GrabPayload,
  GrabResultView,
  HandoffPromptView,
  HandoffRequest,
  HealthResponse,
  HwProbeView,
  ImAccountView,
  ImBindTokenPayload,
  ImBindingView,
  ImportWatchPayload,
  ImportWatchView,
  IngestEntriesView,
  IngestEntryView,
  ItemDeleteResultView,
  JobCancelView,
  JobDismissAllRequest,
  JobDismissAllView,
  JobDismissRequest,
  JobDismissView,
  JobEventListView,
  JobListView,
  JobRetryView,
  JobView,
  JobWaitView,
  JobWorkerHealthView,
  LanguageOption,
  LibraryFacetsView,
  LibraryGalleryGroupView,
  LibraryIndexEntryView,
  LibraryItemDetailView,
  LibraryItemView,
  LibraryKindGenreView,
  LibraryPayload,
  LibraryRelaxView,
  LibraryReorderPayload,
  LibrarySearchView,
  LibraryView,
  LlmDefaultsPayload,
  LlmDefaultsView,
  LlmModelOptionView,
  LlmPresetView,
  LlmProviderPayload,
  LlmProviderView,
  LogContent,
  LogDayList,
  LoginDeviceView,
  LoginRequest,
  LogoutRequest,
  ManualDownloadTargetPayload,
  ManualDownloadTargetView,
  MediaActivityView,
  MediaKind,
  MediaSource,
  MediaSourceAnnotationCandidateView,
  MediaSourceAnnotationPayload,
  MemberCreateRequest,
  MemberPasswordResetView,
  MemberStatusRequest,
  MemberUpdateRequest,
  MemberView,
  MetadataRefreshView,
  MetadataScrapeSettingInput,
  MissingClearPayload,
  MissingItemView,
  ModelUpdateCheckView,
  MovieclawApiApiRoutesImportWatchClaimPayload,
  MovieclawApiSchemasLibraryClaimPayload,
  NetworkConfigPayload,
  NetworkConfigView,
  NetworkTestPayload,
  NetworkTestResult,
  NoticeView,
  OrganizePreviewView,
  OrganizeStartView,
  PathReconcilePayload,
  PathReconcilePreviewView,
  PendingUpdateView,
  PersonView,
  PingResult,
  PipelineHealthView,
  PlaybackAttemptView,
  PlaybackClientLogPayload,
  PlaybackDecideRequest,
  PlaybackDecisionView,
  PlaybackDiagnosticsView,
  PlaybackDiscListingView,
  PlaybackFontsView,
  PlaybackHistoryClearView,
  PlaybackHistoryView,
  PlaybackItemView,
  PlaybackMarksRequest,
  PlaybackMarksView,
  PlaybackMetricPayload,
  PlaybackPolicyPayload,
  PlaybackPolicyView,
  PlaybackProgressRequest,
  PlaybackQoeStatsView,
  PlaybackSessionRequest,
  PlaybackSessionView,
  PlaybackStateView,
  PlaybackStatsView,
  PlaybackWatchStatsView,
  PrepareView,
  PreviewRequest,
  PreviewView,
  PushTestPayload,
  RecentArrivalView,
  RedownloadPayload,
  ReelEventBatch,
  ReelEventResult,
  ReelFacetsView,
  ReelFeedView,
  ReidentifyPreviewView,
  ReidentifyResultView,
  RemoteTranscodeConfigPayload,
  RemoteTranscodeConfigView,
  RenameDeviceRequest,
  RestorePayload,
  ReviewGroupView,
  ReviewResolvePayload,
  RollbackOptionsView,
  RollbackPayload,
  RuleSetPayload,
  RuleSetView,
  ScanResultView,
  ScheduledTaskUpdate,
  ScheduledTaskView,
  ScrapeConfigView,
  SearchHistoryItem,
  SearchNowView,
  SearchPresetListView,
  SearchPresetUpdate,
  SearchResponse,
  SeasonCleanupPayload,
  SeasonEpisodesView,
  SelfCheckView,
  SessionContextCompactionView,
  SessionMessageAcceptedView,
  SessionRenamePayload,
  SessionRetryPayload,
  SessionStartPayload,
  SessionSummary,
  SessionTranscriptView,
  SessionView,
  ShareCreateRequest,
  SharePublicView,
  ShareUnlockRequest,
  ShareView,
  SharedCollectionView,
  SharedItemView,
  SiteBoostPauseUpdate,
  SiteBoostStatsView,
  SiteConfigCreate,
  SiteConfigUpdate,
  SiteProtectionUpdate,
  SiteRatioBoostUpdate,
  SiteStatusUpdate,
  SiteSyncStatsView,
  SkillView,
  StatusView,
  StorageStateView,
  SubscriptionCreatePayload,
  SubscriptionCreateView,
  SubscriptionDeleteView,
  SubscriptionDetailView,
  SubscriptionDownloadView,
  SubscriptionFollowFuturePayload,
  SubscriptionRemovalPreviewView,
  SubscriptionTargetPreviewPayload,
  SubscriptionTrackingStatePayload,
  SubscriptionUpdatePayload,
  SubscriptionView,
  SubtitleDeleteResultView,
  SubtitlePreviewView,
  SwitchAccountRequest,
  SyncTokenView,
  TitleSearchHistoryResultsView,
  TitleSearchPayload,
  TitleSearchView,
  TodayArrivalView,
  ToggleRequest,
  TorrentCategory,
  TransferPayload,
  TransferPreviewView,
  TransferStartView,
  TransferStatusView,
  TrashedBatchResultView,
  TrashedFilesData,
  TrashedPurgePayload,
  TrashedRestorePayload,
  TrickplayView,
  UiPreferencesSetting,
  UiPreferencesSettingInput,
  UnidentifiedClearPayload,
  UnidentifiedGroupView,
  UpNextView,
  UpdateCheckView,
  UpdateProfileRequest,
  UpdateProgressView,
  UpdateRetentionPayload,
  UpdateStatusView,
  UpgradeRunPayload,
  UpgradeRunView,
  WebPortPayload,
  WebhookConfigPayload,
  WebhookConfigView,
  WebhookEndpointView,
  WeixinAccountView,
  WeixinBindingStartView,
  WeixinBindingStatusView,
  WeixinVerifyCodePayload,
} from './Models';

/// MovieClaw 全量业务接口（对应 iOS 端 `extension APIClient` 的生成方法）。
export class MovieClawApi {
  private client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  /** 为一条待处理事项生成交给 Agent 的诊断工单 */
  /** `POST /agent-handoff` */
  sessionHandoffPrompt(body: HandoffRequest): Promise<HandoffPromptView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<HandoffPromptView>('/agent-handoff', bodyText);
  }

  /** 读取应用设置 */
  /** `GET /app/config` */
  appShow(): Promise<AppConfigView> {
    return this.client.get<AppConfigView>('/app/config');
  }

  /** 保存应用设置（即时生效） */
  /** `PUT /app/config` */
  appSet(body: AppConfigPayload): Promise<AppConfigView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<AppConfigView>('/app/config', bodyText);
  }

  /** 修改对外端口（保存后全量重启生效） */
  /** `PUT /app/port` */
  appPortSet(body: WebPortPayload): Promise<AppConfigView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<AppConfigView>('/app/port', bodyText);
  }

  /** 重启应用（优雅停机后由容器入口/进程守护拉起） */
  /** `POST /app/restart` */
  appRestart(): Promise<void> {
    return this.client.postVoid('/app/restart', null);
  }

  /** 运行期数据目录的占用统计 */
  /** `GET /app/storage` */
  appStorageUsage(refresh?: boolean): Promise<StorageStateView> {
    const pairs: QueryPair[] = [];
    if (refresh !== undefined && refresh !== null) { pairs.push({ key: 'refresh', value: refresh }); }
    return this.client.get<StorageStateView>('/app/storage' + ApiQuery.build(pairs));
  }

  /** 清理某个缓存目录 */
  /** `POST /app/storage/{key}/clean` */
  appStorageClean(key: string, body: CleanPayload): Promise<CleanResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<CleanResultView>(`/app/storage/${key}/clean`, bodyText);
  }

  /** 应用最新版本（下载校验后自动重启生效） */
  /** `POST /app/update/apply` */
  appUpdateApply(): Promise<UpdateProgressView> {
    return this.client.post<UpdateProgressView>('/app/update/apply', null);
  }

  /** 检查是否有新版本（比对 GitHub 最新 Release） */
  /** `POST /app/update/check` */
  appUpdateCheck(): Promise<UpdateCheckView> {
    return this.client.post<UpdateCheckView>('/app/update/check', null);
  }

  /** 读取 GitHub 访问令牌的配置状态（只返回打码尾号） */
  /** `GET /app/update/github-token` */
  appUpdateGithubTokenGet(): Promise<GithubTokenView> {
    return this.client.get<GithubTokenView>('/app/update/github-token');
  }

  /** 保存 GitHub 访问令牌（空串清除），检查更新时带上以避开匿名限流 */
  /** `PUT /app/update/github-token` */
  appUpdateGithubTokenPut(body: GithubTokenPayload): Promise<GithubTokenView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<GithubTokenView>('/app/update/github-token', bodyText);
  }

  /** 确认上一次异常退出告警（清除记录，不再展示） */
  /** `POST /app/update/last-exit/dismiss` */
  appUpdateLastExitDismiss(): Promise<void> {
    return this.client.postVoid('/app/update/last-exit/dismiss', null);
  }

  /** 更新 NER 模型（下载校验后重启后端生效） */
  /** `POST /app/update/model/apply` */
  appUpdateModelApply(): Promise<UpdateProgressView> {
    return this.client.post<UpdateProgressView>('/app/update/model/apply', null);
  }

  /** 检查 NER 模型是否有新版本 */
  /** `POST /app/update/model/check` */
  appUpdateModelCheck(): Promise<ModelUpdateCheckView> {
    return this.client.post<ModelUpdateCheckView>('/app/update/model/check', null);
  }

  /** 读取待更新快照（最近一次检查的结论，不触网） */
  /** `GET /app/update/pending` */
  appUpdatePending(): Promise<PendingUpdateView> {
    return this.client.get<PendingUpdateView>('/app/update/pending');
  }

  /** 读取更新执行进度 */
  /** `GET /app/update/progress` */
  appUpdateProgress(): Promise<UpdateProgressView> {
    return this.client.get<UpdateProgressView>('/app/update/progress');
  }

  /** 设置本地保留的版本目录数（立即按新策略清理） */
  /** `PUT /app/update/retention` */
  appUpdateRetention(body: UpdateRetentionPayload): Promise<void> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.putVoid('/app/update/retention', bodyText);
  }

  /** 回退到指定版本/镜像内置版本（不带 target 时回退上一版本） */
  /** `POST /app/update/rollback` */
  appUpdateRollback(body?: RollbackPayload): Promise<void> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.postVoid('/app/update/rollback', bodyText);
  }

  /** 回退选择器数据：本地保留的历史版本、数据兼容判定与保留策略 */
  /** `GET /app/update/rollback/options` */
  appUpdateRollbackOptions(): Promise<RollbackOptionsView> {
    return this.client.get<RollbackOptionsView>('/app/update/rollback/options');
  }

  /** 读取应用版本与更新能力状态 */
  /** `GET /app/update/status` */
  appUpdateStatus(): Promise<UpdateStatusView> {
    return this.client.get<UpdateStatusView>('/app/update/status');
  }

  /** 读取外观设置（背景图库与当前生效图） */
  /** `GET /appearance` */
  appearanceShow(): Promise<AppearanceView> {
    return this.client.get<AppearanceView>('/appearance');
  }

  /** 切换当前生效的背景图 */
  /** `PUT /appearance/active` */
  appearanceActiveSet(body: ActiveBackdropUpdate): Promise<AppearanceView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<AppearanceView>('/appearance/active', bodyText);
  }

  /** 从图库删除一张背景图 */
  /** `DELETE /appearance/backdrops/{backdrop_id}` */
  appearanceBackdropsDelete(backdropId: string): Promise<AppearanceView> {
    return this.client.del<AppearanceView>(`/appearance/backdrops/${backdropId}`, null);
  }

  /** 列出本浏览器已登录的全部账号（激活账号排第一） */
  /** `GET /auth/accounts` */
  authAccountsList(): Promise<AccountView[]> {
    return this.client.get<AccountView[]>('/auth/accounts');
  }

  /** 切换到本浏览器已登录的另一个账号（无需再输密码） */
  /** `POST /auth/accounts/switch` */
  authAccountsSwitch(body: SwitchAccountRequest): Promise<SessionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SessionView>('/auth/accounts/switch', bodyText);
  }

  /** 从本浏览器移除一个已登录账号（移除的是当前账号时自动切到下一个） */
  /** `DELETE /auth/accounts/{username}` */
  authAccountsRemove(username: string): Promise<SessionView | null> {
    return this.client.del<SessionView | null>(`/auth/accounts/${username}`, null);
  }

  /** 查询系统是否已完成首次初始化 */
  /** `GET /auth/bootstrap` */
  authBootstrapStatus(): Promise<BootstrapStatus> {
    return this.client.get<BootstrapStatus>('/auth/bootstrap');
  }

  /** 首次初始化：创建超级管理员（全生命周期仅一次） */
  /** `POST /auth/bootstrap` */
  authBootstrapCreate(body: BootstrapRequest): Promise<SessionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SessionView>('/auth/bootstrap', bodyText);
  }

  /** 设备发起接入请求，取得配对码（匿名） */
  /** `POST /auth/device/authorize` */
  authDeviceAuthorize(body: DeviceAuthorizeRequest): Promise<DeviceAuthorizeView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<DeviceAuthorizeView>('/auth/device/authorize', bodyText);
  }

  /** 原生 App 用账号密码登录，换取设备令牌（明文仅返回这一次） */
  /** `POST /auth/device/login` */
  authDeviceLogin(body: DeviceLoginRequest): Promise<DeviceLoginView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<DeviceLoginView>('/auth/device/login', bodyText);
  }

  /** 设备轮询兑换令牌（匿名） */
  /** `POST /auth/device/token` */
  authDeviceToken(body: DeviceTokenRequest): Promise<DeviceTokenView | null> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<DeviceTokenView | null>('/auth/device/token', bodyText);
  }

  /** 我的设备：登录着我的账号的浏览器、App、命令行、转码器与播放器 */
  /** `GET /auth/devices` */
  authDevicesList(all?: boolean): Promise<LoginDeviceView[]> {
    const pairs: QueryPair[] = [];
    if (all !== undefined && all !== null) { pairs.push({ key: 'all', value: all }); }
    return this.client.get<LoginDeviceView[]>('/auth/devices' + ApiQuery.build(pairs));
  }

  /** 注销当前这台设备（退出登录 / 断开配对） */
  /** `DELETE /auth/devices/current` */
  authDevicesRevokeCurrent(): Promise<void> {
    return this.client.delVoid('/auth/devices/current', null);
  }

  /** 当前这台设备（命令行 mclaw status 用） */
  /** `GET /auth/devices/current` */
  authDevicesCurrent(): Promise<LoginDeviceView> {
    return this.client.get<LoginDeviceView>('/auth/devices/current');
  }

  /** 按配对码查看一条待批准的接入请求 */
  /** `GET /auth/devices/requests/{user_code}` */
  authDevicesRequest(userCode: string): Promise<DeviceRequestView> {
    return this.client.get<DeviceRequestView>(`/auth/devices/requests/${userCode}`);
  }

  /** 批准一台设备接入（此刻才签发令牌，令牌归属批准者） */
  /** `POST /auth/devices/requests/{user_code}/approve` */
  authDevicesApprove(userCode: string): Promise<void> {
    return this.client.postVoid(`/auth/devices/requests/${userCode}/approve`, null);
  }

  /** 拒绝一台设备接入 */
  /** `POST /auth/devices/requests/{user_code}/deny` */
  authDevicesDeny(userCode: string): Promise<void> {
    return this.client.postVoid(`/auth/devices/requests/${userCode}/deny`, null);
  }

  /** 注销一台设备（凭证立即失效，正在播放与转码的一并停止） */
  /** `DELETE /auth/devices/{device_id}` */
  /** `POST /auth/devices/cleanup`：清理长期没用过的设备（dry_run=true 先列清单） */
  authDevicesCleanup(body: DeviceCleanupRequest): Promise<DeviceCleanupView> {
    const bodyText: string = JSON.stringify(body);
    return this.client.post<DeviceCleanupView>('/auth/devices/cleanup', bodyText);
  }

  authDevicesRevoke(deviceId: string): Promise<void> {
    return this.client.delVoid(`/auth/devices/${deviceId}`, null);
  }

  /** 给设备改名 */
  /** `PATCH /auth/devices/{device_id}` */
  authDevicesRename(deviceId: string, body: RenameDeviceRequest): Promise<LoginDeviceView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<LoginDeviceView>(`/auth/devices/${deviceId}`, bodyText);
  }

  /** 管理员登录 */
  /** `POST /auth/login` */
  authLogin(body: LoginRequest): Promise<SessionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SessionView>('/auth/login', bodyText);
  }

  /** 退出当前账号（自动切到浏览器里的下一个账号）；all=true 退出全部 */
  /** `POST /auth/logout` */
  authLogout(body?: LogoutRequest): Promise<SessionView | null> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SessionView | null>('/auth/logout', bodyText);
  }

  /** 查询当前登录状态 */
  /** `GET /auth/me` */
  authMe(): Promise<SessionView> {
    return this.client.get<SessionView>('/auth/me');
  }

  /** 修改密码（本人其余会话强制下线） */
  /** `PUT /auth/password` */
  authPasswordUpdate(body: ChangePasswordRequest): Promise<SessionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<SessionView>('/auth/password', bodyText);
  }

  /** 修改个人信息（昵称） */
  /** `PUT /auth/profile` */
  authProfileUpdate(body: UpdateProfileRequest): Promise<SessionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<SessionView>('/auth/profile', bodyText);
  }

  /** 手工创建一枚令牌（明文仅返回这一次，请立即保存） */
  /** `POST /auth/tokens` */
  authTokensCreate(body: ApiTokenCreateRequest): Promise<ApiTokenCreatedView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ApiTokenCreatedView>('/auth/tokens', bodyText);
  }

  /** 接入飞书群机器人(粘贴 Webhook 地址,即绑即用) */
  /** `POST /channels/im/feishu/bindings` */
  channelsImFeishuBind(body: FeishuBindPayload): Promise<ImAccountView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ImAccountView>('/channels/im/feishu/bindings', bodyText);
  }

  /** 读取推送内容开关 */
  /** `GET /channels/im/push-config` */
  channelsImPushConfigGet(): Promise<ChannelPushConfigView> {
    return this.client.get<ChannelPushConfigView>('/channels/im/push-config');
  }

  /** 保存推送内容开关 */
  /** `PUT /channels/im/push-config` */
  channelsImPushConfigUpdate(body: ChannelPushConfigView): Promise<ChannelPushConfigView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<ChannelPushConfigView>('/channels/im/push-config', bodyText);
  }

  /** 向所有已绑定通道发送测试推送 */
  /** `POST /channels/im/push-test` */
  channelsImPushTest(body: PushTestPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/channels/im/push-test', bodyText);
  }

  /** 已绑定的 TG/Discord 账号列表 */
  /** `GET /channels/im/{channel}/accounts` */
  channelsImAccountsList(channel: string): Promise<ImAccountView[]> {
    return this.client.get<ImAccountView[]>(`/channels/im/${channel}/accounts`);
  }

  /** 解绑 TG/Discord 账号 */
  /** `DELETE /channels/im/{channel}/accounts/{account_id}` */
  channelsImAccountsUnbind(channel: string, accountId: string): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/channels/im/${channel}/accounts/${accountId}`, null);
  }

  /** 发起配对绑定(提交 bot token,返回配对码) */
  /** `POST /channels/im/{channel}/bindings` */
  channelsImBindingsStart(channel: string, body: ImBindTokenPayload): Promise<ImBindingView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ImBindingView>(`/channels/im/${channel}/bindings`, bodyText);
  }

  /** 查询配对状态(前端轮询) */
  /** `GET /channels/im/{channel}/bindings/{challenge_id}` */
  channelsImBindingsStatus(channel: string, challengeId: string): Promise<ImBindingView> {
    return this.client.get<ImBindingView>(`/channels/im/${channel}/bindings/${challengeId}`);
  }

  /** 已绑定的微信账号列表 */
  /** `GET /channels/weixin/accounts` */
  channelsWeixinAccountsList(): Promise<WeixinAccountView[]> {
    return this.client.get<WeixinAccountView[]>('/channels/weixin/accounts');
  }

  /** 解绑微信账号 */
  /** `DELETE /channels/weixin/accounts/{account_id}` */
  channelsWeixinAccountsUnbind(accountId: string): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/channels/weixin/accounts/${accountId}`, null);
  }

  /** 发起微信扫码绑定 */
  /** `POST /channels/weixin/bindings` */
  channelsWeixinBindingsStart(): Promise<WeixinBindingStartView> {
    return this.client.post<WeixinBindingStartView>('/channels/weixin/bindings', null);
  }

  /** 查询绑定状态(前端轮询) */
  /** `GET /channels/weixin/bindings/{challenge_id}` */
  channelsWeixinBindingsStatus(challengeId: string): Promise<WeixinBindingStatusView> {
    return this.client.get<WeixinBindingStatusView>(`/channels/weixin/bindings/${challengeId}`);
  }

  /** 提交扫码配对数字 */
  /** `POST /channels/weixin/bindings/{challenge_id}/verify-code` */
  channelsWeixinBindingsVerify(challengeId: string, body: WeixinVerifyCodePayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>(`/channels/weixin/bindings/${challengeId}/verify-code`, bodyText);
  }

  /** 合集列表（按元数据可见性过滤，成员为空的不列） */
  /** `GET /collections` */
  collectionList(libraryId?: number, includeEmpty?: boolean, includeHidden?: boolean): Promise<CollectionView[]> {
    const pairs: QueryPair[] = [];
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    if (includeEmpty !== undefined && includeEmpty !== null) { pairs.push({ key: 'include_empty', value: includeEmpty }); }
    if (includeHidden !== undefined && includeHidden !== null) { pairs.push({ key: 'include_hidden', value: includeHidden }); }
    return this.client.get<CollectionView[]>('/collections' + ApiQuery.build(pairs));
  }

  /** 创建合集（筛完存为合集） */
  /** `POST /collections` */
  collectionCreate(body: CollectionPayload): Promise<CollectionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<CollectionView>('/collections', bodyText);
  }

  /** 删除合集（不动作品本身） */
  /** `DELETE /collections/{collection_id}` */
  collectionDelete(collectionId: number): Promise<void> {
    return this.client.delVoid(`/collections/${collectionId}`, null);
  }

  /** 合集详情 */
  /** `GET /collections/{collection_id}` */
  collectionGet(collectionId: number): Promise<CollectionView> {
    return this.client.get<CollectionView>(`/collections/${collectionId}`);
  }

  /** 改合集（改名 / 改规则 / 改可见性） */
  /** `PUT /collections/{collection_id}` */
  collectionUpdate(collectionId: number, body: CollectionPayload): Promise<CollectionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<CollectionView>(`/collections/${collectionId}`, bodyText);
  }

  /** 合集成员的图廊：海报 / 剧照 / 章节场景图按作品分组铺平（合集页图床浏览模式数据源） */
  /** `GET /collections/{collection_id}/gallery` */
  collectionGallery(collectionId: number, limit?: number, offset?: number, sort?: string, order?: string): Promise<LibraryGalleryGroupView[]> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (order !== undefined && order !== null) { pairs.push({ key: 'order', value: order }); }
    return this.client.get<LibraryGalleryGroupView[]>(`/collections/${collectionId}/gallery` + ApiQuery.build(pairs));
  }

  /** 合集成员（与单库海报墙同一份聚合） */
  /** `GET /collections/{collection_id}/items` */
  collectionItemsList(collectionId: number, limit?: number, offset?: number, sort?: string, order?: string): Promise<LibraryItemView[]> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (order !== undefined && order !== null) { pairs.push({ key: 'order', value: order }); }
    return this.client.get<LibraryItemView[]>(`/collections/${collectionId}/items` + ApiQuery.build(pairs));
  }

  /** 把作品加进手动合集（已在里面的忽略，不报错） */
  /** `POST /collections/{collection_id}/items` */
  collectionItemsAdd(collectionId: number, body: CollectionItemsPayload): Promise<CollectionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<CollectionView>(`/collections/${collectionId}/items`, bodyText);
  }

  /** 把一部作品移出手动合集（不动作品本身） */
  /** `DELETE /collections/{collection_id}/items/{media_item_id}` */
  collectionItemsRemove(collectionId: number, mediaItemId: number): Promise<CollectionView> {
    return this.client.del<CollectionView>(`/collections/${collectionId}/items/${mediaItemId}`, null);
  }

  /** 手动合集的排序（拖拽结果整体覆盖） */
  /** `PUT /collections/{collection_id}/order` */
  collectionItemsReorder(collectionId: number, body: CollectionItemsPayload): Promise<CollectionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<CollectionView>(`/collections/${collectionId}/order`, bodyText);
  }

  /** 系列合集的「已有 N / 共 M」与缺片名单 */
  /** `GET /collections/{collection_id}/series` */
  collectionSeriesGet(collectionId: number): Promise<CollectionSeriesView> {
    return this.client.get<CollectionSeriesView>(`/collections/${collectionId}/series`);
  }

  /** 取消这个合集的分享，链接立刻失效 */
  /** `DELETE /collections/{collection_id}/share` */
  collectionShareRevoke(collectionId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/collections/${collectionId}/share`, null);
  }

  /** 看这个合集当前的分享链接、密码和有效期 */
  /** `GET /collections/{collection_id}/share` */
  collectionShareGet(collectionId: number): Promise<ShareView | null> {
    return this.client.get<ShareView | null>(`/collections/${collectionId}/share`);
  }

  /** 把整个合集分享出去，拿到链接的人不用登录就能看 */
  /** `POST /collections/{collection_id}/share` */
  collectionShareCreate(collectionId: number, body: ShareCreateRequest): Promise<ShareView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ShareView>(`/collections/${collectionId}/share`, bodyText);
  }

  /** 列出指定来源中可浏览的电影或剧集片单 */
  /** `GET /discover/collections` */
  discoverListCollections(mediaType: MediaKind, provider: MediaSource): Promise<DiscoveryCollectionListView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'media_type', value: mediaType });
    pairs.push({ key: 'provider', value: provider });
    return this.client.get<DiscoveryCollectionListView>('/discover/collections' + ApiQuery.build(pairs));
  }

  /** 浏览指定片单中的电影或剧集 */
  /** `GET /discover/collections/{collection_ref}/titles` */
  discoverBrowseCollection(collectionRef: string, limit?: number, page?: number): Promise<DiscoveryCollectionTitlesView> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (page !== undefined && page !== null) { pairs.push({ key: 'page', value: page }); }
    return this.client.get<DiscoveryCollectionTitlesView>(`/discover/collections/${collectionRef}/titles` + ApiQuery.build(pairs));
  }

  /** 获取组合发现可用的类型选项 */
  /** `GET /discover/filters` */
  discoverFilterOptions(mediaType: MediaKind): Promise<DiscoveryFilterOptionsView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'media_type', value: mediaType });
    return this.client.get<DiscoveryFilterOptionsView>('/discover/filters' + ApiQuery.build(pairs));
  }

  /** 获取 TMDB 影人的完整影视履历及本地状态 */
  /** `GET /discover/people/{tmdb_person_id}` */
  discoverGetPersonDetails(tmdbPersonId: number): Promise<DiscoveredPersonDetailsView> {
    return this.client.get<DiscoveredPersonDetailsView>(`/discover/people/${tmdbPersonId}`);
  }

  /** 读取「正在热映/即将上映」的院线地区 */
  /** `GET /discover/region` */
  discoverRegionShow(): Promise<DiscoverRegionView> {
    return this.client.get<DiscoverRegionView>('/discover/region');
  }

  /** 切换院线地区（选择即保存，立即生效） */
  /** `PUT /discover/region` */
  discoverRegionSet(body: DiscoverRegionPayload): Promise<DiscoverRegionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<DiscoverRegionView>('/discover/region', bodyText);
  }

  /** 按类型、地区、年份、评分、片长和排序组合发现影视 */
  /** `GET /discover/titles` */
  discoverFilterTitles(mediaType: MediaKind, genreIds?: number[], originCountry?: string, year?: number, ratingGte?: number, runtimeLte?: number, sort?: DiscoverySort, page?: number): Promise<DiscoveryTitlePageView> {
    const pairs: QueryPair[] = [];
    if (originCountry !== undefined && originCountry !== null) { pairs.push({ key: 'origin_country', value: originCountry }); }
    if (year !== undefined && year !== null) { pairs.push({ key: 'year', value: year }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (runtimeLte !== undefined && runtimeLte !== null) { pairs.push({ key: 'runtime_lte', value: runtimeLte }); }
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (page !== undefined && page !== null) { pairs.push({ key: 'page', value: page }); }
    if (genreIds !== undefined && genreIds !== null) {
      for (const item of genreIds) { pairs.push({ key: 'genre_ids', value: item }); }
    }
    pairs.push({ key: 'media_type', value: mediaType });
    return this.client.get<DiscoveryTitlePageView>('/discover/titles' + ApiQuery.build(pairs));
  }

  /** 获取影视条目的完整资料、演职员、图片和相关推荐 */
  /** `GET /discover/titles/{title_ref}` */
  discoverGetTitleDetails(titleRef: string): Promise<DiscoveredTitleDetailsView> {
    return this.client.get<DiscoveredTitleDetailsView>(`/discover/titles/${titleRef}`);
  }

  /** 列出已配置的下载器及连接状态 */
  /** `GET /downloaders` */
  dlList(): Promise<DownloaderView[]> {
    return this.client.get<DownloaderView[]>('/downloaders');
  }

  /** 添加一个下载器（保存后异步测试连接） */
  /** `POST /downloaders` */
  dlAdd(body: DownloaderPayload): Promise<DownloaderView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<DownloaderView>('/downloaders', bodyText);
  }

  /** 识别手动搜索结果并预演媒体库与监听导入投递目录 */
  /** `POST /downloaders/resolve-target` */
  dlResolveTarget(body: ManualDownloadTargetPayload): Promise<ManualDownloadTargetView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ManualDownloadTargetView>('/downloaders/resolve-target', bodyText);
  }

  /** 把一条搜索结果种子提交到下载器（缺省默认下载器，可指定分流） */
  /** `POST /downloaders/submit` */
  dlSubmit(body: DownloadSubmitPayload): Promise<DownloadSubmitView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<DownloadSubmitView>('/downloaders/submit', bodyText);
  }

  /** 我的保存位置记忆（搜索结果页据此决定弹确认条还是完整弹窗） */
  /** `GET /downloaders/target-prefs` */
  dlTargetPrefsList(): Promise<DownloadTargetPrefView[]> {
    return this.client.get<DownloadTargetPrefView[]>('/downloaders/target-prefs');
  }

  /** 不再记住某个分类的保存位置 */
  /** `DELETE /downloaders/target-prefs/{category}` */
  dlTargetPrefsForget(category: string): Promise<void> {
    return this.client.delVoid(`/downloaders/target-prefs/${category}`, null);
  }

  /** 列出所有下载器里正在跑的任务，以及它们对应哪部片、哪一集 */
  /** `GET /downloaders/tasks` */
  dlTasks(): Promise<DownloadTaskListView> {
    return this.client.get<DownloadTaskListView>('/downloaders/tasks');
  }

  /** 删除下载器配置 */
  /** `DELETE /downloaders/{downloader_id}` */
  dlDelete(downloaderId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/downloaders/${downloaderId}`, null);
  }

  /** 获取单个下载器详情 */
  /** `GET /downloaders/{downloader_id}` */
  dlShow(downloaderId: number): Promise<DownloaderView> {
    return this.client.get<DownloaderView>(`/downloaders/${downloaderId}`);
  }

  /** 更新下载器配置（更新后重新测试连接） */
  /** `PUT /downloaders/{downloader_id}` */
  dlUpdate(downloaderId: number, body: DownloaderPayload): Promise<DownloaderView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<DownloaderView>(`/downloaders/${downloaderId}`, bodyText);
  }

  /** 设为默认下载器 */
  /** `POST /downloaders/{downloader_id}/default` */
  dlDefaultSet(downloaderId: number): Promise<DownloaderView> {
    return this.client.post<DownloaderView>(`/downloaders/${downloaderId}/default`, null);
  }

  /** 读取下载器的全局限速与任务队列上限 */
  /** `GET /downloaders/{downloader_id}/limits` */
  dlLimits(downloaderId: number): Promise<DownloaderLimitsView> {
    return this.client.get<DownloaderLimitsView>(`/downloaders/${downloaderId}/limits`);
  }

  /** 设置下载器的全局限速与任务队列上限 */
  /** `PUT /downloaders/{downloader_id}/limits` */
  dlLimitsSet(downloaderId: number, body: DownloaderLimitsUpdate): Promise<DownloaderLimitsView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<DownloaderLimitsView>(`/downloaders/${downloaderId}/limits`, bodyText);
  }

  /** 启用 / 停用下载器 */
  /** `PATCH /downloaders/{downloader_id}/status` */
  dlStatusSet(downloaderId: number, body: DownloaderStatusUpdate): Promise<DownloaderView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<DownloaderView>(`/downloaders/${downloaderId}/status`, bodyText);
  }

  /** 从下载器里删掉一个种子任务，可选连同已下好的文件一起删 */
  /** `DELETE /downloaders/{downloader_id}/torrents/{info_hash}` */
  dlTorrentDelete(downloaderId: number, infoHash: string, deleteFiles?: boolean): Promise<DownloadTaskDeleteView> {
    const pairs: QueryPair[] = [];
    if (deleteFiles !== undefined && deleteFiles !== null) { pairs.push({ key: 'delete_files', value: deleteFiles }); }
    return this.client.del<DownloadTaskDeleteView>(`/downloaders/${downloaderId}/torrents/${infoHash}` + ApiQuery.build(pairs), null);
  }

  /** 给卡住不动的下载立刻换一个同品质的种子源 */
  /** `POST /downloaders/{downloader_id}/torrents/{info_hash}/replace` */
  dlTorrentReplace(downloaderId: number, infoHash: string): Promise<DownloadTaskReplaceView> {
    return this.client.post<DownloadTaskReplaceView>(`/downloaders/${downloaderId}/torrents/${infoHash}/replace`, null);
  }

  /** 手动重新测试连接 */
  /** `POST /downloaders/{downloader_id}/verify` */
  dlVerify(downloaderId: number): Promise<DownloaderView> {
    return this.client.post<DownloaderView>(`/downloaders/${downloaderId}/verify`, null);
  }

  /** 推送某站点的 Cookie（保存后异步验证） */
  /** `POST /extension/cookies` */
  extensionCookiesPush(body: CookiePushRequest): Promise<CookieSyncResult> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<CookieSyncResult>('/extension/cookies', bodyText);
  }

  /** 连接与令牌自检 */
  /** `GET /extension/ping` */
  extensionPing(): Promise<PingResult> {
    return this.client.get<PingResult>('/extension/ping');
  }

  /** 列出支持 Cookie 同步的站点及配置状态 */
  /** `GET /extension/sites` */
  extensionSitesList(): Promise<ExtensionSiteView[]> {
    return this.client.get<ExtensionSiteView[]>('/extension/sites');
  }

  /** 关闭同步（撤销令牌） */
  /** `DELETE /extension/token` */
  extensionTokenRevoke(): Promise<SyncTokenView> {
    return this.client.del<SyncTokenView>('/extension/token', null);
  }

  /** 查看当前同步令牌 */
  /** `GET /extension/token` */
  extensionTokenShow(): Promise<SyncTokenView> {
    return this.client.get<SyncTokenView>('/extension/token');
  }

  /** 生成 / 重新生成同步令牌 */
  /** `POST /extension/token` */
  extensionTokenCreate(): Promise<SyncTokenView> {
    return this.client.post<SyncTokenView>('/extension/token', null);
  }

  /** 列出服务器上某个目录下有哪些子目录 */
  /** `GET /fs/browse` */
  fsBrowse(path?: string): Promise<FsBrowseView> {
    const pairs: QueryPair[] = [];
    if (path !== undefined && path !== null) { pairs.push({ key: 'path', value: path }); }
    return this.client.get<FsBrowseView>('/fs/browse' + ApiQuery.build(pairs));
  }

  /** Health check */
  /** `GET /health` */
  healthCheck(): Promise<HealthResponse> {
    return this.client.rawGet<HealthResponse>('/health');
  }

  /** 列出全部监听导入规则 */
  /** `GET /import-watch` */
  watchList(): Promise<ImportWatchView[]> {
    return this.client.get<ImportWatchView[]>('/import-watch');
  }

  /** 创建监听导入规则（硬链接策略保存即做同盘检测） */
  /** `POST /import-watch` */
  watchCreate(body: ImportWatchPayload): Promise<ImportWatchView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ImportWatchView>('/import-watch', bodyText);
  }

  /** 认领条目：钉到指定 TMDB 身份并恢复后台入库作业 */
  /** `POST /import-watch/entries/{entry_id}/claim` */
  watchEntriesClaim(entryId: number, body: MovieclawApiApiRoutesImportWatchClaimPayload): Promise<IngestEntryView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<IngestEntryView>(`/import-watch/entries/${entryId}/claim`, bodyText);
  }

  /** 忽略条目：永久跳过，不再处理（可恢复） */
  /** `POST /import-watch/entries/{entry_id}/ignore` */
  watchEntriesIgnore(entryId: number): Promise<IngestEntryView> {
    return this.client.post<IngestEntryView>(`/import-watch/entries/${entryId}/ignore`, null);
  }

  /** 恢复条目：重新进入处理流程 */
  /** `POST /import-watch/entries/{entry_id}/restore` */
  watchEntriesRestore(entryId: number): Promise<IngestEntryView> {
    return this.client.post<IngestEntryView>(`/import-watch/entries/${entryId}/restore`, null);
  }

  /** 删除监听导入规则（不动磁盘，仅停止监听） */
  /** `DELETE /import-watch/{rule_id}` */
  watchDelete(ruleId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/import-watch/${ruleId}`, null);
  }

  /** 更新监听导入规则 */
  /** `PUT /import-watch/{rule_id}` */
  watchUpdate(ruleId: number, body: ImportWatchPayload): Promise<ImportWatchView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<ImportWatchView>(`/import-watch/${ruleId}`, bodyText);
  }

  /** 一条规则的台账清单（待处理/失败/已忽略/已入库） */
  /** `GET /import-watch/{rule_id}/entries` */
  watchEntries(ruleId: number, status?: string): Promise<IngestEntriesView> {
    const pairs: QueryPair[] = [];
    if (status !== undefined && status !== null) { pairs.push({ key: 'status', value: status }); }
    return this.client.get<IngestEntriesView>(`/import-watch/${ruleId}/entries` + ApiQuery.build(pairs));
  }

  /** 查询后台任务（可按状态、类型或资源聚合） */
  /** `GET /jobs` */
  jobsList(status?: string, jobType?: string, resourceType?: string, resourceId?: string, activeOnly?: boolean, limit?: number): Promise<JobListView> {
    const pairs: QueryPair[] = [];
    if (status !== undefined && status !== null) { pairs.push({ key: 'status', value: status }); }
    if (jobType !== undefined && jobType !== null) { pairs.push({ key: 'job_type', value: jobType }); }
    if (resourceType !== undefined && resourceType !== null) { pairs.push({ key: 'resource_type', value: resourceType }); }
    if (resourceId !== undefined && resourceId !== null) { pairs.push({ key: 'resource_id', value: resourceId }); }
    if (activeOnly !== undefined && activeOnly !== null) { pairs.push({ key: 'active_only', value: activeOnly }); }
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    return this.client.get<JobListView>('/jobs' + ApiQuery.build(pairs));
  }

  /** 忽略当前所有失败任务 */
  /** `POST /jobs/dismiss-all` */
  jobsDismissAll(body?: JobDismissAllRequest): Promise<JobDismissAllView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<JobDismissAllView>('/jobs/dismiss-all', bodyText);
  }

  /** 查看后台任务执行器健康状态 */
  /** `GET /jobs/health` */
  jobsHealth(): Promise<JobWorkerHealthView> {
    return this.client.get<JobWorkerHealthView>('/jobs/health');
  }

  /** 查看后台任务详情 */
  /** `GET /jobs/{job_id}` */
  jobsShow(jobId: string): Promise<JobView> {
    return this.client.get<JobView>(`/jobs/${jobId}`);
  }

  /** 取消后台任务（在安全边界生效） */
  /** `POST /jobs/{job_id}/cancel` */
  jobsCancel(jobId: string): Promise<JobCancelView> {
    return this.client.post<JobCancelView>(`/jobs/${jobId}/cancel`, null);
  }

  /** 忽略失败的后台任务（不再计入需要处理） */
  /** `POST /jobs/{job_id}/dismiss` */
  jobsDismiss(jobId: string, body?: JobDismissRequest): Promise<JobDismissView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<JobDismissView>(`/jobs/${jobId}/dismiss`, bodyText);
  }

  /** 查看后台任务事件时间线 */
  /** `GET /jobs/{job_id}/events` */
  jobsEvents(jobId: string, after?: number, limit?: number): Promise<JobEventListView> {
    const pairs: QueryPair[] = [];
    if (after !== undefined && after !== null) { pairs.push({ key: 'after', value: after }); }
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    return this.client.get<JobEventListView>(`/jobs/${jobId}/events` + ApiQuery.build(pairs));
  }

  /** 重试失败、已取消或需要处理的后台任务 */
  /** `POST /jobs/{job_id}/retry` */
  jobsRetry(jobId: string): Promise<JobRetryView> {
    return this.client.post<JobRetryView>(`/jobs/${jobId}/retry`, null);
  }

  /** 撤销忽略，任务回到需要处理 */
  /** `POST /jobs/{job_id}/undismiss` */
  jobsUndismiss(jobId: string): Promise<JobDismissView> {
    return this.client.post<JobDismissView>(`/jobs/${jobId}/undismiss`, null);
  }

  /** 等待任务状态变化（CLI 长轮询） */
  /** `GET /jobs/{job_id}/wait` */
  jobsWait(jobId: string, afterRevision?: number, waitSeconds?: number): Promise<JobWaitView> {
    const pairs: QueryPair[] = [];
    if (afterRevision !== undefined && afterRevision !== null) { pairs.push({ key: 'after_revision', value: afterRevision }); }
    if (waitSeconds !== undefined && waitSeconds !== null) { pairs.push({ key: 'wait_seconds', value: waitSeconds }); }
    return this.client.get<JobWaitView>(`/jobs/${jobId}/wait` + ApiQuery.build(pairs));
  }

  /** 列出媒体库（含库存统计，可按类型过滤；默认只列当前身份可浏览的库） */
  /** `GET /libraries` */
  libraryList(kind?: string, scope?: string): Promise<LibraryView[]> {
    const pairs: QueryPair[] = [];
    if (kind !== undefined && kind !== null) { pairs.push({ key: 'kind', value: kind }); }
    if (scope !== undefined && scope !== null) { pairs.push({ key: 'scope', value: scope }); }
    return this.client.get<LibraryView[]>('/libraries' + ApiQuery.build(pairs));
  }

  /** 创建媒体库（该类型首个库自动成为默认，并自动开始首次扫描） */
  /** `POST /libraries` */
  libraryCreate(body: LibraryPayload): Promise<LibraryView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<LibraryView>('/libraries', bodyText);
  }

  /** 重排媒体库展示顺序（决定首页卡片与「最近添加」分区的排列） */
  /** `PUT /libraries/display-order` */
  libraryReorder(body: LibraryReorderPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<Record<string, JsonValue>>('/libraries/display-order', bodyText);
  }

  /** 重复文件：扫描状态 + 三档摘要 + 本页条目 */
  /** `GET /libraries/duplicate-files` */
  libraryDuplicatesList(tier?: string, reviewKind?: string, q?: string, libraryId?: number, mediaItemId?: number, limit?: number, offset?: number): Promise<DuplicateFilesData> {
    const pairs: QueryPair[] = [];
    if (tier !== undefined && tier !== null) { pairs.push({ key: 'tier', value: tier }); }
    if (reviewKind !== undefined && reviewKind !== null) { pairs.push({ key: 'review_kind', value: reviewKind }); }
    if (q !== undefined && q !== null) { pairs.push({ key: 'q', value: q }); }
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    if (mediaItemId !== undefined && mediaItemId !== null) { pairs.push({ key: 'media_item_id', value: mediaItemId }); }
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    return this.client.get<DuplicateFilesData>('/libraries/duplicate-files' + ApiQuery.build(pairs));
  }

  /** 一个单元 / 一季的决定：留这个 / 整季留这个版本 / 都留着 */
  /** `POST /libraries/duplicate-files/resolve` */
  libraryDuplicatesResolve(body: DuplicateResolvePayload): Promise<TrashedBatchResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TrashedBatchResultView>('/libraries/duplicate-files/resolve', bodyText);
  }

  /** 一整档 / 一组一起决定：都按建议清理，或都留着 */
  /** `POST /libraries/duplicate-files/resolve-all` */
  libraryDuplicatesResolveAll(body: DuplicateResolveAllPayload): Promise<TrashedBatchResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TrashedBatchResultView>('/libraries/duplicate-files/resolve-all', bodyText);
  }

  /** 开始扫描重复文件（可恢复后台作业，结论落库供页面读取） */
  /** `POST /libraries/duplicate-files/scan` */
  libraryDuplicatesScan(): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>('/libraries/duplicate-files/scan', null);
  }

  /** 删除该文件的一个外挂字幕（含 AI 生成的字幕；内封轨在容器内，不可删） */
  /** `DELETE /libraries/files/{file_id}/subtitles` */
  librarySubtitlesDelete(fileId: number, filename: string): Promise<SubtitleDeleteResultView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'filename', value: filename });
    return this.client.del<SubtitleDeleteResultView>(`/libraries/files/${fileId}/subtitles` + ApiQuery.build(pairs), null);
  }

  /** AI 字幕生成预检：选源结果与成本估算（发起确认框素材） */
  /** `GET /libraries/files/{file_id}/subtitles/generation-preview` */
  librarySubtitlesPreviewGeneration(fileId: number, targetLanguage?: string, secondaryLanguage?: string, sourceCandidateKey?: string): Promise<GenPreviewView> {
    const pairs: QueryPair[] = [];
    if (targetLanguage !== undefined && targetLanguage !== null) { pairs.push({ key: 'target_language', value: targetLanguage }); }
    if (secondaryLanguage !== undefined && secondaryLanguage !== null) { pairs.push({ key: 'secondary_language', value: secondaryLanguage }); }
    if (sourceCandidateKey !== undefined && sourceCandidateKey !== null) { pairs.push({ key: 'source_candidate_key', value: sourceCandidateKey }); }
    return this.client.get<GenPreviewView>(`/libraries/files/${fileId}/subtitles/generation-preview` + ApiQuery.build(pairs));
  }

  /** 发起 AI 字幕生成（后台执行；同文件单飞） */
  /** `POST /libraries/files/{file_id}/subtitles/generations` */
  librarySubtitlesGenerate(fileId: number, body: GenStartPayload): Promise<JobView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<JobView>(`/libraries/files/${fileId}/subtitles/generations`, bodyText);
  }

  /** 预览一条外挂或文本内封字幕的时间轴内容 */
  /** `GET /libraries/files/{file_id}/subtitles/preview` */
  uiLibraryFilesPreviewSubtitles(fileId: number, track: string): Promise<SubtitlePreviewView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'track', value: track });
    return this.client.get<SubtitlePreviewView>(`/libraries/files/${fileId}/subtitles/preview` + ApiQuery.build(pairs));
  }

  /** 一键校准外挂字幕时间轴（音轨互相关；strm 退字幕对字幕） */
  /** `POST /libraries/files/{file_id}/subtitles/timing-calibration` */
  librarySubtitlesCalibrateTiming(fileId: number, body: CalibratePayload): Promise<CalibrateResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<CalibrateResultView>(`/libraries/files/${fileId}/subtitles/timing-calibration`, bodyText);
  }

  /** 把多个文件一次关联到同一个 Discover 影视条目 */
  /** `POST /libraries/identification/file-title-assignments` */
  libraryIdentificationAssignFilesToTitle(body: ClaimBatchPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/identification/file-title-assignments', bodyText);
  }

  /** 标为「非独立作品」：摘掉身份锚并忽略（花絮/预告类，不动磁盘） */
  /** `POST /libraries/identification/files/mark-as-extras` */
  libraryIdentificationMarkFilesAsExtras(body: DetachPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/identification/files/mark-as-extras', bodyText);
  }

  /** 忽略一个待识别文件：以后扫描不再过问（不动磁盘） */
  /** `POST /libraries/identification/files/{file_id}/ignore` */
  libraryIdentificationIgnoreFile(fileId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/identification/files/${fileId}/ignore`, null);
  }

  /** 把一个文件明确关联到 Discover 影视条目 */
  /** `POST /libraries/identification/files/{file_id}/title-assignment` */
  libraryIdentificationAssignFileToTitle(fileId: number, body: MovieclawApiSchemasLibraryClaimPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>(`/libraries/identification/files/${fileId}/title-assignment`, bodyText);
  }

  /** 恢复已忽略的文件：重新参与识别 */
  /** `POST /libraries/identification/ignored-file-restorations` */
  libraryIdentificationRestoreFiles(body: RestorePayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/identification/ignored-file-restorations', bodyText);
  }

  /** 已忽略清单（用户说过「别再问」的文件，可恢复） */
  /** `GET /libraries/identification/ignored-files` */
  libraryIdentificationListIgnoredFiles(libraryId?: number): Promise<UnidentifiedGroupView[]> {
    const pairs: QueryPair[] = [];
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    return this.client.get<UnidentifiedGroupView[]>('/libraries/identification/ignored-files' + ApiQuery.build(pairs));
  }

  /** 身份复核清单（识别器升级后的新旧结论分歧，可按库过滤） */
  /** `GET /libraries/identification/review-cases` */
  libraryIdentificationListReviewCases(libraryId?: number): Promise<ReviewGroupView[]> {
    const pairs: QueryPair[] = [];
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    return this.client.get<ReviewGroupView[]>('/libraries/identification/review-cases' + ApiQuery.build(pairs));
  }

  /** 决定身份复核结果：采纳建议或维持当前身份 */
  /** `POST /libraries/identification/review-decisions` */
  libraryIdentificationResolveReview(body: ReviewResolvePayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/identification/review-decisions', bodyText);
  }

  /** 忽略一个媒体库内的全部待识别文件（可恢复，不动磁盘） */
  /** `POST /libraries/identification/unidentified-file-ignores` */
  libraryIdentificationIgnoreAllUnidentifiedFiles(body: UnidentifiedClearPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/identification/unidentified-file-ignores', bodyText);
  }

  /** 待识别清单（按条目目录分组，不含已忽略，可按库过滤） */
  /** `GET /libraries/identification/unidentified-files` */
  libraryIdentificationListUnidentifiedFiles(libraryId?: number): Promise<UnidentifiedGroupView[]> {
    const pairs: QueryPair[] = [];
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    return this.client.get<UnidentifiedGroupView[]>('/libraries/identification/unidentified-files' + ApiQuery.build(pairs));
  }

  /** 整季人工标注片源：把「无法确认」的洗版单元变为可判定 */
  /** `POST /libraries/media-source-annotations` */
  libraryItemsAnnotateMediaSource(body: MediaSourceAnnotationPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/media-source-annotations', bodyText);
  }

  /** 整季片源标注的预览：列出将被标注的文件（片源未知或既有人工标注） */
  /** `GET /libraries/media-source-annotations/candidates` */
  libraryItemsListMediaSourceAnnotationCandidates(mediaItemId: number, seasonNumber: number): Promise<MediaSourceAnnotationCandidateView[]> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'media_item_id', value: mediaItemId });
    pairs.push({ key: 'season_number', value: seasonNumber });
    return this.client.get<MediaSourceAnnotationCandidateView[]>('/libraries/media-source-annotations/candidates' + ApiQuery.build(pairs));
  }

  /** 清理缺失记录（只删台账，绝不动磁盘）；不带 media_item_id 清整库 */
  /** `POST /libraries/missing-record-clearances` */
  libraryMissingClearRecords(body: MissingClearPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/missing-record-clearances', bodyText);
  }

  /** 重新下载缺失内容：缺失单元交回订阅管线（无订阅则按缺失季创建） */
  /** `POST /libraries/missing-redownloads` */
  libraryMissingRedownload(body: RedownloadPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/libraries/missing-redownloads', bodyText);
  }

  /** 列出媒体库路由规则可用的媒体类型、地区预设和类型标签 */
  /** `GET /libraries/routing-options` */
  libraryListRoutingOptions(): Promise<Record<string, JsonValue>> {
    return this.client.get<Record<string, JsonValue>>('/libraries/routing-options');
  }

  /** 回收站：全部待回收文件，按条目分组分页（含摘要与分面计数） */
  /** `GET /libraries/trashed-files` */
  libraryRecycleList(q?: string, libraryId?: number, reason?: string, limit?: number, offset?: number): Promise<TrashedFilesData> {
    const pairs: QueryPair[] = [];
    if (q !== undefined && q !== null) { pairs.push({ key: 'q', value: q }); }
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    if (reason !== undefined && reason !== null) { pairs.push({ key: 'reason', value: reason }); }
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    return this.client.get<TrashedFilesData>('/libraries/trashed-files' + ApiQuery.build(pairs));
  }

  /** 批量立即清理待回收文件（按 id 或按筛选；真删磁盘） */
  /** `POST /libraries/trashed-files/purge` */
  libraryRecyclePurge(body: TrashedPurgePayload): Promise<TrashedBatchResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TrashedBatchResultView>('/libraries/trashed-files/purge', bodyText);
  }

  /** 批量恢复待回收文件为在位版本 */
  /** `POST /libraries/trashed-files/restore` */
  libraryRecycleRestore(body: TrashedRestorePayload): Promise<TrashedBatchResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TrashedBatchResultView>('/libraries/trashed-files/restore', bodyText);
  }

  /** 删除媒体库（不动磁盘文件；其订阅回落到该类型默认库；扫描/整理中锁定） */
  /** `DELETE /libraries/{library_id}` */
  libraryDelete(libraryId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/libraries/${libraryId}`, null);
  }

  /** 获取单个媒体库详情 */
  /** `GET /libraries/{library_id}` */
  libraryGet(libraryId: number): Promise<LibraryView> {
    return this.client.get<LibraryView>(`/libraries/${libraryId}`);
  }

  /** 更新媒体库（类型创建后不可改；变更根路径时要求库空闲） */
  /** `PUT /libraries/{library_id}` */
  libraryUpdate(libraryId: number, body: LibraryPayload): Promise<LibraryView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<LibraryView>(`/libraries/${libraryId}`, bodyText);
  }

  /** 生成整库的章节（可恢复后台作业；force=true 已有的也重新生成） */
  /** `POST /libraries/{library_id}/chapter-images` */
  libraryChapterImagesGenerate(libraryId: number, force?: boolean): Promise<Record<string, JsonValue>> {
    const pairs: QueryPair[] = [];
    if (force !== undefined && force !== null) { pairs.push({ key: 'force', value: force }); }
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/chapter-images` + ApiQuery.build(pairs), null);
  }

  /** 删除媒体库自定义封面（回落到自动拼贴） */
  /** `DELETE /libraries/{library_id}/cover` */
  libraryCoverClear(libraryId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/libraries/${libraryId}/cover`, null);
  }

  /** 设为该类型的默认库 */
  /** `POST /libraries/{library_id}/default-selection` */
  librarySetDefault(libraryId: number): Promise<LibraryView> {
    return this.client.post<LibraryView>(`/libraries/${libraryId}/default-selection`, null);
  }

  /** 筛选面板的候选值与计数（每一维排除自身条件后算） */
  /** `GET /libraries/{library_id}/facets` */
  libraryItemsFacets(libraryId: number, tier?: string, g?: string, c?: string, d?: string, w?: string, ratingGte?: number, rt?: string, lang?: string, res?: string, hdr?: boolean, stock?: string, seriesKeys?: string): Promise<LibraryFacetsView> {
    const pairs: QueryPair[] = [];
    if (tier !== undefined && tier !== null) { pairs.push({ key: 'tier', value: tier }); }
    if (g !== undefined && g !== null) { pairs.push({ key: 'g', value: g }); }
    if (c !== undefined && c !== null) { pairs.push({ key: 'c', value: c }); }
    if (d !== undefined && d !== null) { pairs.push({ key: 'd', value: d }); }
    if (w !== undefined && w !== null) { pairs.push({ key: 'w', value: w }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (rt !== undefined && rt !== null) { pairs.push({ key: 'rt', value: rt }); }
    if (lang !== undefined && lang !== null) { pairs.push({ key: 'lang', value: lang }); }
    if (res !== undefined && res !== null) { pairs.push({ key: 'res', value: res }); }
    if (hdr !== undefined && hdr !== null) { pairs.push({ key: 'hdr', value: hdr }); }
    if (stock !== undefined && stock !== null) { pairs.push({ key: 'stock', value: stock }); }
    if (seriesKeys !== undefined && seriesKeys !== null) { pairs.push({ key: 'series_keys', value: seriesKeys }); }
    return this.client.get<LibraryFacetsView>(`/libraries/${libraryId}/facets` + ApiQuery.build(pairs));
  }

  /** 预览整理计划：每个文件改成什么名、哪些跳过及原因（只读，不动磁盘） */
  /** `POST /libraries/{library_id}/file-organization-preview` */
  workflowLibraryOrganizeFilesPreview(libraryId: number): Promise<OrganizePreviewView> {
    return this.client.post<OrganizePreviewView>(`/libraries/${libraryId}/file-organization-preview`, null);
  }

  /** 开始整理：按规范命名批量改名归位（可恢复后台作业） */
  /** `POST /libraries/{library_id}/file-organizations` */
  workflowLibraryOrganizeFilesStart(libraryId: number): Promise<OrganizeStartView> {
    return this.client.post<OrganizeStartView>(`/libraries/${libraryId}/file-organizations`, null);
  }

  /** 库内条目的图廊：海报 / 剧照 / 章节场景图按条目分组铺平（图床浏览模式数据源） */
  /** `GET /libraries/{library_id}/gallery` */
  uiLibraryGallery(libraryId: number, limit?: number, offset?: number, sort?: string, order?: string, g?: string, c?: string, d?: string, w?: string, ratingGte?: number, rt?: string, lang?: string, res?: string, hdr?: boolean, stock?: string, seriesKeys?: string): Promise<LibraryGalleryGroupView[]> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (order !== undefined && order !== null) { pairs.push({ key: 'order', value: order }); }
    if (g !== undefined && g !== null) { pairs.push({ key: 'g', value: g }); }
    if (c !== undefined && c !== null) { pairs.push({ key: 'c', value: c }); }
    if (d !== undefined && d !== null) { pairs.push({ key: 'd', value: d }); }
    if (w !== undefined && w !== null) { pairs.push({ key: 'w', value: w }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (rt !== undefined && rt !== null) { pairs.push({ key: 'rt', value: rt }); }
    if (lang !== undefined && lang !== null) { pairs.push({ key: 'lang', value: lang }); }
    if (res !== undefined && res !== null) { pairs.push({ key: 'res', value: res }); }
    if (hdr !== undefined && hdr !== null) { pairs.push({ key: 'hdr', value: hdr }); }
    if (stock !== undefined && stock !== null) { pairs.push({ key: 'stock', value: stock }); }
    if (seriesKeys !== undefined && seriesKeys !== null) { pairs.push({ key: 'series_keys', value: seriesKeys }); }
    return this.client.get<LibraryGalleryGroupView[]>(`/libraries/${libraryId}/gallery` + ApiQuery.build(pairs));
  }

  /** 库内条目 id 集合（前端判定「已入库」用） */
  /** `GET /libraries/{library_id}/item-ids` */
  uiLibraryItemsIds(libraryId: number): Promise<number[]> {
    return this.client.get<number[]>(`/libraries/${libraryId}/item-ids`);
  }

  /** 海报墙的跳转索引（按标题：A-Z 首字母档；按内容时间：月份档） */
  /** `GET /libraries/{library_id}/item-index` */
  uiLibraryItemsIndex(libraryId: number, sort?: string, order?: string, g?: string, c?: string, d?: string, w?: string, ratingGte?: number, rt?: string, lang?: string, res?: string, hdr?: boolean, stock?: string, seriesKeys?: string): Promise<LibraryIndexEntryView[]> {
    const pairs: QueryPair[] = [];
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (order !== undefined && order !== null) { pairs.push({ key: 'order', value: order }); }
    if (g !== undefined && g !== null) { pairs.push({ key: 'g', value: g }); }
    if (c !== undefined && c !== null) { pairs.push({ key: 'c', value: c }); }
    if (d !== undefined && d !== null) { pairs.push({ key: 'd', value: d }); }
    if (w !== undefined && w !== null) { pairs.push({ key: 'w', value: w }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (rt !== undefined && rt !== null) { pairs.push({ key: 'rt', value: rt }); }
    if (lang !== undefined && lang !== null) { pairs.push({ key: 'lang', value: lang }); }
    if (res !== undefined && res !== null) { pairs.push({ key: 'res', value: res }); }
    if (hdr !== undefined && hdr !== null) { pairs.push({ key: 'hdr', value: hdr }); }
    if (stock !== undefined && stock !== null) { pairs.push({ key: 'stock', value: stock }); }
    if (seriesKeys !== undefined && seriesKeys !== null) { pairs.push({ key: 'series_keys', value: seriesKeys }); }
    return this.client.get<LibraryIndexEntryView[]>(`/libraries/${libraryId}/item-index` + ApiQuery.build(pairs));
  }

  /** 预检批量转移：空间、冲突、硬链接与做种影响一次算清（只读，不动磁盘） */
  /** `POST /libraries/{library_id}/item-transfer-preview` */
  workflowLibraryTransferItemsPreview(libraryId: number, body: BatchTransferPayload): Promise<BatchTransferPreviewView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<BatchTransferPreviewView>(`/libraries/${libraryId}/item-transfer-preview`, bodyText);
  }

  /** 条目转移的实时进度与最近一次结论 */
  /** `GET /libraries/{library_id}/item-transfer-status` */
  libraryItemsGetTransferStatus(libraryId: number): Promise<TransferStatusView> {
    return this.client.get<TransferStatusView>(`/libraries/${libraryId}/item-transfer-status`);
  }

  /** 批量转移条目到另一个媒体库：一次提交，后台逐条搬运并随迁台账 */
  /** `POST /libraries/{library_id}/item-transfers` */
  workflowLibraryTransferItemsStart(libraryId: number, body: BatchTransferPayload): Promise<TransferStartView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TransferStartView>(`/libraries/${libraryId}/item-transfers`, bodyText);
  }

  /** 库内媒体条目的库存聚合（单库海报墙数据源） */
  /** `GET /libraries/{library_id}/items` */
  libraryItemsList(libraryId: number, sort?: string, order?: string, limit?: number, offset?: number, identity?: string, g?: string, c?: string, d?: string, w?: string, ratingGte?: number, rt?: string, lang?: string, res?: string, hdr?: boolean, stock?: string, seriesKeys?: string): Promise<LibraryItemView[]> {
    const pairs: QueryPair[] = [];
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (order !== undefined && order !== null) { pairs.push({ key: 'order', value: order }); }
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    if (identity !== undefined && identity !== null) { pairs.push({ key: 'identity', value: identity }); }
    if (g !== undefined && g !== null) { pairs.push({ key: 'g', value: g }); }
    if (c !== undefined && c !== null) { pairs.push({ key: 'c', value: c }); }
    if (d !== undefined && d !== null) { pairs.push({ key: 'd', value: d }); }
    if (w !== undefined && w !== null) { pairs.push({ key: 'w', value: w }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (rt !== undefined && rt !== null) { pairs.push({ key: 'rt', value: rt }); }
    if (lang !== undefined && lang !== null) { pairs.push({ key: 'lang', value: lang }); }
    if (res !== undefined && res !== null) { pairs.push({ key: 'res', value: res }); }
    if (hdr !== undefined && hdr !== null) { pairs.push({ key: 'hdr', value: hdr }); }
    if (stock !== undefined && stock !== null) { pairs.push({ key: 'stock', value: stock }); }
    if (seriesKeys !== undefined && seriesKeys !== null) { pairs.push({ key: 'series_keys', value: seriesKeys }); }
    return this.client.get<LibraryItemView[]>(`/libraries/${libraryId}/items` + ApiQuery.build(pairs));
  }

  /** 从磁盘彻底删除条目（整个刮削目录：视频+NFO+海报+字幕一起清除） */
  /** `DELETE /libraries/{library_id}/items/{media_item_id}` */
  libraryItemsDelete(libraryId: number, mediaItemId: number): Promise<ItemDeleteResultView> {
    return this.client.del<ItemDeleteResultView>(`/libraries/${libraryId}/items/${mediaItemId}`, null);
  }

  /** 条目详情：基本信息 + NFO 本地刮削元数据 + 逐文件真实介质规格 */
  /** `GET /libraries/{library_id}/items/{media_item_id}` */
  libraryItemsGet(libraryId: number, mediaItemId: number): Promise<LibraryItemDetailView> {
    return this.client.get<LibraryItemDetailView>(`/libraries/${libraryId}/items/${mediaItemId}`);
  }

  /** `GET /libraries/kinds/{kind}/genres`：跨库「按类型找」的格子（首页那条行用它） */
  libraryKindGenres(kind: string): Promise<LibraryKindGenreView[]> {
    return this.client.get<LibraryKindGenreView[]>('/libraries/kinds/' + kind + '/genres');
  }

  /**
   * `GET /libraries/kinds/{kind}/items`：跨库条目（首页「全部电影 / 全部剧集」聚合行用它）。
   * 查询参数与单库墙一致，这里只暴露首页用得到的几个。
   */
  libraryKindItems(kind: string, sort?: string, order?: string, limit?: number, offset?: number,
    genre?: string): Promise<LibraryItemView[]> {
    const pairs: QueryPair[] = [];
    if (sort !== undefined && sort.length > 0) {
      pairs.push({ key: 'sort', value: sort });
    }
    if (order !== undefined && order.length > 0) {
      pairs.push({ key: 'order', value: order });
    }
    if (limit !== undefined && limit > 0) {
      pairs.push({ key: 'limit', value: `${limit}` });
    }
    if (offset !== undefined && offset > 0) {
      pairs.push({ key: 'offset', value: `${offset}` });
    }
    if (genre !== undefined && genre.length > 0) {
      pairs.push({ key: 'g', value: genre });
    }
    return this.client.get<LibraryItemView[]>('/libraries/kinds/' + kind + '/items'
      + ApiQuery.build(pairs));
  }

  /** 条目的候选海报/背景图/徽标列表（选图前先看这里） */
  /** `GET /libraries/{library_id}/items/{media_item_id}/artwork/candidates` */
  libraryArtworkListCandidates(libraryId: number, mediaItemId: number): Promise<ArtworkCandidatesView> {
    return this.client.get<ArtworkCandidatesView>(`/libraries/${libraryId}/items/${mediaItemId}/artwork/candidates`);
  }

  /** 选定海报/背景/徽标（当场落盘并覆盖媒体目录；此后刷新不再覆盖） */
  /** `POST /libraries/{library_id}/items/{media_item_id}/artwork/select` */
  libraryArtworkSelect(libraryId: number, mediaItemId: number, body: ArtworkSelectPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/items/${mediaItemId}/artwork/select`, bodyText);
  }

  /** 重新生成单个条目的章节（全部重抓，可恢复后台作业） */
  /** `POST /libraries/{library_id}/items/{media_item_id}/chapter-images` */
  libraryItemsRegenerateChapterImages(libraryId: number, mediaItemId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/items/${mediaItemId}/chapter-images`, null);
  }

  /** 剧集条目一季的分集清单（集名/简介/剧照 + 拥有状态，分集横滚区数据源） */
  /** `GET /libraries/{library_id}/items/{media_item_id}/episodes` */
  libraryItemsListEpisodes(libraryId: number, mediaItemId: number, seasonNumber: number): Promise<SeasonEpisodesView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'season_number', value: seasonNumber });
    return this.client.get<SeasonEpisodesView>(`/libraries/${libraryId}/items/${mediaItemId}/episodes` + ApiQuery.build(pairs));
  }

  /** 从磁盘删除条目的单个文件（含同名 NFO/字幕/图片附属文件） */
  /** `DELETE /libraries/{library_id}/items/{media_item_id}/files/{file_id}` */
  libraryItemsDeleteFile(libraryId: number, mediaItemId: number, fileId: number): Promise<ItemDeleteResultView> {
    return this.client.del<ItemDeleteResultView>(`/libraries/${libraryId}/items/${mediaItemId}/files/${fileId}`, null);
  }

  /** 立即清理一个待回收的文件（真删磁盘） */
  /** `POST /libraries/{library_id}/items/{media_item_id}/files/{file_id}/purge` */
  libraryItemsPurgeFile(libraryId: number, mediaItemId: number, fileId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/items/${mediaItemId}/files/${fileId}/purge`, null);
  }

  /** 把待回收的文件恢复为在位版本 */
  /** `POST /libraries/{library_id}/items/{media_item_id}/files/{file_id}/restore` */
  libraryItemsRestoreFile(libraryId: number, mediaItemId: number, fileId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/items/${mediaItemId}/files/${fileId}/restore`, null);
  }

  /** 刷新单个条目的元数据（强制重刮 TMDB，可恢复后台作业） */
  /** `POST /libraries/{library_id}/items/{media_item_id}/metadata/refresh` */
  libraryItemsRefreshMetadata(libraryId: number, mediaItemId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/items/${mediaItemId}/metadata/refresh`, null);
  }

  /** 修正识别结果（预览）：重走识别链只出结论，不改台账 */
  /** `POST /libraries/{library_id}/items/{media_item_id}/reidentification-preview` */
  libraryItemsPreviewReidentification(libraryId: number, mediaItemId: number): Promise<ReidentifyPreviewView> {
    return this.client.post<ReidentifyPreviewView>(`/libraries/${libraryId}/items/${mediaItemId}/reidentification-preview`, null);
  }

  /** 重新识别条目：全部在位文件重走识别链（NFO → 名称解析 → TMDB 收敛） */
  /** `POST /libraries/{library_id}/items/{media_item_id}/reidentifications` */
  libraryItemsReidentify(libraryId: number, mediaItemId: number): Promise<ReidentifyResultView> {
    return this.client.post<ReidentifyResultView>(`/libraries/${libraryId}/items/${mediaItemId}/reidentifications`, null);
  }

  /** 取消这部影片的分享，链接立刻失效 */
  /** `DELETE /libraries/{library_id}/items/{media_item_id}/share` */
  libraryItemsShareRevoke(libraryId: number, mediaItemId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/libraries/${libraryId}/items/${mediaItemId}/share`, null);
  }

  /** 看这部影片当前的分享链接、密码和有效期 */
  /** `GET /libraries/{library_id}/items/{media_item_id}/share` */
  libraryItemsShareGet(libraryId: number, mediaItemId: number): Promise<ShareView | null> {
    return this.client.get<ShareView | null>(`/libraries/${libraryId}/items/${mediaItemId}/share`);
  }

  /** 生成一条观看链接，发给没有账号的人也能看 */
  /** `POST /libraries/{library_id}/items/{media_item_id}/share` */
  libraryItemsShareCreate(libraryId: number, mediaItemId: number, body: ShareCreateRequest): Promise<ShareView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ShareView>(`/libraries/${libraryId}/items/${mediaItemId}/share`, bodyText);
  }

  /** 预览条目转移：哪些目录/文件搬到目标库的什么位置（只读，不动磁盘） */
  /** `GET /libraries/{library_id}/items/{media_item_id}/transfer-preview` */
  libraryItemsPreviewTransfer(libraryId: number, mediaItemId: number, targetLibraryId: number): Promise<TransferPreviewView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'target_library_id', value: targetLibraryId });
    return this.client.get<TransferPreviewView>(`/libraries/${libraryId}/items/${mediaItemId}/transfer-preview` + ApiQuery.build(pairs));
  }

  /** 转移条目到另一个媒体库：整个条目目录搬到目标库主根，台账随迁 */
  /** `POST /libraries/{library_id}/items/{media_item_id}/transfers` */
  libraryItemsTransfer(libraryId: number, mediaItemId: number, body: TransferPayload): Promise<TransferStartView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TransferStartView>(`/libraries/${libraryId}/items/${mediaItemId}/transfers`, bodyText);
  }

  /** 整库刷新元数据：全部已识别条目重新刮削（可恢复后台作业） */
  /** `POST /libraries/{library_id}/metadata/refresh` */
  libraryMetadataRefreshLibrary(libraryId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/metadata/refresh`, null);
  }

  /** 整库元数据刷新的实时状态（进度 + 正在处理哪几部、各在什么阶段） */
  /** `GET /libraries/{library_id}/metadata/refresh/progress` */
  libraryMetadataGetRefreshStatus(libraryId: number): Promise<MetadataRefreshView> {
    return this.client.get<MetadataRefreshView>(`/libraries/${libraryId}/metadata/refresh/progress`);
  }

  /** 停止进行中的整库元数据刷新（已刷完的保留） */
  /** `POST /libraries/{library_id}/metadata/refresh/stop` */
  libraryMetadataStopRefresh(libraryId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/metadata/refresh/stop`, null);
  }

  /** 缺失清单：文件已不在磁盘的库存，按条目聚合 */
  /** `GET /libraries/{library_id}/missing` */
  libraryMissingList(libraryId: number): Promise<MissingItemView[]> {
    return this.client.get<MissingItemView[]>(`/libraries/${libraryId}/missing`);
  }

  /** 预览历史根路径迁移修复（只读，不扫描、不修改台账） */
  /** `POST /libraries/{library_id}/path-reconciliation-preview` */
  workflowLibraryReconcilePathsPreview(libraryId: number, body: PathReconcilePayload): Promise<PathReconcilePreviewView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PathReconcilePreviewView>(`/libraries/${libraryId}/path-reconciliation-preview`, bodyText);
  }

  /** 执行历史根路径迁移修复（重新扫描新根并收口旧路径台账） */
  /** `POST /libraries/{library_id}/path-reconciliations` */
  workflowLibraryReconcilePathsStart(libraryId: number, body: PathReconcilePayload): Promise<ScanResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ScanResultView>(`/libraries/${libraryId}/path-reconciliations`, bodyText);
  }

  /** 筛空时的放宽建议（只列救得回内容的条件） */
  /** `GET /libraries/{library_id}/relax` */
  libraryItemsRelax(libraryId: number, g?: string, c?: string, d?: string, w?: string, ratingGte?: number, rt?: string, lang?: string, res?: string, hdr?: boolean, stock?: string, seriesKeys?: string): Promise<LibraryRelaxView> {
    const pairs: QueryPair[] = [];
    if (g !== undefined && g !== null) { pairs.push({ key: 'g', value: g }); }
    if (c !== undefined && c !== null) { pairs.push({ key: 'c', value: c }); }
    if (d !== undefined && d !== null) { pairs.push({ key: 'd', value: d }); }
    if (w !== undefined && w !== null) { pairs.push({ key: 'w', value: w }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (rt !== undefined && rt !== null) { pairs.push({ key: 'rt', value: rt }); }
    if (lang !== undefined && lang !== null) { pairs.push({ key: 'lang', value: lang }); }
    if (res !== undefined && res !== null) { pairs.push({ key: 'res', value: res }); }
    if (hdr !== undefined && hdr !== null) { pairs.push({ key: 'hdr', value: hdr }); }
    if (stock !== undefined && stock !== null) { pairs.push({ key: 'stock', value: stock }); }
    if (seriesKeys !== undefined && seriesKeys !== null) { pairs.push({ key: 'series_keys', value: seriesKeys }); }
    return this.client.get<LibraryRelaxView>(`/libraries/${libraryId}/relax` + ApiQuery.build(pairs));
  }

  /** 预检根路径归并：条目会搬到哪、空间够不够、根配置怎么变（只读） */
  /** `POST /libraries/{library_id}/root-consolidation-preview` */
  workflowLibraryConsolidateRootsPreview(libraryId: number, body: ConsolidateRootsPayload): Promise<ConsolidateRootsPreviewView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ConsolidateRootsPreviewView>(`/libraries/${libraryId}/root-consolidation-preview`, bodyText);
  }

  /** 归并根路径：把若干个根下的条目搬到一个根，台账随迁、根配置收口 */
  /** `POST /libraries/{library_id}/root-consolidations` */
  workflowLibraryConsolidateRootsStart(libraryId: number, body: ConsolidateRootsPayload): Promise<TransferStartView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TransferStartView>(`/libraries/${libraryId}/root-consolidations`, bodyText);
  }

  /** 扫描该库的根路径，把存量文件识别入账（后台执行） */
  /** `POST /libraries/{library_id}/scan` */
  libraryScanStart(libraryId: number): Promise<ScanResultView> {
    return this.client.post<ScanResultView>(`/libraries/${libraryId}/scan`, null);
  }

  /** 停止进行中的扫描（已入账的保留，剩余文件下次扫描继续） */
  /** `POST /libraries/{library_id}/scan/stop` */
  libraryScanStop(libraryId: number): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/libraries/${libraryId}/scan/stop`, null);
  }

  /** 查看 AI 设定（各用途的默认模型） */
  /** `GET /llm/defaults` */
  llmDefaultsShow(): Promise<LlmDefaultsView> {
    return this.client.get<LlmDefaultsView>('/llm/defaults');
  }

  /** 保存 AI 设定（各用途的默认模型） */
  /** `PUT /llm/defaults` */
  llmDefaultsUpdate(body: LlmDefaultsPayload): Promise<LlmDefaultsView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<LlmDefaultsView>('/llm/defaults', bodyText);
  }

  /** 列出对话框可选的全部模型（跨实例） */
  /** `GET /llm/models` */
  llmModels(): Promise<LlmModelOptionView[]> {
    return this.client.get<LlmModelOptionView[]>('/llm/models');
  }

  /** 列出可接入的供应商类型及其模型目录 */
  /** `GET /llm/presets` */
  llmPresets(): Promise<LlmPresetView[]> {
    return this.client.get<LlmPresetView[]>('/llm/presets');
  }

  /** 列出已接入的模型供应商实例 */
  /** `GET /llm/providers` */
  llmProvidersList(): Promise<LlmProviderView[]> {
    return this.client.get<LlmProviderView[]>('/llm/providers');
  }

  /** 接入一个模型供应商实例（保存后异步测试连接） */
  /** `POST /llm/providers` */
  llmProvidersCreate(body: LlmProviderPayload): Promise<LlmProviderView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<LlmProviderView>('/llm/providers', bodyText);
  }

  /** 删除一个模型供应商实例 */
  /** `DELETE /llm/providers/{provider_id}` */
  llmProvidersDelete(providerId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/llm/providers/${providerId}`, null);
  }

  /** 查看一个模型供应商实例 */
  /** `GET /llm/providers/{provider_id}` */
  llmProvidersShow(providerId: number): Promise<LlmProviderView> {
    return this.client.get<LlmProviderView>(`/llm/providers/${providerId}`);
  }

  /** 修改一个模型供应商实例（保存后异步测试连接） */
  /** `PUT /llm/providers/{provider_id}` */
  llmProvidersUpdate(providerId: number, body: LlmProviderPayload): Promise<LlmProviderView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<LlmProviderView>(`/llm/providers/${providerId}`, bodyText);
  }

  /** 手动重新测试一个实例的模型连接 */
  /** `POST /llm/providers/{provider_id}/verify` */
  llmProvidersVerify(providerId: number): Promise<LlmProviderView> {
    return this.client.post<LlmProviderView>(`/llm/providers/${providerId}/verify`, null);
  }

  /** 新建 MCP 端点（令牌明文仅本次返回） */
  /** `POST /mcp/endpoints` */
  mcpEndpointsCreate(body: EndpointCreateRequest): Promise<EndpointCreatedView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<EndpointCreatedView>('/mcp/endpoints', bodyText);
  }

  /** 试算：给定服务集合会暴露哪些工具、占多少上下文 */
  /** `POST /mcp/endpoints/preview` */
  mcpEndpointsPreview(body: PreviewRequest): Promise<PreviewView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PreviewView>('/mcp/endpoints/preview', bodyText);
  }

  /** 删除端点（地址与令牌一并作废） */
  /** `DELETE /mcp/endpoints/{endpoint_id}` */
  mcpEndpointsDelete(endpointId: string): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/mcp/endpoints/${endpointId}`, null);
  }

  /** 修改端点的名称、服务、工具模式或启停状态 */
  /** `PUT /mcp/endpoints/{endpoint_id}` */
  mcpEndpointsUpdate(endpointId: string, body: EndpointUpdateRequest): Promise<EndpointView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<EndpointView>(`/mcp/endpoints/${endpointId}`, bodyText);
  }

  /** 自检端点：协议握手、工具面与一次只读调用 */
  /** `POST /mcp/endpoints/{endpoint_id}/check` */
  mcpEndpointsCheck(endpointId: string): Promise<SelfCheckView> {
    return this.client.post<SelfCheckView>(`/mcp/endpoints/${endpointId}/check`, null);
  }

  /** 轮换端点令牌（旧令牌即刻失效，新明文仅本次返回） */
  /** `POST /mcp/endpoints/{endpoint_id}/token` */
  mcpEndpointsRotateToken(endpointId: string): Promise<EndpointCreatedView> {
    return this.client.post<EndpointCreatedView>(`/mcp/endpoints/${endpointId}/token`, null);
  }

  /** MCP 总开关、端点清单与可选服务目录 */
  /** `GET /mcp/status` */
  mcpStatus(): Promise<StatusView> {
    return this.client.get<StatusView>('/mcp/status');
  }

  /** 开启或关闭 MCP 服务（关闭后所有端点一律 404） */
  /** `PUT /mcp/status` */
  mcpToggle(body: ToggleRequest): Promise<StatusView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<StatusView>('/mcp/status', bodyText);
  }

  /** 成员列表（含能力开关与白名单摘要） */
  /** `GET /members` */
  membersList(): Promise<MemberView[]> {
    return this.client.get<MemberView[]>('/members');
  }

  /** 新建成员（把用户名和初始密码发给对方，登录后可自行修改） */
  /** `POST /members` */
  membersCreate(body: MemberCreateRequest): Promise<MemberView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<MemberView>('/members', bodyText);
  }

  /** 删除成员（清理其个人数据；订阅与已下载内容保留） */
  /** `DELETE /members/{member_id}` */
  membersDelete(memberId: number): Promise<void> {
    return this.client.delVoid(`/members/${memberId}`, null);
  }

  /** 成员详情 */
  /** `GET /members/{member_id}` */
  membersShow(memberId: number): Promise<MemberView> {
    return this.client.get<MemberView>(`/members/${memberId}`);
  }

  /** 编辑成员（昵称 / 能力开关 / 可见库与可用站点白名单） */
  /** `PUT /members/{member_id}` */
  membersUpdate(memberId: number, body: MemberUpdateRequest): Promise<MemberView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<MemberView>(`/members/${memberId}`, bodyText);
  }

  /** 重置成员密码（新密码明文仅返回这一次） */
  /** `POST /members/{member_id}/reset-password` */
  membersPasswordReset(memberId: number): Promise<MemberPasswordResetView> {
    return this.client.post<MemberPasswordResetView>(`/members/${memberId}/reset-password`, null);
  }

  /** 让成员在全部设备上下线（网页、App、命令行、播放器；账号本身不动） */
  /** `POST /members/{member_id}/sign-out` */
  membersSignOut(memberId: number): Promise<MemberView> {
    return this.client.post<MemberView>(`/members/${memberId}/sign-out`, null);
  }

  /** 启用 / 停用成员（停用即时踢下线，数据全部保留） */
  /** `PUT /members/{member_id}/status` */
  membersStatusSet(memberId: number, body: MemberStatusRequest): Promise<MemberView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<MemberView>(`/members/${memberId}/status`, bodyText);
  }

  /** 读取网络与代理配置 */
  /** `GET /network/config` */
  netShow(): Promise<NetworkConfigView> {
    return this.client.get<NetworkConfigView>('/network/config');
  }

  /** 保存网络与代理配置（立即生效，无需重启） */
  /** `PUT /network/config` */
  netSet(body: NetworkConfigPayload): Promise<NetworkConfigView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<NetworkConfigView>('/network/config', bodyText);
  }

  /** 按服务做一次连通性测试（走当前保存的出口配置） */
  /** `POST /network/test` */
  netTest(body: NetworkTestPayload): Promise<NetworkTestResult> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<NetworkTestResult>('/network/test', bodyText);
  }

  /** 人物页：库内这个影人的档案与作品 */
  /** `GET /people/{tmdb_person_id}` */
  peopleShow(tmdbPersonId: number): Promise<PersonView> {
    return this.client.get<PersonView>(`/people/${tmdbPersonId}`);
  }

  /** 看此刻家里谁在看什么、用哪台设备、速度多快 */
  /** `GET /playback/activity` */
  playbackActivity(scope?: string): Promise<MediaActivityView> {
    const pairs: QueryPair[] = [];
    if (scope !== undefined && scope !== null) { pairs.push({ key: 'scope', value: scope }); }
    return this.client.get<MediaActivityView>('/playback/activity' + ApiQuery.build(pairs));
  }

  /** 掐断某台设备正在进行的播放（不影响登录） */
  /** `POST /playback/activity/sessions/{device_id}/end` */
  playbackActivityEnd(deviceId: string): Promise<void> {
    return this.client.postVoid(`/playback/activity/sessions/${deviceId}/end`, null);
  }

  /** 一次播放的完整记录与时间线 */
  /** `GET /playback/attempts/{attempt_id}` */
  playbackAttemptGet(attemptId: string): Promise<PlaybackAttemptView> {
    return this.client.get<PlaybackAttemptView>(`/playback/attempts/${attemptId}`);
  }

  /** 播放器客户端日志 */
  /** `POST /playback/client-log` */
  playbackClientLog(body: PlaybackClientLogPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/playback/client-log', bodyText);
  }

  /** 播放决策 */
  /** `POST /playback/decide` */
  playbackDecide(body: PlaybackDecideRequest): Promise<PlaybackDecisionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PlaybackDecisionView>('/playback/decide', bodyText);
  }

  /** 注销一台播放设备，让它下次必须重新登录 */
  /** `DELETE /playback/devices/{device_id}` */
  playbackDeviceRevoke(deviceId: string): Promise<void> {
    return this.client.delVoid(`/playback/devices/${deviceId}`, null);
  }

  /** 我的收藏 */
  /** `GET /playback/favorites` */
  playbackFavorites(limit?: number, offset?: number, unwatchedFirst?: boolean, sort?: string, order?: string): Promise<FavoritesView> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    if (unwatchedFirst !== undefined && unwatchedFirst !== null) { pairs.push({ key: 'unwatched_first', value: unwatchedFirst }); }
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (order !== undefined && order !== null) { pairs.push({ key: 'order', value: order }); }
    return this.client.get<FavoritesView>('/playback/favorites' + ApiQuery.build(pairs));
  }

  /** 我的收藏 · 图廊：收藏作品的海报 / 剧照 / 章节场景图按作品分组铺平 */
  /** `GET /playback/favorites/gallery` */
  playbackFavoritesGallery(limit?: number, offset?: number, sort?: string, order?: string): Promise<LibraryGalleryGroupView[]> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    if (sort !== undefined && sort !== null) { pairs.push({ key: 'sort', value: sort }); }
    if (order !== undefined && order !== null) { pairs.push({ key: 'order', value: order }); }
    return this.client.get<LibraryGalleryGroupView[]>('/playback/favorites/gallery' + ApiQuery.build(pairs));
  }

  /** 原盘目录清单（目录直推） */
  /** `GET /playback/files/{file_id}/disc` */
  playbackFileDiscList(fileId: number, token: string): Promise<PlaybackDiscListingView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'token', value: token });
    return this.client.get<PlaybackDiscListingView>(`/playback/files/${fileId}/disc` + ApiQuery.build(pairs));
  }

  /** 内嵌字体清单 */
  /** `GET /playback/files/{file_id}/fonts` */
  playbackFileFonts(fileId: number, token: string): Promise<PlaybackFontsView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'token', value: token });
    return this.client.get<PlaybackFontsView>(`/playback/files/${fileId}/fonts` + ApiQuery.build(pairs));
  }

  /** 进度条缩略图索引 */
  /** `GET /playback/files/{file_id}/trickplay` */
  playbackFileTrickplay(fileId: number, token: string): Promise<TrickplayView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'token', value: token });
    return this.client.get<TrickplayView>(`/playback/files/${fileId}/trickplay` + ApiQuery.build(pairs));
  }

  /** 硬件加速自检 */
  /** `GET /playback/hardware` */
  playbackHardwareProbe(refresh?: boolean): Promise<HwProbeView> {
    const pairs: QueryPair[] = [];
    if (refresh !== undefined && refresh !== null) { pairs.push({ key: 'refresh', value: refresh }); }
    return this.client.get<HwProbeView>('/playback/hardware' + ApiQuery.build(pairs));
  }

  /** 清除自己的观看记录（按条目 / 按库 / 全部） */
  /** `DELETE /playback/history` */
  playbackHistoryClear(scope: string, mediaItemId?: number, libraryId?: number, since?: string): Promise<PlaybackHistoryClearView> {
    const pairs: QueryPair[] = [];
    if (mediaItemId !== undefined && mediaItemId !== null) { pairs.push({ key: 'media_item_id', value: mediaItemId }); }
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    if (since !== undefined && since !== null) { pairs.push({ key: 'since', value: since }); }
    pairs.push({ key: 'scope', value: scope });
    return this.client.del<PlaybackHistoryClearView>('/playback/history' + ApiQuery.build(pairs), null);
  }

  /** 翻看每一场播放的流水：谁、什么时候、看了什么、看了多久 */
  /** `GET /playback/history` */
  playbackHistory(limit?: number, before?: number, days?: number, memberId?: number, scope?: string): Promise<PlaybackHistoryView> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (before !== undefined && before !== null) { pairs.push({ key: 'before', value: before }); }
    if (days !== undefined && days !== null) { pairs.push({ key: 'days', value: days }); }
    if (memberId !== undefined && memberId !== null) { pairs.push({ key: 'member_id', value: memberId }); }
    if (scope !== undefined && scope !== null) { pairs.push({ key: 'scope', value: scope }); }
    return this.client.get<PlaybackHistoryView>('/playback/history' + ApiQuery.build(pairs));
  }

  /** 播放页条目信息（标题/海报/库归属） */
  /** `GET /playback/items/{media_item_id}` */
  playbackItemInfo(mediaItemId: number): Promise<PlaybackItemView> {
    return this.client.get<PlaybackItemView>(`/playback/items/${mediaItemId}`);
  }

  /** 播放页一季的分集清单（切集/上一集下一集数据源） */
  /** `GET /playback/items/{media_item_id}/episodes` */
  playbackItemEpisodes(mediaItemId: number, seasonNumber: number): Promise<SeasonEpisodesView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'season_number', value: seasonNumber });
    return this.client.get<SeasonEpisodesView>(`/playback/items/${mediaItemId}/episodes` + ApiQuery.build(pairs));
  }

  /** 已看 / 收藏状态 */
  /** `GET /playback/marks` */
  playbackMarksGet(mediaItemId: number, seasonNumber?: number, episodeNumber?: number): Promise<PlaybackMarksView> {
    const pairs: QueryPair[] = [];
    if (seasonNumber !== undefined && seasonNumber !== null) { pairs.push({ key: 'season_number', value: seasonNumber }); }
    if (episodeNumber !== undefined && episodeNumber !== null) { pairs.push({ key: 'episode_number', value: episodeNumber }); }
    pairs.push({ key: 'media_item_id', value: mediaItemId });
    return this.client.get<PlaybackMarksView>('/playback/marks' + ApiQuery.build(pairs));
  }

  /** 标记已看 / 收藏 */
  /** `POST /playback/marks` */
  playbackMarksSet(body: PlaybackMarksRequest): Promise<PlaybackMarksView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PlaybackMarksView>('/playback/marks', bodyText);
  }

  /** 上报播放质量 */
  /** `POST /playback/metrics` */
  playbackMetricReport(body: PlaybackMetricPayload): Promise<Record<string, JsonValue>> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<Record<string, JsonValue>>('/playback/metrics', bodyText);
  }

  /** 读取播放策略 */
  /** `GET /playback/policy` */
  playbackPolicyShow(): Promise<PlaybackPolicyView> {
    return this.client.get<PlaybackPolicyView>('/playback/policy');
  }

  /** 保存播放策略 */
  /** `PUT /playback/policy` */
  playbackPolicySet(body: PlaybackPolicyPayload): Promise<PlaybackPolicyView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<PlaybackPolicyView>('/playback/policy', bodyText);
  }

  /** 上报观看进度 */
  /** `POST /playback/progress` */
  playbackProgress(body: PlaybackProgressRequest): Promise<PlaybackStateView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PlaybackStateView>('/playback/progress', bodyText);
  }

  /** 续播点与记忆轨 */
  /** `GET /playback/resume` */
  playbackResume(mediaItemId: number, seasonNumber?: number, episodeNumber?: number): Promise<PlaybackStateView> {
    const pairs: QueryPair[] = [];
    if (seasonNumber !== undefined && seasonNumber !== null) { pairs.push({ key: 'season_number', value: seasonNumber }); }
    if (episodeNumber !== undefined && episodeNumber !== null) { pairs.push({ key: 'episode_number', value: episodeNumber }); }
    pairs.push({ key: 'media_item_id', value: mediaItemId });
    return this.client.get<PlaybackStateView>('/playback/resume' + ApiQuery.build(pairs));
  }

  /** 开始播放 */
  /** `POST /playback/sessions` */
  playbackSessionStart(body: PlaybackSessionRequest): Promise<PlaybackSessionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PlaybackSessionView>('/playback/sessions', bodyText);
  }

  /** 结束播放 */
  /** `DELETE /playback/sessions/{session_id}` */
  playbackSessionStop(sessionId: string): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/playback/sessions/${sessionId}`, null);
  }

  /** 播放会话诊断 */
  /** `GET /playback/sessions/{session_id}/diagnostics` */
  playbackSessionDiagnostics(sessionId: string, token: string): Promise<PlaybackDiagnosticsView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'token', value: token });
    return this.client.get<PlaybackDiagnosticsView>(`/playback/sessions/${sessionId}/diagnostics` + ApiQuery.build(pairs));
  }

  /** 播放心跳 */
  /** `POST /playback/sessions/{session_id}/ping` */
  playbackSessionPing(sessionId: string): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/playback/sessions/${sessionId}/ping`, null);
  }

  /** 播放质量汇总 */
  /** `GET /playback/stats` */
  playbackStats(): Promise<PlaybackStatsView> {
    return this.client.get<PlaybackStatsView>('/playback/stats');
  }

  /** 播放体验统计：无打扰播放率、起播与跳转分位、中断、规格损失、最差的播放 */
  /** `GET /playback/stats/qoe` */
  playbackStatsQoe(days?: number, groupBy?: string, includeLab?: boolean, worst?: number): Promise<PlaybackQoeStatsView> {
    const pairs: QueryPair[] = [];
    if (days !== undefined && days !== null) { pairs.push({ key: 'days', value: days }); }
    if (groupBy !== undefined && groupBy !== null) { pairs.push({ key: 'group_by', value: groupBy }); }
    if (includeLab !== undefined && includeLab !== null) { pairs.push({ key: 'include_lab', value: includeLab }); }
    if (worst !== undefined && worst !== null) { pairs.push({ key: 'worst', value: worst }); }
    return this.client.get<PlaybackQoeStatsView>('/playback/stats/qoe' + ApiQuery.build(pairs));
  }

  /** 一段时间的观看总览：看了多久、多少场、看完率、活跃了几个人 */
  /** `GET /playback/stats/watch` */
  playbackStatsWatch(days?: number, tzOffset?: number, memberId?: number, scope?: string): Promise<PlaybackWatchStatsView> {
    const pairs: QueryPair[] = [];
    if (days !== undefined && days !== null) { pairs.push({ key: 'days', value: days }); }
    if (tzOffset !== undefined && tzOffset !== null) { pairs.push({ key: 'tz_offset', value: tzOffset }); }
    if (memberId !== undefined && memberId !== null) { pairs.push({ key: 'member_id', value: memberId }); }
    if (scope !== undefined && scope !== null) { pairs.push({ key: 'scope', value: scope }); }
    return this.client.get<PlaybackWatchStatsView>('/playback/stats/watch' + ApiQuery.build(pairs));
  }

  /** 接下来继续 */
  /** `GET /playback/up-next` */
  playbackUpNext(limit?: number, thisDevice?: boolean): Promise<UpNextView> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (thisDevice !== undefined && thisDevice !== null) { pairs.push({ key: 'this_device', value: thisDevice }); }
    return this.client.get<UpNextView>('/playback/up-next' + ApiQuery.build(pairs));
  }

  /** 刷片：取一页片段 */
  /** `GET /reels` */
  reelsFeed(seed?: number, offset?: number, limit?: number, modes?: string, kind?: string, g?: string, c?: string, d?: string, w?: string, ratingGte?: number, rt?: string, lang?: string, res?: string, hdr?: boolean, stock?: string, seriesKeys?: string): Promise<ReelFeedView> {
    const pairs: QueryPair[] = [];
    if (seed !== undefined && seed !== null) { pairs.push({ key: 'seed', value: seed }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (modes !== undefined && modes !== null) { pairs.push({ key: 'modes', value: modes }); }
    if (kind !== undefined && kind !== null) { pairs.push({ key: 'kind', value: kind }); }
    if (g !== undefined && g !== null) { pairs.push({ key: 'g', value: g }); }
    if (c !== undefined && c !== null) { pairs.push({ key: 'c', value: c }); }
    if (d !== undefined && d !== null) { pairs.push({ key: 'd', value: d }); }
    if (w !== undefined && w !== null) { pairs.push({ key: 'w', value: w }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (rt !== undefined && rt !== null) { pairs.push({ key: 'rt', value: rt }); }
    if (lang !== undefined && lang !== null) { pairs.push({ key: 'lang', value: lang }); }
    if (res !== undefined && res !== null) { pairs.push({ key: 'res', value: res }); }
    if (hdr !== undefined && hdr !== null) { pairs.push({ key: 'hdr', value: hdr }); }
    if (stock !== undefined && stock !== null) { pairs.push({ key: 'stock', value: stock }); }
    if (seriesKeys !== undefined && seriesKeys !== null) { pairs.push({ key: 'series_keys', value: seriesKeys }); }
    return this.client.get<ReelFeedView>('/reels' + ApiQuery.build(pairs));
  }

  /** 刷片：上报事件 */
  /** `POST /reels/events` */
  reelsEvents(body: ReelEventBatch): Promise<ReelEventResult> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ReelEventResult>('/reels/events', bodyText);
  }

  /** 刷片：筛选菜单的候选值与计数（每一维排除自身条件后算） */
  /** `GET /reels/facets` */
  reelsFacets(kind?: string, g?: string, c?: string, d?: string, w?: string, ratingGte?: number, rt?: string, lang?: string, res?: string, hdr?: boolean, stock?: string, seriesKeys?: string): Promise<ReelFacetsView> {
    const pairs: QueryPair[] = [];
    if (kind !== undefined && kind !== null) { pairs.push({ key: 'kind', value: kind }); }
    if (g !== undefined && g !== null) { pairs.push({ key: 'g', value: g }); }
    if (c !== undefined && c !== null) { pairs.push({ key: 'c', value: c }); }
    if (d !== undefined && d !== null) { pairs.push({ key: 'd', value: d }); }
    if (w !== undefined && w !== null) { pairs.push({ key: 'w', value: w }); }
    if (ratingGte !== undefined && ratingGte !== null) { pairs.push({ key: 'rating_gte', value: ratingGte }); }
    if (rt !== undefined && rt !== null) { pairs.push({ key: 'rt', value: rt }); }
    if (lang !== undefined && lang !== null) { pairs.push({ key: 'lang', value: lang }); }
    if (res !== undefined && res !== null) { pairs.push({ key: 'res', value: res }); }
    if (hdr !== undefined && hdr !== null) { pairs.push({ key: 'hdr', value: hdr }); }
    if (stock !== undefined && stock !== null) { pairs.push({ key: 'stock', value: stock }); }
    if (seriesKeys !== undefined && seriesKeys !== null) { pairs.push({ key: 'series_keys', value: seriesKeys }); }
    return this.client.get<ReelFacetsView>('/reels/facets' + ApiQuery.build(pairs));
  }

  /** 规则组列表（首次访问自动创建默认组） */
  /** `GET /rule-sets` */
  rulesList(): Promise<RuleSetView[]> {
    return this.client.get<RuleSetView[]>('/rule-sets');
  }

  /** 创建规则组 */
  /** `POST /rule-sets` */
  rulesCreate(body: RuleSetPayload): Promise<RuleSetView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<RuleSetView>('/rule-sets', bodyText);
  }

  /** 删除规则组（默认组与被引用的组禁删） */
  /** `DELETE /rule-sets/{rule_set_id}` */
  rulesDelete(ruleSetId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/rule-sets/${ruleSetId}`, null);
  }

  /** 更新规则组（只影响之后的匹配评估） */
  /** `PUT /rule-sets/{rule_set_id}` */
  rulesUpdate(ruleSetId: number, body: RuleSetPayload): Promise<RuleSetView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<RuleSetView>(`/rule-sets/${ruleSetId}`, bodyText);
  }

  /** 设为默认规则组（新订阅未指定规则组时使用） */
  /** `POST /rule-sets/{rule_set_id}/default` */
  rulesDefault(ruleSetId: number): Promise<RuleSetView> {
    return this.client.post<RuleSetView>(`/rule-sets/${ruleSetId}/default`, null);
  }

  /** 定时任务：周期、启停与最近/下次执行 */
  /** `GET /scheduled-tasks` */
  appTasksList(): Promise<ScheduledTaskView[]> {
    return this.client.get<ScheduledTaskView[]>('/scheduled-tasks');
  }

  /** 改一个定时任务的周期 / 启停（立即重排，不用重启） */
  /** `PUT /scheduled-tasks/{task_key}` */
  appTasksUpdate(taskKey: string, body: ScheduledTaskUpdate): Promise<ScheduledTaskView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<ScheduledTaskView>(`/scheduled-tasks/${taskKey}`, bodyText);
  }

  /** 读取刮削与整理配置 */
  /** `GET /scrape/config` */
  scrapeShow(): Promise<ScrapeConfigView> {
    return this.client.get<ScrapeConfigView>('/scrape/config');
  }

  /** 修改刮削与整理配置：只更新给出的字段，没给的保持原样（立即生效） */
  /** `PUT /scrape/config` */
  scrapeSet(body: MetadataScrapeSettingInput): Promise<ScrapeConfigView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<ScrapeConfigView>('/scrape/config', bodyText);
  }

  /** 完整地区表（供「更多地区」搜索面板） */
  /** `GET /scrape/country-options` */
  scrapeCountries(): Promise<CountryOption[]> {
    return this.client.get<CountryOption[]>('/scrape/country-options');
  }

  /** 完整语种表（供「更多语言」搜索面板） */
  /** `GET /scrape/language-options` */
  scrapeLanguages(): Promise<LanguageOption[]> {
    return this.client.get<LanguageOption[]>('/scrape/language-options');
  }

  /** 清空搜索历史；`vertical` 传 `titles` / `torrents` 只清该分区（媒体库没有历史，不能以空清全部） */
  /** `DELETE /search/history` */
  searchHistoryClear(vertical?: string): Promise<void> {
    const query: string = vertical !== undefined && vertical !== null && vertical.length > 0
      ? `?vertical=${encodeURIComponent(vertical)}` : '';
    return this.client.delVoid('/search/history' + query, null);
  }

  /** 获取最近的搜索历史；`vertical` 传 `titles` / `torrents` 只取该分区（媒体库没有历史） */
  /** `GET /search/history` */
  searchHistoryList(limit?: number, vertical?: string): Promise<SearchHistoryItem[]> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (vertical !== undefined && vertical !== null && vertical.length > 0) {
      pairs.push({ key: 'vertical', value: vertical });
    }
    return this.client.get<SearchHistoryItem[]>('/search/history' + ApiQuery.build(pairs));
  }

  /** 删除单条搜索历史 */
  /** `DELETE /search/history/{history_id}` */
  searchHistoryDelete(historyId: number): Promise<void> {
    return this.client.delVoid(`/search/history/${historyId}`, null);
  }

  /** 读取一条影视搜索历史保存的结果快照（历史无快照时后端报 404，调用方回退实时搜索） */
  /** `GET /search/history/{history_id}/results` */
  searchHistorySnapshot(historyId: number): Promise<TitleSearchHistoryResultsView> {
    return this.client.get<TitleSearchHistoryResultsView>(`/search/history/${historyId}/results`);
  }

  /** 媒体库名称、别名、拼音及人物搜索（相关度排序，稳定分页） */
  /** `GET /search/library` */
  searchLibrary(q: string, cursor?: string | null): Promise<LibrarySearchView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'q', value: q });
    if (cursor !== undefined && cursor !== null && cursor.length > 0) {
      pairs.push({ key: 'cursor', value: cursor });
    }
    return this.client.get<LibrarySearchView>('/search/library' + ApiQuery.build(pairs));
  }

  /** 列出资源搜索的内置分类与自定义站点组合预设 */
  /** `GET /search/presets` */
  searchPresetsList(): Promise<SearchPresetListView> {
    return this.client.get<SearchPresetListView>('/search/presets');
  }

  /** 整体保存资源搜索的分类与站点组合预设 */
  /** `PUT /search/presets` */
  searchPresetsUpdate(body: SearchPresetUpdate): Promise<SearchPresetListView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<SearchPresetListView>('/search/presets', bodyText);
  }

  /** 按片名搜索 TMDB、豆瓣或全部影视来源 */
  /** `POST /search/titles` */
  searchTitles(body: TitleSearchPayload): Promise<TitleSearchView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<TitleSearchView>('/search/titles', bodyText);
  }

  /** 跨站点并发搜索种子资源（关键词留空 = 按分类浏览各站种子列表） */
  /** `GET /search/torrents` */
  searchTorrents(keyword?: string, categories?: TorrentCategory[], sites?: string[], label?: string, noHistory?: boolean, posterMode?: boolean, page?: number): Promise<SearchResponse> {
    const pairs: QueryPair[] = [];
    if (keyword !== undefined && keyword !== null) { pairs.push({ key: 'keyword', value: keyword }); }
    if (label !== undefined && label !== null) { pairs.push({ key: 'label', value: label }); }
    if (noHistory !== undefined && noHistory !== null) { pairs.push({ key: 'no_history', value: noHistory }); }
    if (posterMode !== undefined && posterMode !== null) { pairs.push({ key: 'poster_mode', value: posterMode }); }
    if (page !== undefined && page !== null) { pairs.push({ key: 'page', value: page }); }
    if (categories !== undefined && categories !== null) {
      for (const item of categories) { pairs.push({ key: 'categories', value: item }); }
    }
    if (sites !== undefined && sites !== null) {
      for (const item of sites) { pairs.push({ key: 'sites', value: item }); }
    }
    return this.client.get<SearchResponse>('/search/torrents' + ApiQuery.build(pairs));
  }

  /** 最近会话列表（按最后活跃时间倒序） */
  /** `GET /sessions` */
  sessionList(limit?: number, offset?: number): Promise<SessionSummary[]> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    if (offset !== undefined && offset !== null) { pairs.push({ key: 'offset', value: offset }); }
    return this.client.get<SessionSummary[]>('/sessions' + ApiQuery.build(pairs));
  }

  /** 开始新会话，或向已有会话发送用户消息 */
  /** `POST /sessions` */
  sessionStart(body: SessionStartPayload): Promise<SessionMessageAcceptedView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SessionMessageAcceptedView>('/sessions', bodyText);
  }

  /** 删除会话（转录文件与索引一并删除） */
  /** `DELETE /sessions/{session_id}` */
  sessionDelete(sessionId: string): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/sessions/${sessionId}`, null);
  }

  /** 读取会话的完整轨迹 */
  /** `GET /sessions/{session_id}` */
  sessionGetTranscript(sessionId: string): Promise<SessionTranscriptView> {
    return this.client.get<SessionTranscriptView>(`/sessions/${sessionId}`);
  }

  /** 重命名会话 */
  /** `PATCH /sessions/{session_id}` */
  sessionRename(sessionId: string, body: SessionRenamePayload): Promise<SessionSummary> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<SessionSummary>(`/sessions/${sessionId}`, bodyText);
  }

  /** 手动压缩会话上下文 */
  /** `POST /sessions/{session_id}/compact-context` */
  sessionCompactContext(sessionId: string): Promise<SessionContextCompactionView> {
    return this.client.post<SessionContextCompactionView>(`/sessions/${sessionId}/compact-context`, null);
  }

  /** 从已有上下文创建独立的新会话 */
  /** `POST /sessions/{session_id}/fork` */
  sessionFork(sessionId: string): Promise<SessionTranscriptView> {
    return this.client.post<SessionTranscriptView>(`/sessions/${sessionId}/fork`, null);
  }

  /** 重新提交指定用户消息（可替换问题内容） */
  /** `POST /sessions/{session_id}/retry` */
  sessionRetry(sessionId: string, body: SessionRetryPayload): Promise<SessionMessageAcceptedView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SessionMessageAcceptedView>(`/sessions/${sessionId}/retry`, bodyText);
  }

  /** 停止会话当前消息的模型处理 */
  /** `POST /sessions/{session_id}/stop` */
  sessionStop(sessionId: string): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/sessions/${sessionId}/stop`, null);
  }

  /** 分享探针：要不要密码、本浏览器是否已解锁 */
  /** `GET /share/{slug}` */
  shareProbe(slug: string): Promise<SharePublicView> {
    return this.client.get<SharePublicView>(`/share/${slug}`);
  }

  /** 分享页的合集信息（名字 + 此刻的成员） */
  /** `GET /share/{slug}/collection` */
  shareCollection(slug: string): Promise<SharedCollectionView> {
    return this.client.get<SharedCollectionView>(`/share/${slug}/collection`);
  }

  /** 分享页一季的分集清单 */
  /** `GET /share/{slug}/episodes` */
  shareEpisodes(slug: string, seasonNumber: number, item?: number): Promise<SeasonEpisodesView> {
    const pairs: QueryPair[] = [];
    if (item !== undefined && item !== null) { pairs.push({ key: 'item', value: item }); }
    pairs.push({ key: 'season_number', value: seasonNumber });
    return this.client.get<SeasonEpisodesView>(`/share/${slug}/episodes` + ApiQuery.build(pairs));
  }

  /** 分享页的影片信息 */
  /** `GET /share/{slug}/item` */
  shareItem(slug: string, item?: number): Promise<SharedItemView> {
    const pairs: QueryPair[] = [];
    if (item !== undefined && item !== null) { pairs.push({ key: 'item', value: item }); }
    return this.client.get<SharedItemView>(`/share/${slug}/item` + ApiQuery.build(pairs));
  }

  /** 分享页播放决策 */
  /** `POST /share/{slug}/playback/decide` */
  sharePlaybackDecide(slug: string, body: PlaybackDecideRequest): Promise<PlaybackDecisionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PlaybackDecisionView>(`/share/${slug}/playback/decide`, bodyText);
  }

  /** 分享页播放器的条目信息 */
  /** `GET /share/{slug}/playback/items/{media_item_id}` */
  sharePlaybackItem(mediaItemId: number, slug: string): Promise<PlaybackItemView> {
    return this.client.get<PlaybackItemView>(`/share/${slug}/playback/items/${mediaItemId}`);
  }

  /** 分享页播放器的分集清单 */
  /** `GET /share/{slug}/playback/items/{media_item_id}/episodes` */
  sharePlaybackItemEpisodes(mediaItemId: number, slug: string, seasonNumber: number): Promise<SeasonEpisodesView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'season_number', value: seasonNumber });
    return this.client.get<SeasonEpisodesView>(`/share/${slug}/playback/items/${mediaItemId}/episodes` + ApiQuery.build(pairs));
  }

  /** 分享页播放心跳（只刷新活动页的实时会话，不落任何观看状态） */
  /** `POST /share/{slug}/playback/progress` */
  sharePlaybackProgress(slug: string, body: PlaybackProgressRequest): Promise<PlaybackStateView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PlaybackStateView>(`/share/${slug}/playback/progress`, bodyText);
  }

  /** 分享页开始播放 */
  /** `POST /share/{slug}/playback/sessions` */
  sharePlaybackSessionStart(slug: string, body: PlaybackSessionRequest): Promise<PlaybackSessionView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PlaybackSessionView>(`/share/${slug}/playback/sessions`, bodyText);
  }

  /** 分享页结束播放 */
  /** `DELETE /share/{slug}/playback/sessions/{session_id}` */
  sharePlaybackSessionStop(sessionId: string, slug: string): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/share/${slug}/playback/sessions/${sessionId}`, null);
  }

  /** 分享页播放会话诊断 */
  /** `GET /share/{slug}/playback/sessions/{session_id}/diagnostics` */
  sharePlaybackSessionDiagnostics(sessionId: string, slug: string, token: string): Promise<PlaybackDiagnosticsView> {
    const pairs: QueryPair[] = [];
    pairs.push({ key: 'token', value: token });
    return this.client.get<PlaybackDiagnosticsView>(`/share/${slug}/playback/sessions/${sessionId}/diagnostics` + ApiQuery.build(pairs));
  }

  /** 分享页播放心跳 */
  /** `POST /share/{slug}/playback/sessions/{session_id}/ping` */
  sharePlaybackSessionPing(sessionId: string, slug: string): Promise<Record<string, JsonValue>> {
    return this.client.post<Record<string, JsonValue>>(`/share/${slug}/playback/sessions/${sessionId}/ping`, null);
  }

  /** 输入分享密码，解锁本浏览器 */
  /** `POST /share/{slug}/unlock` */
  shareUnlock(slug: string, body: ShareUnlockRequest): Promise<SharePublicView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SharePublicView>(`/share/${slug}/unlock`, bodyText);
  }

  /** 列出当前所有还有效的分享链接 */
  /** `GET /shares` */
  sharesList(): Promise<ShareView[]> {
    return this.client.get<ShareView[]>('/shares');
  }

  /** 按 id 取消一条分享，链接立刻失效 */
  /** `DELETE /shares/{share_id}` */
  sharesRevoke(shareId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/shares/${shareId}`, null);
  }

  /** 列出用户已配置的站点及验证状态 */
  /** `GET /sites` */
  siteList(): Promise<ConfiguredSite[]> {
    return this.client.get<ConfiguredSite[]>('/sites');
  }

  /** 配置一个站点（保存后异步验证） */
  /** `POST /sites` */
  siteAdd(body: SiteConfigCreate): Promise<ConfiguredSite> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<ConfiguredSite>('/sites', bodyText);
  }

  /** 刷流在池种子概况（按站点，含能否立即清理） */
  /** `GET /sites/boost-pool` */
  siteBoostPoolShow(): Promise<BoostPoolView> {
    return this.client.get<BoostPoolView>('/sites/boost-pool');
  }

  /** 清理残留的刷流种子（连数据删除） */
  /** `POST /sites/boost-pool/cleanup` */
  siteBoostPoolCleanup(body: BoostCleanupRequest): Promise<BoostCleanupResult> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<BoostCleanupResult>('/sites/boost-pool/cleanup', bodyText);
  }

  /** 各站点的刷流运行统计 */
  /** `GET /sites/boost-stats` */
  siteBoostStats(): Promise<Record<string, SiteBoostStatsView>> {
    return this.client.get<Record<string, SiteBoostStatsView>>('/sites/boost-stats');
  }

  /** 列出系统支持的可配置站点及授权要求 */
  /** `GET /sites/catalog` */
  siteCatalog(): Promise<CatalogItem[]> {
    return this.client.get<CatalogItem[]>('/sites/catalog');
  }

  /** 各站点的种子缓存量与同步节奏 */
  /** `GET /sites/sync-stats` */
  siteStats(): Promise<Record<string, SiteSyncStatsView>> {
    return this.client.get<Record<string, SiteSyncStatsView>>('/sites/sync-stats');
  }

  /** 删除站点配置（连带清理 cookie 缓存） */
  /** `DELETE /sites/{site_id}` */
  siteDelete(siteId: string): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/sites/${siteId}`, null);
  }

  /** 获取单个已配置站点详情 */
  /** `GET /sites/{site_id}` */
  siteShow(siteId: string): Promise<ConfiguredSite> {
    return this.client.get<ConfiguredSite>(`/sites/${siteId}`);
  }

  /** 更新站点授权信息（更新后重新异步验证） */
  /** `PUT /sites/{site_id}` */
  siteUpdate(siteId: string, body: SiteConfigUpdate): Promise<ConfiguredSite> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<ConfiguredSite>(`/sites/${siteId}`, bodyText);
  }

  /** 打开 / 关闭站点保护 */
  /** `PATCH /sites/{site_id}/protection` */
  siteProtectionSet(siteId: string, body: SiteProtectionUpdate): Promise<ConfiguredSite> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<ConfiguredSite>(`/sites/${siteId}/protection`, bodyText);
  }

  /** 设置自动刷分享率（开关与存储预算） */
  /** `PATCH /sites/{site_id}/ratio-boost` */
  siteRatioBoostSet(siteId: string, body: SiteRatioBoostUpdate): Promise<ConfiguredSite> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<ConfiguredSite>(`/sites/${siteId}/ratio-boost`, bodyText);
  }

  /** 暂停 / 恢复站点刷流 */
  /** `PATCH /sites/{site_id}/ratio-boost/pause` */
  siteRatioBoostPause(siteId: string, body: SiteBoostPauseUpdate): Promise<ConfiguredSite> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<ConfiguredSite>(`/sites/${siteId}/ratio-boost/pause`, bodyText);
  }

  /** 启用 / 停用站点 */
  /** `PATCH /sites/{site_id}/status` */
  siteStatusSet(siteId: string, body: SiteStatusUpdate): Promise<ConfiguredSite> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<ConfiguredSite>(`/sites/${siteId}/status`, bodyText);
  }

  /** 手动重新触发验证 */
  /** `POST /sites/{site_id}/verify` */
  siteVerify(siteId: string): Promise<ConfiguredSite> {
    return this.client.post<ConfiguredSite>(`/sites/${siteId}/verify`, null);
  }

  /** 列出可显式调用的 Agent 技能 */
  /** `GET /skills` */
  skillsList(): Promise<SkillView[]> {
    return this.client.get<SkillView[]>('/skills');
  }

  /** 列出当前账号可见的电影和剧集订阅 */
  /** `GET /subscriptions` */
  subscriptionsList(kind?: string): Promise<SubscriptionView[]> {
    const pairs: QueryPair[] = [];
    if (kind !== undefined && kind !== null) { pairs.push({ key: 'kind', value: kind }); }
    return this.client.get<SubscriptionView[]>('/subscriptions' + ApiQuery.build(pairs));
  }

  /** 从 Discover 影视条目创建订阅并生成初始追踪工单 */
  /** `POST /subscriptions` */
  subscriptionsCreate(body: SubscriptionCreatePayload): Promise<SubscriptionCreateView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SubscriptionCreateView>('/subscriptions', bodyText);
  }

  /** 检查订阅自动搜索、下载、转移与入库链路是否就绪 */
  /** `GET /subscriptions/automation-readiness` */
  subscriptionsCheckAutomationReadiness(): Promise<PipelineHealthView> {
    return this.client.get<PipelineHealthView>('/subscriptions/automation-readiness');
  }

  /** 预览订阅资源的下载目标与自动入库路径 */
  /** `GET /subscriptions/download-routing-preview` */
  subscriptionsPreviewDownloadRouting(kind: string, libraryId?: number, tmdbId?: number, title?: string, year?: number): Promise<DispatchPreviewView> {
    const pairs: QueryPair[] = [];
    if (libraryId !== undefined && libraryId !== null) { pairs.push({ key: 'library_id', value: libraryId }); }
    if (tmdbId !== undefined && tmdbId !== null) { pairs.push({ key: 'tmdb_id', value: tmdbId }); }
    if (title !== undefined && title !== null) { pairs.push({ key: 'title', value: title }); }
    if (year !== undefined && year !== null) { pairs.push({ key: 'year', value: year }); }
    pairs.push({ key: 'kind', value: kind });
    return this.client.get<DispatchPreviewView>('/subscriptions/download-routing-preview' + ApiQuery.build(pairs));
  }

  /** 列出最近入库、当前账号还没看完的订阅内容 */
  /** `GET /subscriptions/recent-arrivals` */
  subscriptionsListRecentArrivals(days?: number, limit?: number): Promise<RecentArrivalView[]> {
    const pairs: QueryPair[] = [];
    if (days !== undefined && days !== null) { pairs.push({ key: 'days', value: days }); }
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    return this.client.get<RecentArrivalView[]>('/subscriptions/recent-arrivals' + ApiQuery.build(pairs));
  }

  /** 预览订阅目标的季集、库存和现有订阅状态 */
  /** `POST /subscriptions/title-preview` */
  uiSubscriptionsPreviewTitle(body: SubscriptionTargetPreviewPayload): Promise<PrepareView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<PrepareView>('/subscriptions/title-preview', bodyText);
  }

  /** 列出最近一次可能入库的订阅内容 */
  /** `GET /subscriptions/today-arrivals` */
  subscriptionsListTodayArrivals(window?: string): Promise<TodayArrivalView[]> {
    const pairs: QueryPair[] = [];
    if (window !== undefined && window !== null) { pairs.push({ key: 'window', value: window }); }
    return this.client.get<TodayArrivalView[]>('/subscriptions/today-arrivals' + ApiQuery.build(pairs));
  }

  /** 管理员永久删除一条订阅及其追踪工单（默认不删除已下载内容） */
  /** `DELETE /subscriptions/{subscription_id}` */
  subscriptionsDelete(subscriptionId: number, deleteTorrents?: boolean, deleteLibraryFiles?: boolean): Promise<SubscriptionDeleteView> {
    const pairs: QueryPair[] = [];
    if (deleteTorrents !== undefined && deleteTorrents !== null) { pairs.push({ key: 'delete_torrents', value: deleteTorrents }); }
    if (deleteLibraryFiles !== undefined && deleteLibraryFiles !== null) { pairs.push({ key: 'delete_library_files', value: deleteLibraryFiles }); }
    return this.client.del<SubscriptionDeleteView>(`/subscriptions/${subscriptionId}` + ApiQuery.build(pairs), null);
  }

  /** 获取一条订阅的设置、进度和缺失资源明细 */
  /** `GET /subscriptions/{subscription_id}` */
  subscriptionsGet(subscriptionId: number): Promise<SubscriptionDetailView> {
    return this.client.get<SubscriptionDetailView>(`/subscriptions/${subscriptionId}`);
  }

  /** 修改订阅的选季、自动续订、过滤规则或目标媒体库 */
  /** `PATCH /subscriptions/{subscription_id}` */
  subscriptionsUpdate(subscriptionId: number, body: SubscriptionUpdatePayload): Promise<SubscriptionDetailView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<SubscriptionDetailView>(`/subscriptions/${subscriptionId}`, bodyText);
  }

  /** 列出一条订阅当前正在进行的下载及实时进度 */
  /** `GET /subscriptions/{subscription_id}/active-downloads` */
  subscriptionsListActiveDownloads(subscriptionId: number): Promise<SubscriptionDownloadView[]> {
    return this.client.get<SubscriptionDownloadView[]>(`/subscriptions/${subscriptionId}/active-downloads`);
  }

  /** 按时间倒序列出一条订阅的活动记录 */
  /** `GET /subscriptions/{subscription_id}/activities` */
  subscriptionsListActivities(subscriptionId: number, limit?: number): Promise<ActivityView[]> {
    const pairs: QueryPair[] = [];
    if (limit !== undefined && limit !== null) { pairs.push({ key: 'limit', value: limit }); }
    return this.client.get<ActivityView[]>(`/subscriptions/${subscriptionId}/activities` + ApiQuery.build(pairs));
  }

  /** 开启或关闭一条剧集订阅的自动续订 */
  /** `PATCH /subscriptions/{subscription_id}/follow-future` */
  subscriptionsSetFollowFuture(subscriptionId: number, body: SubscriptionFollowFuturePayload): Promise<SubscriptionDetailView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.patch<SubscriptionDetailView>(`/subscriptions/${subscriptionId}/follow-future`, bodyText);
  }

  /** `PATCH /subscriptions/{subscription_id}/tracking-state`：暂停 / 恢复追踪（state = active | paused） */
  subscriptionsSetTrackingState(subscriptionId: number, body: SubscriptionTrackingStatePayload): Promise<SubscriptionDetailView> {
    return this.client.patch<SubscriptionDetailView>('/subscriptions/' + subscriptionId + '/tracking-state',
      JSON.stringify(body));
  }

  /** 成员停止关注一条订阅而不影响其他正在追踪的成员 */
  /** `DELETE /subscriptions/{subscription_id}/following` */
  subscriptionsUnsubscribe(subscriptionId: number): Promise<Record<string, JsonValue>> {
    return this.client.del<Record<string, JsonValue>>(`/subscriptions/${subscriptionId}/following`, null);
  }

  /** 立即为一条订阅搜索目前缺失且已经可搜索的资源 */
  /** `POST /subscriptions/{subscription_id}/missing-resource-searches` */
  subscriptionsSearchMissingResources(subscriptionId: number): Promise<SearchNowView> {
    return this.client.post<SearchNowView>(`/subscriptions/${subscriptionId}/missing-resource-searches`, null);
  }

  /** 取消订阅前预览可一并清理的种子与媒体库文件 */
  /** `GET /subscriptions/{subscription_id}/removal-preview` */
  subscriptionsPreviewRemoval(subscriptionId: number, seasons?: number[]): Promise<SubscriptionRemovalPreviewView> {
    const pairs: QueryPair[] = [];
    if (seasons !== undefined && seasons !== null) {
      for (const item of seasons) { pairs.push({ key: 'seasons', value: item }); }
    }
    return this.client.get<SubscriptionRemovalPreviewView>(`/subscriptions/${subscriptionId}/removal-preview` + ApiQuery.build(pairs));
  }

  /** 清理已移出订阅范围的那几季的种子与媒体库文件 */
  /** `POST /subscriptions/{subscription_id}/season-cleanup` */
  subscriptionsCleanupSeasons(subscriptionId: number, body: SeasonCleanupPayload): Promise<SubscriptionDeleteView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<SubscriptionDeleteView>(`/subscriptions/${subscriptionId}/season-cleanup`, bodyText);
  }

  /** 下载为一条订阅人工选中的种子搜索结果 */
  /** `POST /subscriptions/{subscription_id}/selected-torrent-downloads` */
  subscriptionsDownloadSelectedTorrent(subscriptionId: number, body: GrabPayload): Promise<GrabResultView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<GrabResultView>(`/subscriptions/${subscriptionId}/selected-torrent-downloads`, bodyText);
  }

  /** 把一条订阅的追踪状态明确设置为 active 或 paused */
  
  /** 触发一轮洗版：逐集体检并把可洗单元排入立即搜索 */
  /** `POST /subscriptions/{subscription_id}/upgrade-runs` */
  subscriptionsUpgradeRun(subscriptionId: number, body: UpgradeRunPayload): Promise<UpgradeRunView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.post<UpgradeRunView>(`/subscriptions/${subscriptionId}/upgrade-runs`, bodyText);
  }

  /** 列出可查看的日志日期 */
  /** `GET /system/logs` */
  logsDays(): Promise<LogDayList> {
    return this.client.get<LogDayList>('/system/logs');
  }

  /** 读取某天的日志内容 */
  /** `GET /system/logs/{day}` */
  logsRead(day: string, tail?: number): Promise<LogContent> {
    const pairs: QueryPair[] = [];
    if (tail !== undefined && tail !== null) { pairs.push({ key: 'tail', value: tail }); }
    return this.client.get<LogContent>(`/system/logs/${day}` + ApiQuery.build(pairs));
  }

  /** 列出全部活跃的待处理事项（error 在前，新的在前） */
  /** `GET /system/notices` */
  noticesList(): Promise<NoticeView[]> {
    return this.client.get<NoticeView[]>('/system/notices');
  }

  /** 忽略一条待处理事项（问题仍在也不再提示；自动消退不受影响） */
  /** `POST /system/notices/{notice_id}/dismiss` */
  noticesDismiss(noticeId: number): Promise<void> {
    return this.client.postVoid(`/system/notices/${noticeId}/dismiss`, null);
  }

  /** 读取远程转码配置 */
  /** `GET /transcode-worker/config` */
  transcodeConfigShow(): Promise<RemoteTranscodeConfigView> {
    return this.client.get<RemoteTranscodeConfigView>('/transcode-worker/config');
  }

  /** 保存远程转码配置 */
  /** `PUT /transcode-worker/config` */
  transcodeConfigSet(body: RemoteTranscodeConfigPayload): Promise<RemoteTranscodeConfigView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<RemoteTranscodeConfigView>('/transcode-worker/config', bodyText);
  }

  /** 远程转码 Worker 状态 */
  /** `GET /transcode-worker/status` */
  transcodeStatus(): Promise<Record<string, JsonValue>> {
    return this.client.get<Record<string, JsonValue>>('/transcode-worker/status');
  }

  /** 发现页展示编排（分区引用与呈现方式） */
  /** `GET /ui/discovery/{media_type}` */
  uiDiscoveryGet(mediaType: MediaKind, provider?: MediaSource): Promise<DiscoveryPageView> {
    const pairs: QueryPair[] = [];
    if (provider !== undefined && provider !== null) { pairs.push({ key: 'provider', value: provider }); }
    return this.client.get<DiscoveryPageView>(`/ui/discovery/${mediaType}` + ApiQuery.build(pairs));
  }

  /** 读取界面偏好（按页面分组的样式设定） */
  /** `GET /ui/preferences` */
  uiPrefsShow(): Promise<UiPreferencesSetting> {
    return this.client.get<UiPreferencesSetting>('/ui/preferences');
  }

  /** 保存界面偏好（整体覆盖） */
  /** `PUT /ui/preferences` */
  uiPrefsUpdate(body: UiPreferencesSettingInput): Promise<UiPreferencesSetting> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<UiPreferencesSetting>('/ui/preferences', bodyText);
  }

  /** 读取 Webhook 配置与事件目录 */
  /** `GET /webhook` */
  webhookShow(): Promise<WebhookConfigView> {
    return this.client.get<WebhookConfigView>('/webhook');
  }

  /** 保存 Webhook 配置（新建 endpoint 的 secret 仅本次返回明文） */
  /** `PUT /webhook` */
  webhookSet(body: WebhookConfigPayload): Promise<WebhookConfigView> {
    const bodyText = (body === undefined || body === null) ? null : JSON.stringify(body);
    return this.client.put<WebhookConfigView>('/webhook', bodyText);
  }

  /** 最近投递记录（每端点保留 50 条，重启清空） */
  /** `GET /webhook/endpoints/{endpoint_id}/deliveries` */
  webhookDeliveries(endpointId: string): Promise<DeliveryView[]> {
    return this.client.get<DeliveryView[]>(`/webhook/endpoints/${endpointId}/deliveries`);
  }

  /** 轮换签名密钥（旧密钥即刻作废，新明文仅本次返回） */
  /** `POST /webhook/endpoints/{endpoint_id}/rotate-secret` */
  webhookRotateSecret(endpointId: string): Promise<WebhookEndpointView> {
    return this.client.post<WebhookEndpointView>(`/webhook/endpoints/${endpointId}/rotate-secret`, null);
  }

  /** 发送测试事件（同步返回状态码/耗时/错误） */
  /** `POST /webhook/endpoints/{endpoint_id}/test` */
  webhookTest(endpointId: string): Promise<DeliveryView> {
    return this.client.post<DeliveryView>(`/webhook/endpoints/${endpointId}/test`, null);
  }
}