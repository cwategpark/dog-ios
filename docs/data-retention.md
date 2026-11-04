# 数据保留与清理策略

| 数据 | 保留 | 清理行为 |
| --- | --- | --- |
| 游客会话 `guest_sessions` | 默认 24h（`WAGELPAW_SESSION_TTL_SECONDS`） | 过期后不可读写；worker 在 `expires_at < now - media_retention` 后删除会话、档案与未认领任务 |
| 游客上传/生成产物 | 默认 24h | `uploads.expires_at` 到期由 worker 删除文件 + Archive 行；**失败任务不伪造成功模型**；已落盘的可信 checkpoint（如 cartoon）按 `partial` 归档 |
| 已认领资产 | 长期保留 | 认领后 `asset_archive.user_id` 写入、`uploads.archived=1`、`expires_at` 延长（默认 10 年）；清理任务保护这些文件 |
| 生成任务 `jobs` | 随 owner 会话 | 成功任务结果与归档产物解耦：归档后即使会话过期，已认领资产仍可下载；崩溃恢复会补归档已落盘的 partial 产物 |
| 邮箱 challenge | OTP 10 分钟（magic-link 认领链接默认关闭；如启用 20 分钟） | 一次性原子消费；过期/已消费返回 410；不长期保存明文 |
| 移动 access token | 15 分钟 | 过期 401；refresh 轮换，旧 token 复用触发整族吊销 |
| 移动 refresh token | 30 天 | logout 吊销；复用检测 |
| 发现位置 | 24h TTL | `GET /nearby` 自动排除过期；用户可随时 `enabled=false` |
| 联系消息 | 持久 | 目前无自动删除（产品未定保留期）；生产需按隐私政策定义并加归档/删除作业 |
| 邮件 outbox（仅 test/development） | 本地文件 | 不入库、不部署生产；生产必须关闭 `WAGELPAW_DEV_EMAIL_OUTBOX` |

原则：

1. 默认匿名、最小化：邮箱只用于身份映射与 OTP，不对外展示（附近响应不含 email）。
2. 位置只存 0.05° 网格与中心，不存精确 GPS；TTL 到期即不可见，不做历史轨迹。
3. 认领是显式动作：未验证邮箱的游客不会自动继承他人数据；已认领用户数据不被 24h 清理误删。
4. 生产备份需覆盖数据库 + 私有媒体卷；只备份代码不能恢复业务数据。
