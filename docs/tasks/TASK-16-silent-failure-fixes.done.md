# TASK-16 账号删除链路两处「静默失败」+ 一处注释错位(P3)

## 背景

CLAUDE.md 要求错误显式传播。4fa6be73 留下两处静默失败:

1. `backend/app/auth/dependencies.py` `require_authenticated_user`:
   `getattr(request.app.state, "user_store", None)` 为 `None` 时直接跳过「账号是否存在」核验,
   请求被放行(fail-open)。生产不应出现,但出现即配置错误,应当报错而不是放行。
2. `ios/QiCompass/QiCompass/Services/EntitlementStore.swift` `deactivateAllForAccount`:
   失败只返回 `-1` 并记日志,调用方 `ProfileView.performAccountDeletion()` 用
   `@discardableResult` 忽略了返回值。结果:用户看到「账号已删除」,本机已购章节却仍显示解锁,
   点进去后端返回 403。删号后用户已是匿名态,`synchronizeFromBackend` 不会再跑,这个错误状态会一直留着。
3. 同文件里 `synchronizeFromBackend` 的文档注释(约 200–212 行)被新函数插在中间,
   现在挂到了 `deactivateAllForAccount` 头上,`synchronizeFromBackend` 反而没有注释。

## 要做

1. **后端**:`require_authenticated_user` 在 `user_store is None` 时抛错(500 语义的配置错误,
   复用现有错误类型体系,message 写清「app.state.user_store 未初始化」)。
   先 grep 测试里是否有构造 app 时不挂 `user_store` 的用例;有就给它们挂上,不要为测试保留放行分支。
2. **iOS `deactivateAllForAccount`**:改成 `throws`(去掉 `-1` 返回值约定)。
   `performAccountDeletion()` 中服务端删除成功后:
   - 调用失败 → 在 `UserDefaults` 写待办标记(key 例如 `pendingLocalEntitlementDeactivation`,
     值存要失效的 `userId` 与 `userLocalId`),照常 `signOut()`,完成提示改用下表新文案
   - `RootTabView` 启动时(`.onAppear` 里现有分流处)发现待办标记 → 重试失效;成功清标记,
     失败保留标记并记 error 日志,下次启动再试
   - `signOut()` 必须在读取 `UserIdentity.currentUserId` **之后**执行(先取值存进局部变量,再登出)
3. **注释归位**:把 `synchronizeFromBackend` 的文档注释挪回该函数上方;
   `deactivateAllForAccount` 只保留它自己的那段说明,并按新的 `throws` 语义更新。

新增一个文案 key(删除成功但本机失效未完成时用):

| key | zh-Hans | zh-Hant | en |
|---|---|---|---|
| `account.delete.doneLocalPending` | 账号已删除。本机已购章节的状态会在下次打开 App 时更新。 | 帳號已刪除。本機已購章節的狀態會在下次開啟 App 時更新。 | Your account has been deleted. Purchased chapters on this phone will be updated next time you open the app. |

## 验收

- 后端:新增用例「`app.state.user_store` 缺失时强登录路由返回 500 且不放行」;`cd backend && python -m pytest` 全绿
- iOS 单测:
  - `deactivateAllForAccount` 正常路径:目标行 `isActive == false`
  - 待办标记的写入 → 启动重试成功 → 标记清除
  - 重试失败 → 标记保留
- `python3 tools/build_songti_fonts.py --verify` PASS

## 全局约束(必读)

- 来源:2026-11-27 外部 review;开工前读 `CLAUDE.md` 全文
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全
