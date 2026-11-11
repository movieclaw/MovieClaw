<!--
中文 / English 都可以。可以删掉用不上的小节。
Either Chinese or English is fine. Delete any section that doesn't apply.

同步 main 请用 rebase，不要 merge：
仓库只允许变基合并，分支里带「Merge main into …」提交（尤其是手工解过冲突的）时，
GitHub 没法自动变基，合并按钮会被挡住。

  git fetch upstream main
  git rebase upstream/main
  git push --force-with-lease

Please sync with main by rebasing, not merging: this repo only allows rebase merges,
and a "Merge main into …" commit (especially one with hand-resolved conflicts)
blocks the merge button.
-->

## 改了什么 / What & why

## 验证 / Verification

<!-- 跑了哪些测试、在哪些端 / 设备上试过；没能验证的端也请写明。
     Which tests you ran and on which clients/devices; please also list what you couldn't verify. -->
