# iOS ↔ canonical 账号链路证据（2026-11-10）

本目录保留原 Windows 隔离测试的脚本与脱敏证据，供 iOS 团队复现账号联动结论。

## 文件

- `verify_account_linkage.py`：隔离测试脚本；只在临时 SQLite/媒体/outbox 中运行，使用
  `example.invalid` 合成账号，不发送真实邮件、不调用真实生成供应商，结束后清理运行目录。
- `account-linkage-evidence.json`：2026-11-10 Windows 隔离测试原始证据；7 项断言
  `passed: true`，`cleaned_up: true`，无真实用户、OTP 或 token。

## 运行前提

必须使用最新网站 dog canonical backend 源码及其 Python 环境/requirements；**不能只用
本 iOS repo 自带的过时 `backend/` 复现**（其缺少 `/mobile/v1/models`、
`/mobile/v1/orders/logistics` 等接口）。示例：

```bash
cd /Users/jbf/Documents/dog-ios
/path/to/dog-canonical-root/backend/.venv/bin/python \
  docs/ios-sync-verification/verify_account_linkage.py \
  --canonical-project /path/to/dog-canonical-root
```

`--canonical-project` 必须是包含 `backend/` 的 canonical root。脚本默认参数保留原
Windows 路径，仅用于记录原始环境；跨机器运行时应显式传入。

脚本生成的工作目录在 `docs/ios-sync-verification/work/`，已加入 `.gitignore`；不得提交
运行凭据、SQLite 数据库、媒体、OTP 或 fixture 私有文件。证据文件只用于只读审计。
