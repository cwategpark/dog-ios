# 第三轮剩余后端缺陷修复与证据

日期：2026-11-04。仅后端与测试；未修改 SwiftUI/网站主题视觉。基线包为
`dog-ios-delivery-20261104-124040.tar.gz`。本轮每条均有确定性测试，不把“15 项”整体
重新宣称为已完成。

## 1. 归档补领新事务重新解析 guest session→pet（P2）

- 修复：`_reconcile_archive_ownership` 在补领事务内重新调用 `_pet_id_for_session`；`archive_upload`
  在观察点之后重读权威 `guest_sessions.user_id` 与 `GuestSessionPet` 后再插入，不再使用认领前缓存值；
  manifest 归档也做 job 级幂等检查。
- 测试：
  - `test_archive_backfill_re_resolves_pet_mapping_in_new_transaction`
  - `test_archive_commit_then_claim_backfills_user_and_pet`
  - 断言 `AssetArchive.user_id`、`AssetArchive.pet_id`、`GuestSessionPet` 与 `/pet-home?pet_id=` 的
    `selected=personal`，并验证重复归档只有一行。
- 复现路径：未认领 guest + PetProfile + 成功 model job；`archive_job_result` 的 `ownership_read`
  观察点内完成 `claim_guest_session`，随后归档提交。

## 2. 终态 job 归档补偿 + cleanup 保护（P1）

- 修复：
  - `jobs` 迁移 `0004` 增加 `archived_at/archive_attempts/archive_retry_at`；
    `archive_pending_jobs` 每轮有界扫描 success/failed/needs_review 终态 job，只调用归档路径，
    不调用供应商；失败按指数退避重试，成功/无产物标记 `archived_at`，重复调用幂等。
  - worker `serve` 每轮调用补偿扫描；成功提交后崩溃、首次归档失败、partial 恢复归档失败均可恢复。
  - `cleanup_expired` 的 guest 归属集合包含 `Upload.owner_id`：无 archive 但 owner guest 已认领时，
    交付文件与 DB 行在 TTL 清理中被保护，等待补偿归档。
  - `archive_job_result` 对 manifest 做 job 级去重，避免重试产生重复 manifest archive。
- 测试：
  - `test_success_crash_before_archive_is_repaired_by_worker_loop`（cleanup 保护 + `serve(once=True)` 补归档 + 下载）
  - `test_first_success_archive_failure_is_retried_by_compensation`
  - `test_partial_recovery_archive_failure_is_retried`（`recover_expired` 首次失败后补偿成功）
  - `test_unclaimed_expired_upload_is_still_deleted`（未认领仍正常清理）
  - 断言同一 Upload 只有一条 archive、`provider_calls == []`、24h 后文件仍在。

## 3. block/create/accept/send 的 TOCTOU（P1）

- 根因：`blocked_between` 返回 false 后，另一线程 `add_block` 提交，再恢复写入；解除拉黑后数据重现。
- 修复：新增持久表 `social_pair_locks`（有序 `pair_key`）+ `_lock_pair`：
  - 在同一事务内先取得 pair 行写锁（PostgreSQL 行锁；SQLite 写事务），再检查 block 并写入；
  - `create_contact_request`、`respond_to_request`、`send_message`、`add_block`、`remove_block`
    使用同一协议；单纯重复 read 不再作为同步手段。
  - 迁移 `0004` 建表；测试同时编译 PostgreSQL 与 SQLite SQL/DDL。
- 测试（`backend/tests/test_social_pair_lock.py`）：
  - `test_create_cannot_commit_after_a_concurrent_block_check`
  - `test_send_cannot_commit_after_a_concurrent_block_check`
  - `test_accept_cannot_commit_after_a_concurrent_block_check`
  - `test_block_first_rejects_create_and_send`、`test_block_first_rejects_accept`
  - `test_audit_gate_create_cannot_pass_after_block_commit`
  - `test_audit_gate_send_cannot_pass_after_block_commit`
  - `test_pair_lock_row_is_ordered_persistent_and_portable_sql`
  - 断言 block 在操作持有 pair 锁时不能提交；block 先提交时 create/send/accept 得到 403/409。

## 验证边界

- 本轮真实运行 SQLite；PostgreSQL 只做 SQL/DDL 编译与设计推理，Mac 无 PG/Docker 运行时，不能声称
  PostgreSQL 并发实测通过。
- 未修改 UI/主题视觉；未发真实邮件、未付费生成、未 commit/push。
