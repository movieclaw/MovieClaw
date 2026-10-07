"use client";

/**
 * 设置 -> 成员：成员账号、能力与资源范围的唯一管理入口。
 *
 * 列表只负责扫描状态，创建和编辑使用独立弹窗，避免在表格中展开长表单导致
 * 行高跳变。创建/重置产生的明文密码进入一次性结果弹窗，关闭后前端也不再
 * 保留，和后端“仅返回一次”的凭据语义一致。
 */

import { useCallback, useEffect, useState } from "react";

import { AvatarBadge } from "@/components/avatar-badge";
import { BrandLoader } from "@/components/brand-loader";
import { copyText } from "@/components/copy-button";
import { useConfirm, useToast } from "@/components/feedback";
import { CheckIcon, PlusIcon } from "@/components/icons";
import { Modal } from "@/components/modal";
import {
  SETTINGS_BUTTON_CLASS,
  SETTINGS_INPUT_CLASS,
  SETTINGS_PRIMARY_BUTTON_CLASS,
  SettingsEmpty,
  SettingsMoreMenu,
  SettingsSection,
} from "@/components/settings-ui";
import { listLibraries, type MediaLibrary } from "@/lib/api/libraries";
import {
  createMember,
  deleteMember,
  listMembers,
  resetMemberPassword,
  setMemberStatus,
  signOutMember,
  updateMember,
  type MemberUpdatePayload,
  type MemberView,
} from "@/lib/api/members";
import { listSiteCatalog, type CatalogItem } from "@/lib/api/sites";
import { formatRelativeTime } from "@/lib/time";

interface PasswordResult {
  title: string;
  username: string;
  password: string;
}

/** 生成随机初始密码（前端生成，创建前即可复制；后端只保存哈希）。 */
function generatePassword(): string {
  const alphabet = "abcdefghjkmnpqrstuvwxyzACDEFGHJKLMNPQRSTUVWXYZ2345679";
  const bytes = crypto.getRandomValues(new Uint8Array(14));
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join("");
}

