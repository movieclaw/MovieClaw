import assert from "node:assert/strict";
import test from "node:test";

import {
  jobCancellable,
  jobIsHistorical,
  jobNeedsAttention,
  selectLatestResourceJob,
  subtitleGenOpenMode,
  subtitleGenShowsTerminalIssue,
} from "../lib/job-attention.ts";

function job({ status = "failed", dismissedAt = null } = {}) {
  return { id: "job_1", status, dismissed_at: dismissedAt, dismissed_by: null };
}

// issue #221：失败任务此前没有任何出口，永远赖在「需要处理」里，
// 侧栏红角标于是永不熄灭。忽略补上的正是这个出口。

test("失败任务默认要用户处理", () => {
  assert.equal(jobNeedsAttention(job()), true);
  assert.equal(jobIsHistorical(job()), false);
});

test("忽略后失败任务从「需要处理」移到「已结束」", () => {
  const dismissed = job({ dismissedAt: "2026-08-27T10:00:00Z" });
  assert.equal(jobNeedsAttention(dismissed), false);
  assert.equal(jobIsHistorical(dismissed), true);
});

test("忽略不改写状态：它仍然是一条失败记录", () => {
  const dismissed = job({ dismissedAt: "2026-08-27T10:00:00Z" });
  assert.equal(dismissed.status, "failed");
});

test("blocked 任务同样受忽略影响，但它的正常出口是取消", () => {
  assert.equal(jobNeedsAttention(job({ status: "blocked" })), true);
  // blocked 仍占着去重键与资源锁，忽略接口不对它开放（见 services/jobs.dismiss_job）；
  // 真被忽略了也不该继续报警，判定本身保持一致。
  assert.equal(
    jobNeedsAttention(job({ status: "blocked", dismissedAt: "2026-08-27T10:00:00Z" })),
    false,
  );
});

test("成功与取消不受忽略影响，始终算已结束", () => {
  for (const status of ["succeeded", "cancelled"]) {
    assert.equal(jobNeedsAttention(job({ status })), false);
    assert.equal(jobIsHistorical(job({ status })), true);
  }
});

test("进行中的任务既不是待处理也不是历史", () => {
  for (const status of ["queued", "running", "retry_wait", "waiting", "cancelling"]) {
    assert.equal(jobNeedsAttention(job({ status })), false);
    assert.equal(jobIsHistorical(job({ status })), false);
  }
});

// issue #1050：blocked 的正常出口是取消，但卡片此前不给取消项，只能去 CLI。
test("blocked 与进行中的任务可直接取消；终态与取消中的不再给入口", () => {
  for (const status of ["blocked", "queued", "running", "retry_wait", "waiting"]) {
    assert.equal(jobCancellable({ status }), true, status);
  }
  for (const status of ["cancelling", "failed", "succeeded", "cancelled"]) {
    assert.equal(jobCancellable({ status }), false, status);
  }
});

// issue #1337：失败任务被忽略后，详情页最新任务选择、徽标与点击入口不能再指向旧失败。
function resourceJob({
  id,
  status = "failed",
  dismissedAt = null,
  createdAt = "2026-11-25T15:00:00Z",
  updatedAt = createdAt,
  fileId = "5056",
  jobType = "subtitle.generate",
} = {}) {
  return {
    id,
    job_type: jobType,
    status,
    dismissed_at: dismissedAt,
    created_at: createdAt,
    updated_at: updatedAt,
    resources: [{ resource_type: "library_file", resource_id: String(fileId), relation: "target" }],
  };
}

