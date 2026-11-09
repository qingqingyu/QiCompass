"""分模块模型路由(2026-11-09 立项,机制先行路由表留空)。

module → AIClient 静态映射。**无 fallback**(ADR-0010:换模型=换一批生成
质量,不自动发生;路由是部署级静态决策,不是故障切换)。

设计要点(见计划档案与探查结论):
- 挂载位置 = app.state.ai_client(唯一挂载点,测试换 Mock 即旁路全层——
  仓库测试直换 state 属性、无 dependency_overrides,resolver 对非 router
  对象原样透传是零破坏的关键)
- provider/model 属性 = 默认路由身份:启动日志与 /api/health(iOS 消费,
  形状不变)读单一身份;各路真实身份经 resolve_ai_client 按模块取
- translate 生成调用带 module="translate:{源模块}" 前缀(仅监控用,
  见 interpret_translate 的 ai_client.interpret 调用)——client_for 剥
  前缀按源模块路由,长章翻译自动跟长章路由
- 缓存键十维含 provider/model(ADR-0009):路由模块自动获得独立缓存行,
  老行不孤儿化;链走查「变体行全收集」机制本就依赖多模型行共存
"""

from __future__ import annotations

from .client import AIClient

# translate 调用的 module 前缀(与 interpret.py 生成调用约定一致)
_TRANSLATE_PREFIX = "translate:"


class AIClientRouter:
    """module → AIClient 静态路由器。

    Args:
        default: 默认路由(未命中模块走此路;provider/model 属性亦取此路
                 身份,供启动日志与 /api/health 单一身份展示)
        routes: 模块名 → 路由 client 精确映射(启动期已校验模块名合法与
                无重复分配,本类不做二次校验)
    """

    def __init__(self, default: AIClient, routes: dict[str, AIClient]):
        self._default = default
        self._routes = dict(routes)

    @property
    def provider(self) -> str:
        """默认路由身份(单一展示口径,非按模块)。"""
        return self._default.provider

    @property
    def model(self) -> str:
        """默认路由身份(单一展示口径,非按模块)。"""
        return self._default.model

    @property
    def default(self) -> AIClient:
        return self._default

    @property
    def routes(self) -> dict[str, AIClient]:
        return dict(self._routes)

    def client_for(self, module: str) -> AIClient:
        """按模块取路由 client。

        - "translate:{m}" 剥前缀按 m 查表(翻译跟源模块路由)
        - 精确命中 routes → 对应 client;否则默认路由(不猜、不降级)
        """
        key = module
        if module.startswith(_TRANSLATE_PREFIX):
            key = module[len(_TRANSLATE_PREFIX):]
        return self._routes.get(key, self._default)


def resolve_ai_client(
    app_client: AIClient | AIClientRouter, module: str,
) -> AIClient:
    """入口解析:Router → 按模块路由;非 Router(含测试 Mock)原样透传。

    这是端点入口的唯一取用方式——_prepare_prompt_and_key 的 CacheKey
    身份、生成调用、响应身份全部吃 resolved 对象,保证三者一致。
    """
    if isinstance(app_client, AIClientRouter):
        return app_client.client_for(module)
    return app_client
