# TASK-15 Apple 吊销流程两处修正 + 补 HTTP 层测试(P3)

## 背景

1. `backend/app/auth/apple_revocation.py` 在拿不到 `refresh_token` 时回退吊销 `access_token`,
   但请求里的 `token_type_hint` 写死为 `"refresh_token"`,与实际发送的 token 类型不符。
2. `revoke_apple_tokens` 的 HTTP 流程(换 code → 验归属 → 吊销)**没有任何测试**:
   `test_account_deletion.py` 在端点层整体 monkeypatch 掉了这个函数。外部 review 用
   `httpx.MockTransport` 手动跑通过一次,但没有留在仓库里。
3. iOS `ProfileView.performAccountDeletion()`(约 1007 行)不论登录方式,一律先拉起 Sign in with
   Apple 重认证。目前 App 只保留 Apple 登录(`LoginGateButtons.swift:10`),所以现在不出问题;
   一旦恢复 Google 登录,Google 用户将无法删号(取消 Apple 弹窗 = 放弃删除)。

## 要做

1. **token_type_hint 跟随实际 token**:发 `refresh_token` 时 hint 为 `refresh_token`,
   回退发 `access_token` 时 hint 为 `access_token`。
2. **补测试** `backend/tests/test_apple_revocation.py`,用 `httpx.MockTransport` 拦截两个 Apple 端点
   (不得新增依赖;不要用 respx),`verify_apple_identity_token` 用 monkeypatch 替换,
   私钥在测试里用 `cryptography` 现场生成 P-256 PEM:
   - 正常:先打 `/auth/token`,再打 `/auth/revoke`;表单含 `client_id`、`client_secret`、`code`;
     `client_secret` 能用测试公钥按 ES256 解出 `iss` / `sub` / `aud` / `kid`
   - `/auth/token` 返回非 200 → `AppleRevocationCodeInvalidError`,且**没有**打 `/auth/revoke`
   - id_token 的 sub 与账号不符 → `AppleRevocationUserMismatchError`,且没有打 `/auth/revoke`
   - 只有 `access_token` → revoke 请求的 hint 为 `access_token`
   - `/auth/revoke` 返回非 200 → `AppleRevocationEndpointError`
   - 配置缺失 → `AppleRevocationNotConfiguredError`
   - `APPLE_AUTH_PRIVATE_KEY` 以字面 `\n` 写成一行时,经 `config.py` 归一化后能正常签名
3. **iOS 按登录方式决定是否重认证**:`performAccountDeletion()` 先读当前登录用户的 `provider`
   (`AccountManager` 的当前用户模型已有 `provider: AuthProvider`)。`.apple` 才走
   `requestFreshAppleAuthorizationCode()`;其他 provider 直接以 `appleAuthorizationCode: nil`
   调删除接口。取不到当前用户 → 显式报错(复用 `account.delete.failed` 弹窗),不要默认当 Apple 处理。

## 验收

- `cd backend && python -m pytest tests/test_apple_revocation.py tests/test_account_deletion.py` 全绿
- iOS:为「按 provider 选择是否重认证」抽一个纯函数并加单测(apple → 需要;google → 不需要;
  无用户 → 抛错)

## 全局约束(必读)

- 来源:2026-11-27 外部 review;开工前读 `CLAUDE.md` 全文
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖(`httpx` / `cryptography` / `pyjwt` 已在 requirements.txt)