export function MembersSection() {
  const toast = useToast();
  const confirm = useConfirm();
  const [members, setMembers] = useState<MemberView[] | null>(null);
  const [libraries, setLibraries] = useState<MediaLibrary[]>([]);
  const [sites, setSites] = useState<CatalogItem[]>([]);
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState<MemberView | null>(null);
  const [passwordResult, setPasswordResult] = useState<PasswordResult | null>(null);

  const reload = useCallback(async () => setMembers(await listMembers()), []);

  useEffect(() => {
    void reload().catch((error) => toast.error(`加载成员失败：${(error as Error).message}`));
    void listLibraries().then(setLibraries).catch(() => {});
    void listSiteCatalog().then(setSites).catch(() => {});
  }, [reload, toast]);

  const replaceMember = (next: MemberView) => {
    setMembers((rows) => rows?.map((row) => (row.id === next.id ? next : row)) ?? rows);
    setEditing((current) => (current?.id === next.id ? next : current));
  };

  const resetPassword = async (member: MemberView) => {
    const accepted = await confirm({
      title: `重置「${member.nickname}」的密码？`,
      // 重置多半是忘了密码：密码换来的登录下线，配对的命令行保留
      // （docs/design/login-devices.md「失效联动」），要一并收回走「全部下线」
      description:
        "旧密码立即失效，该成员在网页、App 和播放器上的登录会全部下线；命令行不受影响，要一并收回请用「全部下线」。新密码只显示一次。",
      confirmLabel: "重置密码",
    });
    if (!accepted) return;
    try {
      const result = await resetMemberPassword(member.id);
      setPasswordResult({
        title: "密码已重置",
        username: result.username,
        password: result.password,
      });
      // 重置接口不回成员视图，设备数变了得重拉一次
      void reload().catch(() => undefined);
    } catch (error) {
      toast.error(`重置失败：${(error as Error).message}`);
    }
  };

  /** 全部下线：借出去的账号要收回、设备丢了——账号本身不动，重新登录即可。 */
  const signOutEverywhere = async (member: MemberView) => {
    const accepted = await confirm({
      title: `让「${member.nickname}」在全部设备上下线？`,
      description:
        "该成员的网页、App、命令行、播放器都会立即下线，账号本身不受影响，之后用密码重新登录即可。",
      confirmLabel: "全部下线",
      tone: "danger",
    });
    if (!accepted) return;
    try {
      const { member: next, message } = await signOutMember(member.id);
      replaceMember(next);
      toast.success(message);
    } catch (error) {
      toast.error(`操作失败：${(error as Error).message}`);
    }
  };

  const toggleStatus = async (member: MemberView) => {
    const enabling = member.status !== "active";
    if (!enabling) {
      const accepted = await confirm({
        title: `停用「${member.nickname}」？`,
        description: "该成员的全部设备会立即下线，个人数据和订阅保留，可随时重新启用。",
        confirmLabel: "停用成员",
        tone: "danger",
      });
      if (!accepted) return;
    }
    try {
      replaceMember(await setMemberStatus(member.id, enabling));
      toast.success(enabling ? "成员已启用" : "成员已停用");
    } catch (error) {
      toast.error(`操作失败：${(error as Error).message}`);
    }
  };

  const removeMember = async (member: MemberView) => {
    const accepted = await confirm({
      title: `删除成员「${member.nickname}」？`,
      description:
        "头像、播放进度等个人数据会被清理；订阅转由管理员接管，已下载内容不受影响。此操作不可恢复。",
      confirmLabel: "删除成员",
      tone: "danger",
    });
    if (!accepted) return;
    try {
      await deleteMember(member.id);
      setMembers((rows) => rows?.filter((row) => row.id !== member.id) ?? rows);
      setEditing(null);
      toast.success("成员已删除");
    } catch (error) {
      toast.error(`删除失败：${(error as Error).message}`);
    }
  };

  return (
    <SettingsSection
      title="成员账号"
      description={
        members && members.length > 0
          ? `${members.length} 位成员 · 管理登录状态、功能权限和可见媒体库`
          : "管理登录状态、功能权限和可见媒体库"
      }
      action={
        <button
          type="button"
          onClick={() => setCreating(true)}
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1`}
        >
          <PlusIcon className="size-4" />
          添加成员
        </button>
      }
    >
      {members !== null && members.length === 0 ? (
        <SettingsEmpty
          title="还没有成员账号"
          description="添加后即可分别控制订阅、搜索和媒体库可见范围。"
        />
      ) : (
        <div className="css-glass overflow-hidden !rounded-xl">
          <div className="grid grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)_minmax(0,.8fr)_minmax(88px,130px)_36px] gap-4 border-b border-[var(--line)] px-4 py-2.5 text-caption font-medium text-[var(--text-faint)] max-md:hidden">
            <span>成员</span>
            <span>功能权限</span>
            <span>媒体库范围</span>
            <span>最近活动</span>
            <span className="sr-only">操作</span>
          </div>
          {members === null ? (
            <div className="flex items-center justify-center gap-2 px-5 py-10 text-ui text-[var(--text-muted)]">
              <BrandLoader className="size-5" />
              正在加载成员…
            </div>
          ) : (
            <div className="divide-y divide-[var(--line)]">
              {members.map((member) => (
                <MemberTableRow
                  key={member.id}
                  member={member}
                  libraries={libraries}
                  onEdit={() => setEditing(member)}
                  onResetPassword={() => void resetPassword(member)}
                  onSignOut={() => void signOutEverywhere(member)}
                  onToggleStatus={() => void toggleStatus(member)}
                  onDelete={() => void removeMember(member)}
                />
              ))}
            </div>
          )}
        </div>
      )}

      <CreateMemberDialog
        open={creating}
        onClose={() => setCreating(false)}
        onCreated={(member, password) => {
          setCreating(false);
          setMembers((rows) => (rows ? [...rows, member] : [member]));
          setPasswordResult({ title: "成员已创建", username: member.username, password });
        }}
      />

      {editing && (
        <EditMemberDialog
          key={editing.id}
          member={editing}
          libraries={libraries}
          sites={sites}
          onClose={() => setEditing(null)}
          onSaved={(next) => {
            replaceMember(next);
            setEditing(null);
            toast.success("成员设置已保存");
          }}
        />
      )}

      <PasswordResultDialog result={passwordResult} onClose={() => setPasswordResult(null)} />
    </SettingsSection>
  );
}

function MemberTableRow({
  member,
  libraries,
  onEdit,
  onResetPassword,
  onSignOut,
  onToggleStatus,
  onDelete,
}: {
  member: MemberView;
  libraries: MediaLibrary[];
  onEdit: () => void;
  onResetPassword: () => void;
  onSignOut: () => void;
  onToggleStatus: () => void;
  onDelete: () => void;
}) {
  const permissionLabels = [
    member.allow_subscribe ? "订阅" : null,
    member.allow_search ? "资源搜索" : null,
    member.allow_direct_download ? "下载" : null,
    // 分级上限直接摆在摘要里：这是"这个号是给谁用的"最要紧的一条信息
    member.content_age_limit !== null ? `${member.content_age_limit}+ 以下` : null,
  ].filter(Boolean);
  const visibleNames = libraries
    .filter((library) => member.library_ids.includes(library.id))
    .map((library) => library.name);
  // 「全部库」只自动包含对所有成员开放的库；「指定成员」的库要单独勾选，
  // 摘要里把勾了的单独列出来（docs/design/library-access.md 2.2）
  const grantedSelected = libraries
    .filter(
      (library) => library.access_mode === "selected" && member.library_ids.includes(library.id),
    )
    .map((library) => library.name);
  const libraryScope = member.all_libraries
    ? grantedSelected.length > 0
      ? `全部共享库 + 指定成员的库：${grantedSelected.join("、")}`
      : "全部共享库"
    : visibleNames.length > 0
      ? visibleNames.join("、")
      : "未分配媒体库";

  return (
    <div className="grid grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)_minmax(0,.8fr)_minmax(88px,130px)_36px] items-center gap-4 px-4 py-3.5 transition-colors hover:bg-white/[0.025] max-md:grid-cols-[minmax(0,1fr)_36px] max-md:gap-x-3 max-md:gap-y-2.5">
      <div className="flex min-w-0 items-center gap-3">
        <AvatarBadge nickname={member.nickname} avatarUrl={member.avatar_url} className="size-9" />
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="truncate text-ui font-semibold text-[var(--text)]">
              {member.nickname}
            </span>
            <span
              className={`size-1.5 shrink-0 rounded-full ${member.status === "active" ? "bg-[var(--ok)]" : "bg-white/25"}`}
              title={member.status === "active" ? "已启用" : "已停用"}
            />
          </div>
          <p className="truncate text-caption text-[var(--text-faint)]">@{member.username}</p>
        </div>
      </div>
      <div className="flex min-w-0 flex-wrap gap-1.5 max-md:col-start-1">
        {permissionLabels.length > 0 ? (
          permissionLabels.map((label) => <Badge key={label}>{label}</Badge>)
        ) : (
          <span className="text-caption text-[var(--text-faint)]">仅浏览与播放</span>
        )}
      </div>
      {/* min-w-0：网格子项默认 min-width:auto，会把整行撑到内容宽度、把最右的
          ⋯ 列挤出 overflow-hidden 的容器外——PC 上窄一点的设置面板就看不到菜单 */}
      <p className="min-w-0 truncate text-sub text-[var(--text-muted)] max-md:col-start-1" title={libraryScope}>
        {libraryScope}
      </p>
      <div className="min-w-0 max-md:col-start-1">
        <p className="truncate text-caption text-[var(--text-faint)]">
          {member.last_login_at ? formatRelativeTime(member.last_login_at) : "从未登录"}
        </p>
        {/* 网页、App、命令行、播放器合计；要逐台看在「设备」的「全部成员」视图里 */}
        <p className="truncate text-caption text-[var(--text-faint)]">
          {member.device_count > 0 ? `${member.device_count} 台设备登录中` : "无登录中的设备"}
        </p>
      </div>
      <MemberActionsMenu
        member={member}
        onEdit={onEdit}
        onResetPassword={onResetPassword}
        onSignOut={onSignOut}
        onToggleStatus={onToggleStatus}
        onDelete={onDelete}
      />
    </div>
  );
}

function MemberActionsMenu({
  member,
  onEdit,
  onResetPassword,
  onSignOut,
  onToggleStatus,
  onDelete,
}: {
  member: MemberView;
  onEdit: () => void;
  onResetPassword: () => void;
  onSignOut: () => void;
  onToggleStatus: () => void;
  onDelete: () => void;
}) {
  return (
    // 手机上 ⋯ 挪到首行右侧（网格定位留在外层，菜单本身用统一组件）
    <div className="max-md:col-start-2 max-md:row-start-1">
      <SettingsMoreMenu
        label={`${member.nickname} 的更多操作`}
        items={[
          { label: "编辑成员", onSelect: onEdit },
          { label: "重置密码", onSelect: onResetPassword },
          // 停用的成员设备早已全部注销，这一项对他没有意义
          ...(member.status === "active" ? [{ label: "全部下线", onSelect: onSignOut }] : []),
          {
            label: member.status === "active" ? "停用成员" : "启用成员",
            onSelect: onToggleStatus,
            warn: member.status === "active",
          },
          { label: "删除成员", onSelect: onDelete, danger: true },
        ]}
      />
    </div>
  );
}

function CreateMemberDialog({
  open,
  onClose,
  onCreated,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: (member: MemberView, password: string) => void;
}) {
  const toast = useToast();
  const [username, setUsername] = useState("");
  const [nickname, setNickname] = useState("");
  const [password, setPassword] = useState(() => generatePassword());
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!open) return;
    setUsername("");
    setNickname("");
    setPassword(generatePassword());
    setBusy(false);
  }, [open]);

  const submit = async () => {
    if (username.trim().length < 3) return toast.error("用户名至少 3 个字符");
    if (password.length < 8) return toast.error("密码至少 8 位");
    setBusy(true);
    try {
      const member = await createMember(username.trim(), password, nickname.trim());
      onCreated(member, password);
    } catch (error) {
      toast.error(`创建失败：${(error as Error).message}`);
      setBusy(false);
    }
  };

  return (
    <Modal open={open} onClose={onClose} label="添加成员" width="lg">
      <div className="p-6 max-md:p-5">
        <h2 className="text-title font-bold text-white">添加成员</h2>
        <p className="mt-1 text-sub text-[var(--text-muted)]">
          新成员默认可以订阅和浏览全部媒体库，资源搜索默认关闭。
        </p>

        <div className="mt-5 grid grid-cols-2 gap-4 max-md:grid-cols-1">
          <Field label="用户名" hint="登录使用，创建后不可修改">
            <input
              value={username}
              onChange={(event) => setUsername(event.target.value)}
              autoFocus
              autoComplete="off"
              placeholder="如 yee"
              className={INPUT_CLASS}
            />
          </Field>
          <Field label="昵称" hint="页面展示名，可留空">
            <input
              value={nickname}
              onChange={(event) => setNickname(event.target.value)}
              placeholder="如 小叶"
              className={INPUT_CLASS}
            />
          </Field>
        </div>
        <div className="mt-4">
          <SectionTitle
            title="初始密码"
            description="已随机生成。点击密码行即可复制，创建成功后还会显示一次。"
          />
          <div className="overflow-hidden rounded-xl border border-white/[0.08] bg-black/20">
            <CredentialRow label="密码" value={password} mono />
            <button
              type="button"
              onClick={() => setPassword(generatePassword())}
              className="flex w-full items-center justify-between border-t border-white/[0.08] bg-white/[0.035] px-4 py-3 text-left text-sub font-medium text-white/85 transition-colors hover:bg-white/[0.07]"
            >
              重新生成密码
              <span className="text-caption text-[var(--text-faint)]">换一个随机密码</span>
            </button>
          </div>
        </div>

        <div className="mt-6 flex justify-end gap-3">
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            取消
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={() => void submit()}
            className={SETTINGS_PRIMARY_BUTTON_CLASS}
          >
            {busy ? "创建中…" : "创建成员"}
          </button>
        </div>
      </div>
    </Modal>
  );
}

function EditMemberDialog({
  member,
  libraries,
  sites,
  onClose,
  onSaved,
}: {
  member: MemberView;
  libraries: MediaLibrary[];
  sites: CatalogItem[];
  onClose: () => void;
  onSaved: (member: MemberView) => void;
}) {
  const toast = useToast();
  const [nickname, setNickname] = useState(member.nickname);
  const [allowSubscribe, setAllowSubscribe] = useState(member.allow_subscribe);
  const [allowSearch, setAllowSearch] = useState(member.allow_search);
  const [allowDirectDownload, setAllowDirectDownload] = useState(member.allow_direct_download);
  const [allLibraries, setAllLibraries] = useState(member.all_libraries);
  const [libraryIds, setLibraryIds] = useState(member.library_ids);
  const [allSites, setAllSites] = useState(member.all_sites);
  const [ageLimit, setAgeLimit] = useState<number | null>(member.content_age_limit);
  const [allowUnrated, setAllowUnrated] = useState(member.allow_unrated);
  const [siteIds, setSiteIds] = useState(member.site_ids);
  const [busy, setBusy] = useState(false);

  // 「指定成员」的库：成员即使是「全部库」也要单独勾选才可见——保存时不能把
  // 这些显式授权当成白名单一起清掉
  const selectedModeIds = libraries
    .filter((library) => library.access_mode === "selected")
    .map((library) => library.id);
  const save = async () => {
    setBusy(true);
    const payload: MemberUpdatePayload = {
      nickname: nickname.trim(),
      allow_subscribe: allowSubscribe,
      allow_search: allowSearch,
      allow_direct_download: allowSearch && allowDirectDownload,
      all_libraries: allLibraries,
      library_ids: allLibraries ? libraryIds.filter((id) => selectedModeIds.includes(id)) : libraryIds,
      all_sites: allSites,
      site_ids: allSites ? [] : siteIds,
      // -1 = 取消上限。不传是「不改动」——两者在协议上必须分得开，否则
      // 老客户端每存一次设置都会把家长设好的上限悄悄抹掉
      content_age_limit: ageLimit ?? -1,
      allow_unrated: allowUnrated,
    };
    try {
      onSaved(await updateMember(member.id, payload));
    } catch (error) {
      toast.error(`保存失败：${(error as Error).message}`);
      setBusy(false);
    }
  };

  return (
    <Modal
      open
      onClose={onClose}
      label={`编辑成员 ${member.nickname}`}
      width="2xl"
      panelClassName="flex max-h-[82dvh] flex-col"
    >
      <div className="scroll-thin overflow-y-auto p-6 max-md:p-5">
        <div className="flex items-center gap-3">
          <AvatarBadge nickname={member.nickname} avatarUrl={member.avatar_url} className="size-11" />
          <div className="min-w-0">
            <h2 className="truncate text-title font-bold text-white">编辑成员</h2>
            <p className="truncate text-sub text-[var(--text-muted)]">@{member.username}</p>
          </div>
          <StatusBadge status={member.status} />
        </div>

        <div className="mt-6 border-t border-white/[0.07] pt-5">
          <SectionTitle title="基本信息" />
          <Field label="昵称">
            <input value={nickname} onChange={(event) => setNickname(event.target.value)} className={INPUT_CLASS} />
          </Field>
        </div>

        <div className="mt-6 border-t border-white/[0.07] pt-5">
          <SectionTitle title="功能权限" description="关闭后相关入口会从成员页面隐藏，后端同时拒绝调用。" />
          <div className="divide-y divide-white/[0.055]">
            <PermissionToggle
              label="订阅追踪"
              description="发起订阅并管理自己的订阅"
              checked={allowSubscribe}
              onChange={setAllowSubscribe}
            />
            <PermissionToggle
              label="资源搜索"
              description="在被分配的 PT 站点里搜索种子资源（媒体库内搜索不受此开关影响）"
              checked={allowSearch}
              onChange={(checked) => {
                setAllowSearch(checked);
                if (!checked) setAllowDirectDownload(false);
              }}
            />
            <PermissionToggle
              label="一键下载"
              description="从搜索结果直接提交下载，依赖资源搜索"
              checked={allowDirectDownload}
              disabled={!allowSearch}
              onChange={setAllowDirectDownload}
            />
          </div>
        </div>

        <div className="mt-6 border-t border-white/[0.07] pt-5">
          <SectionTitle
            title="内容分级"
            description="给孩子用的档案设一个年龄上限：超过这个分级的作品在海报墙、搜索、合集、播放器和详情页都看不到，直接改地址栏也进不去。"
          />
          <div className="flex flex-wrap gap-1.5">
            {AGE_LIMITS.map((option) => (
              <button
                key={option.value ?? "none"}
                type="button"
                onClick={() => setAgeLimit(option.value)}
                className={`h-8 rounded-lg px-3 text-ui transition ${
                  ageLimit === option.value
                    ? "bg-white/[0.16] text-white"
                    : "bg-white/[0.05] text-white/70 hover:bg-white/[0.10] hover:text-white"
                }`}
              >
                {option.label}
              </button>
            ))}
          </div>
          {ageLimit !== null && (
            <div className="mt-3 divide-y divide-white/[0.055]">
              <PermissionToggle
                label="未分级的作品也给看"
                description="大量中文影片在 TMDB 上没有分级信息。默认一并隐藏——「我不确定的一律不给看」更稳妥；打开之后这些片会出现在这个成员面前。"
                checked={allowUnrated}
                onChange={setAllowUnrated}
              />
            </div>
          )}
        </div>

        <div className="mt-6 border-t border-white/[0.07] pt-5">
          <SectionTitle
            title="媒体库范围"
            description="「全部媒体库」自动包含对所有成员开放的库，含以后新建的；「指定成员」的库需要单独勾选。"
          />
          <AccessPicker
            allSelected={allLibraries}
            allLabel="全部媒体库"
            limitedLabel="指定媒体库"
            options={libraries.map((library) => ({
              id: library.id,
              label: library.access_mode === "selected" ? `${library.name} · 指定成员` : library.name,
            }))}
            selected={libraryIds}
            onModeChange={setAllLibraries}
            onSelectedChange={setLibraryIds}
          />
          {allLibraries && selectedModeIds.length > 0 && (
            <div className="mt-3">
              <p className="text-caption text-[var(--text-faint)]">指定成员的库（需单独勾选）</p>
              <div className="mt-2 flex flex-wrap gap-2">
                {libraries
                  .filter((library) => library.access_mode === "selected")
                  .map((library) => {
                    const on = libraryIds.includes(library.id);
                    return (
                      <button
                        key={library.id}
                        type="button"
                        onClick={() =>
                          setLibraryIds(
                            on ? libraryIds.filter((id) => id !== library.id) : [...libraryIds, library.id],
                          )
                        }
                        className={`rounded-lg border px-3 py-1.5 text-sub font-medium transition-colors ${
                          on
                            ? "border-[var(--accent)]/50 bg-[var(--accent-soft)] text-[var(--accent)]"
                            : "border-white/[0.09] bg-white/[0.035] text-[var(--text-muted)] hover:text-[var(--text)]"
                        }`}
                      >
                        {library.name}
                      </button>
                    );
                  })}
              </div>
            </div>
          )}
        </div>

        {allowSearch && (
          <div className="mt-6 border-t border-white/[0.07] pt-5">
            <SectionTitle title="可搜索站点" />
            <AccessPicker
              allSelected={allSites}
              allLabel="全部启用站点"
              limitedLabel="指定站点"
              options={sites.map((site) => ({ id: site.site_id, label: site.display_name }))}
              selected={siteIds}
              onModeChange={setAllSites}
              onSelectedChange={setSiteIds}
            />
          </div>
        )}

      </div>

      <div className="flex shrink-0 justify-end gap-3 border-t border-white/[0.07] px-6 py-4 max-md:px-5">
        <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
          取消
        </button>
        <button
          type="button"
          disabled={busy}
          onClick={() => void save()}
          className={`${SETTINGS_PRIMARY_BUTTON_CLASS} flex items-center gap-1.5`}
        >
          <CheckIcon className="size-4" />
          {busy ? "保存中…" : "保存设置"}
        </button>
      </div>
    </Modal>
  );
}

function PasswordResultDialog({
  result,
  onClose,
}: {
  result: PasswordResult | null;
  onClose: () => void;
}) {
  if (!result) return null;
  const credentialText = `账号：${result.username}\n密码：${result.password}`;
  return (
    <Modal open onClose={onClose} label={result.title} width="md" raised>
      <div className="p-6 max-md:p-5">
        <h2 className="text-title font-bold text-white">{result.title}</h2>
        <p className="mt-1 text-sub leading-6 text-[var(--text-muted)]">
          密码只在这里显示一次。点击账号或密码即可复制，关闭弹窗后无法再次查看。
        </p>
        <div className="mt-5 overflow-hidden rounded-xl border border-white/[0.08] bg-black/20">
          <CredentialRow label="账号" value={result.username} />
          <CredentialRow label="密码" value={result.password} mono />
          <CopySurface
            text={credentialText}
            successMessage="账号和密码已复制"
            idleLabel=""
            className="flex w-full items-center justify-between border-t border-white/[0.08] bg-white/[0.035] px-4 py-3 text-left text-sub font-medium text-white/85 transition-colors hover:bg-white/[0.07]"
          >
            复制全部登录信息
          </CopySurface>
        </div>
        <div className="mt-5 flex justify-end">
          <button type="button" onClick={onClose} className={SETTINGS_BUTTON_CLASS}>
            完成
          </button>
        </div>
      </div>
    </Modal>
  );
}

const INPUT_CLASS = `${SETTINGS_INPUT_CLASS} w-full`;

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="mt-4 block first:mt-0">
      <span className="mb-1 flex items-baseline gap-2 text-sub font-medium text-[var(--text)]">
        {label}
        {hint && <span className="font-normal text-[var(--text-faint)]">{hint}</span>}
      </span>
      {children}
    </label>
  );
}

function SectionTitle({ title, description }: { title: string; description?: string }) {
  return (
    <div className="mb-3">
      <h3 className="text-ui font-semibold text-white/90">{title}</h3>
      {description && <p className="mt-0.5 text-caption text-[var(--text-faint)]">{description}</p>}
    </div>
  );
}

/**
 * 年龄上限的档位。
 *
 * 不给用户填数字：分级体系是各国自己的一套符号（PG-13 / FSK 16 / R15+），
 * 折算成年龄已经是我们替他做的一次翻译，再让他猜"填几"只会更糊涂。
 * 这几档对着的是家里真实的年龄段。
 */
const AGE_LIMITS: { value: number | null; label: string }[] = [
  { value: null, label: "不限" },
  { value: 6, label: "6 岁以下" },
  { value: 12, label: "12 岁以下" },
  { value: 16, label: "16 岁以下" },
  { value: 18, label: "18 岁以下" },
];

function PermissionToggle({
  label,
  description,
  checked,
  disabled = false,
  onChange,
}: {
  label: string;
  description: string;
  checked: boolean;
  disabled?: boolean;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className={`flex items-center justify-between gap-5 py-3 ${disabled ? "opacity-40" : "cursor-pointer"}`}>
      <span className="min-w-0">
        <span className="block text-ui font-medium text-[var(--text)]">{label}</span>
        <span className="mt-0.5 block text-caption text-[var(--text-faint)]">{description}</span>
      </span>
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(event) => onChange(event.target.checked)}
        className="size-4 shrink-0 accent-[var(--accent)]"
      />
    </label>
  );
}

function AccessPicker<T extends string | number>({
  allSelected,
  allLabel,
  limitedLabel,
  options,
  selected,
  onModeChange,
  onSelectedChange,
}: {
  allSelected: boolean;
  allLabel: string;
  limitedLabel: string;
  options: { id: T; label: string }[];
  selected: T[];
  onModeChange: (all: boolean) => void;
  onSelectedChange: (selected: T[]) => void;
}) {
  const toggle = (id: T) =>
    onSelectedChange(selected.includes(id) ? selected.filter((value) => value !== id) : [...selected, id]);

  return (
    <div>
      <div className="inline-flex rounded-lg border border-white/[0.08] bg-white/[0.035] p-1">
        <ModeButton active={allSelected} onClick={() => onModeChange(true)}>{allLabel}</ModeButton>
        <ModeButton active={!allSelected} onClick={() => onModeChange(false)}>{limitedLabel}</ModeButton>
      </div>
      {!allSelected && (
        <div className="mt-3 flex flex-wrap gap-2">
          {options.length === 0 ? (
            <p className="text-caption text-[var(--text-faint)]">暂无可选项</p>
          ) : (
            options.map((option) => (
              <button
                key={String(option.id)}
                type="button"
                onClick={() => toggle(option.id)}
                className={`rounded-lg border px-3 py-1.5 text-sub font-medium transition-colors ${
                  selected.includes(option.id)
                    ? "border-[var(--accent)]/50 bg-[var(--accent-soft)] text-[var(--accent)]"
                    : "border-white/[0.09] bg-white/[0.035] text-[var(--text-muted)] hover:text-[var(--text)]"
                }`}
              >
                {option.label}
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}

function ModeButton({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`rounded-md px-3 py-1.5 text-sub font-medium transition-colors ${active ? "bg-white/[0.11] text-white" : "text-[var(--text-faint)] hover:text-[var(--text)]"}`}
    >
      {children}
    </button>
  );
}

function Badge({ children }: { children: React.ReactNode }) {
  return <span className="rounded-md bg-white/[0.06] px-2 py-1 text-caption text-white/70">{children}</span>;
}

function StatusBadge({ status }: { status: MemberView["status"] }) {
  return (
    <span className={`ml-auto rounded-full border px-2.5 py-1 text-caption font-medium ${status === "active" ? "border-emerald-400/25 bg-[var(--ok)]/10 text-emerald-300" : "border-white/[0.1] bg-white/[0.04] text-[var(--text-faint)]"}`}>
      {status === "active" ? "已启用" : "已停用"}
    </span>
  );
}

function CredentialRow({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <CopySurface
      text={value}
      successMessage={`${label}已复制`}
      className="flex w-full items-center gap-4 border-b border-white/[0.06] px-4 py-3 text-left transition-colors hover:bg-white/[0.045]"
    >
      <span className="w-10 shrink-0 text-caption text-[var(--text-faint)]">{label}</span>
      <span className={`min-w-0 flex-1 break-all text-ui text-white ${mono ? "font-mono" : ""}`}>
        {value}
      </span>
    </CopySurface>
  );
}

function CopySurface({
  text,
  successMessage,
  idleLabel = "点击复制",
  className,
  children,
}: {
  text: string;
  successMessage: string;
  idleLabel?: string;
  className: string;
  children: React.ReactNode;
}) {
  const toast = useToast();
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = window.setTimeout(() => setCopied(false), 1800);
    return () => window.clearTimeout(timer);
  }, [copied]);

  const copy = async () => {
    try {
      await copyText(text);
      setCopied(true);
      toast.success(successMessage);
    } catch {
      toast.error("复制失败，请长按内容手动复制");
    }
  };

  return (
    <button
      type="button"
      onClick={() => void copy()}
      aria-label={`${successMessage.replace("已复制", "")}，点击复制`}
      className={className}
    >
      {children}
      {(copied || idleLabel) && (
        <span
          aria-live="polite"
          className={`shrink-0 text-caption ${copied ? "text-emerald-300" : "text-[var(--text-faint)]"}`}
        >
          {copied ? "已复制" : idleLabel}
        </span>
      )}
    </button>
  );
}
