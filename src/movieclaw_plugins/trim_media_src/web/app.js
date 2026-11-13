/* 飞牛影视管理页逻辑。判断类函数都放这里，便于用 node 单测。 */
(function () {
  "use strict";

  const $ = (sel) => document.querySelector(sel);

  // ───────────────────────── 纯函数（可单测） ─────────────────────────

  /** 时间的相对显示；非法输入返回原样。 */
  function relTime(iso) {
    if (!iso) return "从未";
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return String(iso);
    const diff = Date.now() - t;
    if (diff < 0) return "刚刚";
    const m = Math.floor(diff / 60000);
    if (m < 1) return "刚刚";
    if (m < 60) return `${m} 分钟前`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h} 小时前`;
    const d = Math.floor(h / 24);
    return `${d} 天前`;
  }

  /** 字节 → 人类可读。 */
  function humanBytes(n) {
    if (typeof n !== "number" || !Number.isFinite(n) || n <= 0) return "0";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let v = n, i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
  }

  /** 库配置是否完整（能拿去同步）。 */
  function libConfigured(lib) {
    return Boolean(lib && lib.id && (lib.source_configured ?? false));
  }

  /** 库的统计概要文案。 */
  function libStatText(stats) {
    if (!stats) return "—";
    const miss = stats.missing_count ? `，缺 ${stats.missing_count}` : "";
    return `${stats.item_count ?? 0} 部 / ${stats.file_count ?? 0} 文件${miss}`;
  }

  /** 范围覆盖块：飞牛库目录下有、MC 台账里没有的文件数（同步时统计，只读）。 */
  function coverageBlock(cov) {
    if (!cov || !cov.files) {
      return `<div class="meta">范围覆盖：<b>尚未统计</b>（下次同步时检查）</div>`;
    }
    if (!cov.uncovered) {
      return `<div class="meta">范围覆盖：<b>${cov.files} / ${cov.files} 个视频文件已收录</b>
        <span class="tag ok">完整</span></div>`;
    }
    const rows = (cov.top_uncovered || [])
      .map((x) => `<div class="file"><span class="t">${escapeHtml(x.dir)}</span><span class="d">${x.files} 个文件</span></div>`)
      .join("");
    return `<div class="meta">范围覆盖：<b>${cov.covered} / ${cov.files}</b> 已收录
        <span class="tag warn">漏 ${cov.uncovered}</span></div>
      <details class="files"><summary>未覆盖的目录（${(cov.top_uncovered || []).length}）</summary>${rows}</details>
      <div class="meta"><small>飞牛这个库的目录比 MC 的库根大（如挂的是父目录），
        需要把库根改成 <code>${escapeHtml((cov.local_roots || [])[0] || "")}</code> 才能收全。</small></div>`;
  }

  /** 库是否是「本机可见」模式。 */
  function isLocalMode(lib) {
    const roots = (lib && lib.root_paths) || [];
    return roots.length > 0;
  }

  /** 飞牛库分类 → 显示名。 */
  function categoryLabel(category) {
    return { Movie: "电影", TV: "剧集", Mix: "混合" }[category] || category || "未知";
  }

  /** 进度百分比（0-100，封顶）。 */
  function progressPct(positionMs, durationMs) {
    if (!positionMs || !durationMs || durationMs <= 0) return 0;
    return Math.max(0, Math.min(100, (positionMs / durationMs) * 100));
  }

  /** 待识别行的展示名。 */
  function unmatchedLabel(row) {
    if (!row) return "";
    const base = row.title || row.original_title || row.guid || "";
    return row.year ? `${base} (${row.year})` : base;
  }

  /** 对齐报告的一行摘要。 */
  function alignSummary(report) {
    if (!report) return "";
    const m = report.match || {};
    return `飞牛 ${report.trim_entries} 条：L1 ${m.l1_tmdb} / L2 ${m.l2_file} / L3 ${m.l3_title}，未匹配 ${m.unmatched}`;
  }

  if (typeof module !== "undefined") {
    module.exports = {
      relTime, humanBytes, libConfigured, libStatText, isLocalMode,
      categoryLabel, progressPct, unmatchedLabel, alignSummary,
    };
  }

  // ───────────────────────── 页面逻辑 ─────────────────────────

  const API = "/api/v1/plugins/trim-media-src";

  function toast(msg, kind) {
    const el = $("#toast");
    el.textContent = msg;
    el.className = "toast" + (kind ? " " + kind : "");
    clearTimeout(el._timer);
    el._timer = setTimeout(() => el.classList.add("hidden"), 3500);
  }

  async function api(path, opts) {
    const resp = await fetch(API + path, {
      headers: { "Content-Type": "application/json" },
      ...opts,
    });
    const body = await resp.json().catch(() => ({}));
    if (!resp.ok) throw new Error(body.detail || body.message || `HTTP ${resp.status}`);
    return body.data !== undefined ? body.data : body;
  }

  function busy(btn, on, label) {
    if (on) { btn._text = btn.textContent; btn.textContent = label || "处理中…"; btn.disabled = true; }
    else { btn.textContent = btn._text || btn.textContent; btn.disabled = false; }
  }

  // ── 状态条 ──
  async function loadStatus() {
    try {
      const st = await api("/status");
      $("#st-conn").textContent = st.configured ? "已配置" : "未配置";
      $("#st-host").textContent = st.base_url || "—";
      $("#st-libs").textContent = (st.libraries || []).length + " 个";
      $("#st-sync").textContent = relTime(st.last_sync_at);
      // 「同步成员」：进度的两边对账是谁的（飞牛按账号存进度，这里说清楚）
      $("#st-member").textContent = st.member_username || "超管本人";
      $("#st-tls").textContent = st.verify_tls ? "校验" : "已关闭";
      $("#conn-dot").className = "dot " + (st.configured ? "ok" : "bad");
      renderMembersProgress(st.libraries || []);
    } catch (err) {
      $("#st-conn").textContent = "加载失败";
      $("#conn-dot").className = "dot bad";
    }
  }

  // ── 媒体库映射 ──
  async function loadLibraries() {
    try {
      const st = await api("/status");
      const list = $("#lib-list");
      list.innerHTML = "";
      const libs = st.libraries || [];
      if (!libs.length) {
        list.innerHTML = `<div class="empty" style="grid-column:1/-1">还没有接入的库，点右上「接入飞牛库」</div>`;
        return;
      }
      for (const lib of libs) {
        const card = document.createElement("div");
        card.className = "card";
        const mode = isLocalMode(lib) ? "本机直连" : "远程";
        const modeTag = isLocalMode(lib)
          ? `<span class="tag ok">直连</span>`
          : `<span class="tag">远程</span>`;
        card.innerHTML = `
          <div class="row">
            <span class="name">${escapeHtml(lib.name)} ${modeTag}</span>
            <span class="kind">${lib.kind === "movie" ? "电影" : "剧集"}</span>
          </div>
          <div class="meta">
            飞牛库：<b>${escapeHtml(lib.fn_name || lib.fn_guid || "—")}</b><br>
            内容：<b>${escapeHtml(libStatText(lib.stats))}</b> · ${mode}<br>
            片头片尾：<b>${lib.markers_pushed ? `${lib.markers_pushed} 季已写回飞牛` : "尚未写回"}</b><br>
            最近同步：<b>${relTime(lib.last_sync_at)}</b>
          </div>
          ${coverageBlock(lib.coverage)}
          <div class="acts">
            <button class="btn btn-sm" data-act="sync-one" data-id="${lib.id}">同步</button>
            <button class="btn btn-sm" data-act="cov" data-id="${lib.id}">检查覆盖</button>
            <button class="btn btn-sm btn-danger" data-act="del" data-id="${lib.id}" data-name="${escapeHtml(lib.name)}">移除库</button>
          </div>`;
        list.appendChild(card);
      }
      renderSyncSummary(st.last_sync_result);
      list.querySelectorAll('[data-act="sync-one"]').forEach((b) =>
        b.addEventListener("click", async () => {
          busy(b, true, "…");
          try { await api("/sync-now", { method: "POST", body: "{}" }); toast("已加入同步队列", "ok"); }
          catch (e) { toast(e.message, "bad"); }
          busy(b, false);
        })
      );
      list.querySelectorAll('[data-act="cov"]').forEach((b) =>
        b.addEventListener("click", async () => {
          busy(b, true, "统计中…");
          try {
            const r = await api(`/check-coverage?library_id=${Number(b.dataset.id)}`);
            const first = (r.libraries || [])[0];
            if (first) {
              toast(
                first.uncovered
                  ? `「${first.library}」漏 ${first.uncovered} 个文件（已收 ${first.covered}/${first.files}）`
                  : `「${first.library}」${first.files} 个文件全部收录`,
                first.uncovered ? "bad" : "ok"
              );
            } else {
              toast("这个库没有本机根，无需检查", "bad");
            }
            loadLibraries();
          } catch (err) {
            toast("检查失败：" + err.message, "bad");
          } finally {
            busy(b, false);
          }
        })
      );
      list.querySelectorAll('[data-act="del"]').forEach((b) =>
        b.addEventListener("click", async () => {
          const id = b.dataset.id, name = b.dataset.name;
          if (!confirm(`删除 MC 库「${name}」？\n\n只删库和台账，不动磁盘文件、不动飞牛。`)) return;
          try {
            await fetch(`/api/v1/libraries/${id}`, { method: "DELETE" });
            toast("已删除", "ok");
            loadLibraries(); loadStatus();
          } catch (e) { toast("删除失败：" + e.message, "bad"); }
        })
      );
    } catch (err) { toast("加载库失败：" + err.message, "bad"); }
  }

  /** 上一轮同步每个库的结果：成功写了几条、跳过原因、失败原因。 */
  function renderSyncSummary(result) {
    const box = $("#sync-summary");
    if (!box) return;
    if (!result || !(result.libraries || []).length) {
      box.innerHTML = "";
      return;
    }
    const chips = result.libraries.map((x) => {
      if (x.skipped) {
        const why = x.skipped === "busy" ? "库在扫描/整理" : x.skipped === "skip_segments" ? "识别任务在跑" : x.skipped;
        return `<span class="tag warn">${escapeHtml(x.library || "（全局）")}：跳过（${escapeHtml(why)}）</span>`;
      }
      if (x.error) {
        return `<span class="tag bad">${escapeHtml(x.library || "—")}：${escapeHtml(String(x.error).slice(0, 60))}</span>`;
      }
      const bits = [];
      if (x.mode === "light") bits.push("轻同步");
      if (typeof x.remote === "number") bits.push(`${x.remote} 条`);
      if (x.markers && x.markers.written) bits.push(`片头片尾 +${x.markers.written}`);
      if (x.missing) bits.push(`缺 ${x.missing}`);
      if (x.fetch_failed) bits.push(`拉取失败 ${x.fetch_failed} 季`);
      return `<span class="tag">${escapeHtml(x.library || "—")}：${escapeHtml(bits.join(" · ") || "完成")}</span>`;
    }).join(" ");
    box.innerHTML = `<div class="hint" style="margin:10px 0 0">上次同步 ${relTime(result.at)}：${chips}</div>`;
  }

  // ── 飞牛侧库 ──
  async function loadFnLibraries() {
    try {
      const [remote, locals] = await Promise.all([api("/libraries"), api("/status")]);
      const localByGuid = new Set((locals.libraries || []).map((l) => l.fn_guid || l.fn_guid_text).filter(Boolean));
      const knownNames = new Set((locals.libraries || []).map((l) => (l.fn_name || "").trim()));
      const body = $("#fn-libs-body");
      body.innerHTML = "";
      const libs = remote || [];
      $("#fn-libs-count").textContent = libs.length + " 个";
      if (!libs.length) { body.innerHTML = `<tr><td colspan="4" class="empty">飞牛上没有媒体库</td></tr>`; return; }
      for (const lib of libs) {
        const imported = localByGuid.has(lib.guid) || knownNames.has(lib.name);
        const tr = document.createElement("tr");
        // 目录往往又长又多：一行一个、最多显示两行，超出省略；悬停看完整路径
        const dirs = (lib.dirs || []).map((d) => escapeHtml(String(d).replace(/\/+$/, "")));
        const dirHtml = dirs.length ? dirs.join("<br>") : "—";
        tr.innerHTML = `
          <td class="name">${escapeHtml(lib.name)}</td>
          <td class="kind">${categoryLabel(lib.category)}</td>
          <td class="path"><code title="${escapeHtml((lib.dirs || []).join("；"))}">${dirHtml}</code></td>
          <td class="state">${imported
            ? `<span class="tag ok">已接入</span>`
            : `<span class="tag">未接入</span>`}</td>`;
        body.appendChild(tr);
      }
    } catch (err) {
      $("#fn-libs-body").innerHTML = `<tr><td colspan="4" class="empty">加载失败：${escapeHtml(err.message)}</td></tr>`;
    }
  }

  // ── 待识别 ──
  async function loadUnidentified() {
    try {
      const st = await api("/status");
      const libIds = new Set((st.libraries || []).map((l) => l.id));
      // 分组数据只带 library_id，类型要从库清单里查（电影/剧集的认领前缀不同）
      const libKind = new Map((st.libraries || []).map((l) => [l.id, l.kind]));
      const resp = await fetch("/api/v1/libraries/identification/unidentified-files");
      const payload = await resp.json().catch(() => null);
      const groups = ((payload && payload.data) || []).filter((g) => libIds.has(g.library_id));
      const list = $("#unid-list");
      list.innerHTML = "";
      const total = groups.reduce((n, g) => n + (g.file_count || 0), 0);
      $("#unid-count").textContent = total;

      if (!groups.length) {
        list.innerHTML = `<div class="empty">全部识别完毕，没有待认领的内容</div>`;
        return;
      }
      for (const g of groups) {
        // 每组一张卡：组名 / 库 / 文件数与体积 / 失败原因 / 候选建议 / 文件明细
        const card = document.createElement("div");
        card.className = "card unid-card";
        const cands = (g.candidates || [])
          .map(
            (c) => `<div class="cand">
              <b>${escapeHtml(c.title)}</b>${c.year ? ` <span class="d">(${c.year})</span>` : ""}
              ${c.episode_count ? `<span class="d">· ${c.episode_count} 集</span>` : ""}
              ${c.tmdb_id ? `<a target="_top" href="https://www.themoviedb.org/${libKind.get(g.library_id) === "movie" ? "movie" : "tv"}/${c.tmdb_id}">TMDB ${c.tmdb_id}</a>` : ""}
            </div>`
          )
          .join("");
        const files = (g.files || [])
          .map(
            (f) => `<div class="file">
              <span class="t">${escapeHtml((f.file_path || "").split("/").pop() || f.file_name || "")}</span>
              <span class="d">${humanBytes(f.size_bytes || 0)}${f.duration_seconds ? ` · ${Math.round(f.duration_seconds / 60)} 分钟` : ""}</span>
            </div>`
          )
          .join("");
        card.innerHTML = `
          <div class="row">
            <span class="name">${escapeHtml(g.label)}
              <span class="tag warn">${escapeHtml(g.code || "待认领")}</span>
            </span>
            <span class="tag">${escapeHtml(g.library_name)} · ${g.file_count} 文件 · ${humanBytes(g.total_size_bytes)}</span>
          </div>
          ${g.reason ? `<div class="meta">${escapeHtml(g.reason)}</div>` : ""}
          ${cands ? `<div class="meta"><b>候选（点击整组认领）：</b>${cands}</div>` : ""}
          ${files ? `<details class="files"><summary>文件明细（${(g.files || []).length}）</summary>${files}</details>` : ""}
          <div class="acts">
            ${g.candidates && g.candidates.length && g.candidates[0].tmdb_id ? `<button class="btn btn-sm" data-claim="1" data-kind="${escapeHtml(libKind.get(g.library_id) || "tv")}" data-files="${escapeHtml(JSON.stringify((g.files || []).map((f) => f.id)))}" data-tmdb="${g.candidates[0].tmdb_id}" data-title="${escapeHtml((g.candidates[0].title || "").slice(0, 20))}">一键认领为「${escapeHtml((g.candidates[0].title || "").slice(0, 18))}」</button>` : ""}
            <a class="btn btn-sm" target="_top" href="/library/${g.library_id}">去媒体库处理</a>
          </div>`;
        list.appendChild(card);
      }
      list.querySelectorAll("[data-claim]").forEach((b) =>
        b.addEventListener("click", async () => {
          let fileIds = [];
          try { fileIds = JSON.parse(b.dataset.files || "[]"); } catch { fileIds = []; }
          const tmdb = Number(b.dataset.tmdb);
          // 电影和剧集的 title_ref 前缀不同：写死 tmdb:tv: 的话，电影会被主线拒绝
          const mediaType = b.dataset.kind === "movie" ? "movie" : "tv";
          if (!fileIds.length || !tmdb) { toast("认领信息不完整", "bad"); return; }
          busy(b, true, "认领中…");
          try {
            const resp = await fetch("/api/v1/libraries/identification/file-title-assignments", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({
                file_ids: fileIds,
                title_ref: `tmdb:${mediaType}:${tmdb}`,
                season_number: null,
              }),
            });
            const body = await resp.json().catch(() => ({}));
            if (!resp.ok) throw new Error(body.detail || body.message || `HTTP ${resp.status}`);
            toast(`已认领 ${fileIds.length} 个文件为「${b.dataset.title}」`, "ok");
            loadUnidentified();
          } catch (err) {
            toast("认领失败：" + err.message, "bad");
          } finally {
            busy(b, false);
          }
        })
      );
    } catch (err) {
      $("#unid-list").innerHTML = `<div class="empty">加载失败：${escapeHtml(err.message)}</div>`;
    }
  }

  // ── 同步进度（每个库的可用文件比例） ──
  function renderMembersProgress(libs) {
    const box = $("#progress-list");
    if (!box) return;
    box.innerHTML = "";
    if (!libs.length) {
      box.innerHTML = `<div class="empty">还没有接入的库</div>`;
      $("#prog-tag").textContent = "—";
      return;
    }
    let files = 0, usable = 0, missing = 0;
    for (const lib of libs) {
      const st = lib.stats || {};
      const total = st.file_count || 0;
      const miss = st.missing_count || 0;
      const okCount = Math.max(0, total - miss);
      files += total; usable += okCount; missing += miss;
      const pct = total ? Math.round((okCount / total) * 100) : 0;
      const el = document.createElement("div");
      el.className = "row-item";
      el.innerHTML = `
        <span class="t">${escapeHtml(lib.name)}</span>
        <span class="d">${okCount} / ${total} 个文件可用${miss ? ` · 缺 ${miss}` : ""} · ${relTime(lib.last_sync_at)}同步</span>
        <span class="tag ${miss ? "warn" : "ok"}">${pct}%</span>
        <span class="bar"><i style="width:${pct}%"></i></span>`;
      box.appendChild(el);
    }
    $("#prog-tag").textContent = missing
      ? `${usable} / ${files} 可用，缺 ${missing}`
      : `${usable} / ${files} 全部可用`;
  }

  // ── 成员 ──
  async function loadMembers() {
    try {
      const resp = await fetch("/api/v1/members");
      const payload = await resp.json().catch(() => null);
      if (!resp.ok) {
        throw new Error((payload && (payload.detail || payload.message)) || `HTTP ${resp.status}`);
      }
      const rows = (payload && payload.data) || [];
      $("#member-count").textContent = rows.length + " 人";
      const list = $("#member-list");
      list.innerHTML = "";
      if (!rows.length) {
        list.innerHTML = `<div class="empty">还没有成员</div>`;
        return;
      }
      for (const m of rows) {
        const enabled = m.status !== "disabled";
        const scope = m.all_libraries
          ? "全部库"
          : `${(m.library_ids || []).length} 个库`;
        const el = document.createElement("div");
        el.className = "row-item";
        el.innerHTML = `
          <span class="t">${escapeHtml(m.nickname || m.username)}</span>
          <span class="d">${escapeHtml(m.username)} · ${scope}${m.device_count ? ` · ${m.device_count} 台设备在线` : ""}</span>
          <span class="tag">${relTime(m.last_login_at)}登录</span>
          <span class="tag ${enabled ? "ok" : "bad"}">${enabled ? "启用" : "停用"}</span>`;
        list.appendChild(el);
      }
    } catch (err) {
      $("#member-list").innerHTML = `<div class="empty">加载失败：${escapeHtml(err.message)}</div>`;
    }
  }

  // ── 接入飞牛库弹窗 ──
  async function openAddDialog() {
    const sel = $("#add-lib-select");
    sel.innerHTML = `<option value="">加载中…</option>`;
    $("#add-lib-name").value = "";
    $("#add-lib-local").value = "";
    const dlg = $("#dlg-add");
    if (typeof dlg.showModal === "function") dlg.showModal();
    try {
      const libs = await api("/libraries");
      const usable = (libs || []).filter((l) => l.supported !== false && !l.overlap);
      sel.innerHTML = "";
      if (!usable.length) {
        sel.innerHTML = `<option value="">没有可接入的库</option>`;
        return;
      }
      for (const lib of usable) {
        const opt = document.createElement("option");
        opt.value = lib.guid;
        opt.dataset.kind = lib.category === "Movie" ? "movie" : "tv";
        opt.dataset.name = lib.name || "";
        opt.dataset.local = (lib.local_roots || [])[0] || "";
        opt.disabled = Boolean(lib.imported);
        opt.textContent = `${lib.name || lib.guid}（${categoryLabel(lib.category)}）${lib.imported ? " · 已接入" : ""}`;
        sel.appendChild(opt);
      }
      const pick = (guid) => {
        const opt = sel.selectedOptions[0];
        if (!opt) return;
        $("#add-lib-name").value = opt.dataset.name || "";
        $("#add-lib-local").value = opt.dataset.local || "";
      };
      sel.onchange = () => pick(sel.value);
      const first = usable.find((l) => !l.imported);
      if (first) sel.value = first.guid;
      pick(sel.value);
    } catch (err) {
      sel.innerHTML = `<option value="">加载失败：${escapeHtml(err.message)}</option>`;
    }
  }

  async function submitAddLib() {
    const sel = $("#add-lib-select");
    const guid = sel.value;
    if (!guid) { toast("先选一个飞牛库", "bad"); return; }
    const opt = sel.selectedOptions[0];
    const body = {
      library_guid: guid,
      library_name: opt ? opt.dataset.name || "" : "",
      name: $("#add-lib-name").value.trim() || (opt ? opt.dataset.name || "" : ""),
      kind: opt ? opt.dataset.kind || "movie" : "movie",
      local_root: $("#add-lib-local").value.trim(),
    };
    const btn = $("#add-lib-ok");
    busy(btn, true, "接入中…");
    try {
      const res = await api("/create-library", { method: "POST", body: JSON.stringify(body) });
      $("#dlg-add").close();
      toast(`已接入「${body.name}」${res && res.created === false ? "（同步已在进行）" : "，正在同步"}`, "ok");
      loadLibraries(); loadFnLibraries(); loadStatus();
    } catch (err) {
      toast("接入失败：" + err.message, "bad");
    } finally {
      busy(btn, false);
    }
  }

  // ── 飞牛账号 ──
  async function loadAccount(refresh) {
    const body = $("#acc-users-body");
    try {
      const r = await api("/account" + (refresh ? "?refresh=true" : ""));
      const cur = r.current;
      const box = $("#acc-current");
      if (!cur) {
        box.innerHTML = `<div class="empty">没取到账号信息，检查连接配置</div>`;
      } else {
        const role = cur.is_admin ? "管理员" : "普通账号";
        const scope = cur.library_count ? `可见 ${cur.library_count} 个库` : "未分配库权限";
        const seen = cur.last_login_at ? `${relTime(cur.last_login_at)}登录` : "最近登录：未知";
        const from = (cur.sources || []).length
          ? `NAS 来源：${(cur.sources || []).join("、")}`
          : "";
        box.innerHTML = `
          <div class="row-item">
            <span class="t">${escapeHtml(cur.username)}</span>
            <span class="d">${role} · ${scope} · ${seen}${from ? ` · ${escapeHtml(from)}` : ""}</span>
            <span class="tag ${cur.is_admin ? "ok" : ""}">${role}</span>
          </div>`;
        const tpl = r.template || {};
        if (tpl.media_permission !== undefined && tpl.media_permission !== null) {
          const tplDesc = tpl.library_count
            ? `新建账号默认可见 ${tpl.library_count} 个库`
            : "新建账号默认不给库权限";
          box.insertAdjacentHTML(
            "beforeend",
            `<div class="hint" style="margin:6px 0 0">默认权限模板：${escapeHtml(tplDesc)}（权限档 ${escapeHtml(String(tpl.media_permission))}）</div>`
          );
        }
      }
      const rows = r.users || [];
      $("#acc-state").textContent = rows.length
        ? `${rows.length} 个账号`
        : (r.is_admin ? "没有账号" : "需要管理员");
      body.innerHTML = "";
      if (!rows.length) {
        body.innerHTML = `<tr><td colspan="4" class="empty">${
          r.is_admin ? "飞牛上没有其他账号" : "当前账号不是管理员，看不到账号列表"
        }</td></tr>`;
        return;
      }
      for (const u of rows) {
        const libs = (u.libraries || []).join("、") || "—";
        const tr = document.createElement("tr");
        tr.innerHTML = `
          <td class="name">${escapeHtml(u.username)}</td>
          <td class="state"><span class="tag ${u.is_admin ? "ok" : ""}">${u.is_admin ? "管理员" : "普通"}</span></td>
          <td class="path"><code title="${escapeHtml(libs)}">${escapeHtml(libs)}</code></td>
          <td class="kind">${u.last_login_at ? relTime(u.last_login_at) : "从未"}</td>`;
        body.appendChild(tr);
      }
    } catch (err) {
      $("#acc-state").textContent = "加载失败";
      body.innerHTML = `<tr><td colspan="4" class="empty">${escapeHtml(err.message)}</td></tr>`;
    }
  }

  $("#btn-acc-refresh").addEventListener("click", async (e) => {
    busy(e.target, true, "…");
    await loadAccount(true);
    busy(e.target, false);
  });

  // ── 运行日志（每 3 秒增量拉一次） ──
  const LOG_POLL_MS = 3000;
  let logPaused = false;
  let logLastKey = "";

  function logKey(item) {
    return `${item.ts}|${item.message}`;
  }

  function logLineHtml(item) {
    const level = String(item.level || "").toUpperCase();
    const cls = level === "ERROR" || level === "CRITICAL" ? "bad" : level === "WARNING" ? "warn" : "";
    const time = String(item.ts || "").slice(11) || String(item.ts || "");
    // 消息里常带「库「飞牛剧集（直连）」」这类中文书名号，原样显示即可
    return `<div class="logline ${cls}"><span class="t">${escapeHtml(time)}</span>`
      + `<span class="l">${escapeHtml(level)}</span>`
      + `<span class="m">${escapeHtml(item.message)}</span></div>`;
  }

  async function loadLogs() {
    if (logPaused) return;
    const box = $("#log-box");
    try {
      const r = await api("/runtime-logs?limit=200");
      const items = r.items || [];
      if (!items.length) {
        if (!logLastKey) box.innerHTML = `<div class="empty">还没有日志</div>`;
        $("#log-state").textContent = "无记录";
        return;
      }
      const lastKey = logLastKey;
      let start = 0;
      if (lastKey) {
        // 从后往前找上一条，命中它的下一条就是新增（同一秒同文案也不会错位）
        for (let i = items.length - 1; i >= 0; i--) {
          if (logKey(items[i]) === lastKey) { start = i + 1; break; }
        }
      }
      const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 40;
      if (!lastKey || start === 0) {
        box.innerHTML = items.map(logLineHtml).join("");
        box.scrollTop = box.scrollHeight;
      } else if (start < items.length) {
        box.insertAdjacentHTML("beforeend", items.slice(start).map(logLineHtml).join(""));
        if (atBottom) box.scrollTop = box.scrollHeight;
      }
      logLastKey = logKey(items[items.length - 1]);
      $("#log-state").textContent = `${items.length} 条`;
    } catch (err) {
      $("#log-state").textContent = "加载失败";
    }
  }

  $("#btn-log-toggle").addEventListener("click", (e) => {
    logPaused = !logPaused;
    e.target.textContent = logPaused ? "继续" : "暂停";
    e.target.classList.toggle("btn-primary", logPaused);
    if (!logPaused) loadLogs();
  });
  $("#btn-log-clear").addEventListener("click", () => {
    logLastKey = "";
    $("#log-box").innerHTML = `<div class="empty">已清屏，新日志会继续出现</div>`;
  });

  // ── 工具 ──
  function escapeHtml(s) {
    return String(s ?? "").replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // ── 启动 ──
  $("#btn-sync").addEventListener("click", async (e) => {
    busy(e.target, true, "同步中…");
    try {
      const r = await api("/sync-now", { method: "POST", body: "{}" });
      toast(r.created ? "已开始同步，任务在「活动」里" : "同步已在进行中", "ok");
      setTimeout(() => { loadLibraries(); loadStatus(); busy(e.target, false); }, 2500);
    } catch (err) { toast(err.message, "bad"); busy(e.target, false); }
  });
  $("#btn-align").addEventListener("click", async (e) => {
    busy(e.target, true, "对齐中…");
    try {
      const r = await api("/align", { method: "POST", body: "{}" });
      const lines = (r.libraries || []).map((x) => `${x.library}：${alignSummary(x)}`);
      toast(lines.join(" ｜ ") || "对齐完成", "ok");
      busy(e.target, false);
    } catch (err) { toast(err.message, "bad"); busy(e.target, false); }
  });
  $("#btn-add-lib").addEventListener("click", openAddDialog);
  $("#add-lib-ok").addEventListener("click", (e) => { e.preventDefault(); submitAddLib(); });

  // 各区块独立加载：一个接口挂了只空它自己那一块，不拖垮整页
  const safe = (fn) => () => Promise.resolve(fn()).catch((err) => console.error("[飞牛影视]", err));
  safe(loadStatus)();
  safe(loadLibraries)();
  safe(loadFnLibraries)();
  safe(loadUnidentified)();
  safe(loadMembers)();
  safe(() => loadAccount(false))();
  safe(loadLogs)();
  setInterval(safe(loadStatus), 30000);
  setInterval(safe(loadLogs), LOG_POLL_MS);
})();