test("#1337: 即使历史库中已忽略旧失败的 updated_at 更新，仍选中其后的成功任务", () => {
  const pollutedDismissedFailure = resourceJob({
    id: "job_fail",
    status: "failed",
    createdAt: "2026-11-25T15:47:00Z",
    updatedAt: "2026-11-25T17:25:09Z",
    dismissedAt: "2026-11-25T17:25:08Z",
  });
  const newerSuccess = resourceJob({
    id: "job_ok",
    status: "succeeded",
    createdAt: "2026-11-25T15:50:00Z",
    updatedAt: "2026-11-25T15:52:51Z",
    dismissedAt: null,
  });

  // 故意把旧失败排在前面（模拟 JobsProvider 按 updated_at 倒序排序后的快照）
  const selected = selectLatestResourceJob(
    [pollutedDismissedFailure, newerSuccess],
    "library_file",
    5056,
    "subtitle.generate",
  );
  assert.equal(selected?.id, "job_ok");
  assert.equal(subtitleGenShowsTerminalIssue(selected, false), false);
  assert.equal(subtitleGenShowsTerminalIssue(selected, true), false);
  assert.equal(subtitleGenOpenMode(selected, false), "preview");
  assert.equal(subtitleGenOpenMode(selected, true), "preview");
});

test("#1337: 仅有一条失败任务时，忽略后详情退回空闲并走预检；撤销忽略后恢复未完成态", () => {
  const dismissedFailure = resourceJob({
    id: "job_only_fail",
    status: "failed",
    createdAt: "2026-11-25T15:47:00Z",
    updatedAt: "2026-11-25T17:25:09Z",
    dismissedAt: "2026-11-25T17:25:08Z",
  });
  assert.equal(
    selectLatestResourceJob([dismissedFailure], "library_file", 5056, "subtitle.generate"),
    null,
  );
  assert.equal(subtitleGenShowsTerminalIssue(dismissedFailure, false), false);
  assert.equal(subtitleGenOpenMode(dismissedFailure, false), "preview");

  const restoredFailure = { ...dismissedFailure, dismissed_at: null };
  const selected = selectLatestResourceJob(
    [restoredFailure],
    "library_file",
    5056,
    "subtitle.generate",
  );
  assert.equal(selected?.id, "job_only_fail");
  assert.equal(subtitleGenShowsTerminalIssue(selected, false), true);
  assert.equal(subtitleGenOpenMode(selected, false), "status");
});

test("#1337: 已有 AI 外挂字幕时徽标与点击入口一致走预检，不落入旧失败状态弹窗", () => {
  const activeFailure = resourceJob({
    id: "job_fail",
    status: "failed",
    createdAt: "2026-11-25T15:47:00Z",
    dismissedAt: null,
  });
  assert.equal(subtitleGenShowsTerminalIssue(activeFailure, true), false);
  assert.equal(subtitleGenOpenMode(activeFailure, true), "preview");

  // 运行中的任务即使已有外挂字幕仍应看进度状态弹窗
  const running = resourceJob({
    id: "job_run",
    status: "running",
    createdAt: "2026-11-25T16:00:00Z",
  });
  assert.equal(subtitleGenOpenMode(running, true), "status");
});

test("#1337: 撤销忽略旧失败且已有更新的成功任务时，仍按 created_at 选中成功任务；进行中任务始终优先", () => {
  const restoredOldFailure = resourceJob({
    id: "job_fail_old",
    status: "failed",
    createdAt: "2026-11-25T15:47:00Z",
    updatedAt: "2026-11-25T17:30:00Z",
    dismissedAt: null,
  });
  const newerSuccess = resourceJob({
    id: "job_ok_new",
    status: "succeeded",
    createdAt: "2026-11-25T15:50:00Z",
    updatedAt: "2026-11-25T15:52:51Z",
    dismissedAt: null,
  });
  assert.equal(
    selectLatestResourceJob([restoredOldFailure, newerSuccess], "library_file", 5056, "subtitle.generate")?.id,
    "job_ok_new",
  );

  const runningEarlier = resourceJob({
    id: "job_running",
    status: "running",
    createdAt: "2026-11-25T15:48:00Z",
    updatedAt: "2026-11-25T15:48:30Z",
  });
  assert.equal(
    selectLatestResourceJob([restoredOldFailure, newerSuccess, runningEarlier], "library_file", 5056, "subtitle.generate")?.id,
    "job_running",
  );
});
