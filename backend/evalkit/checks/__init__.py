"""evalkit 判据层。

L1 确定性(deterministic)/ L2 接地(grounding)/ L3 裁判(rubric + judge,
在上级目录)。签名 module-agnostic:(module, parsed_output, engine_result),
二期接老 3 模块(bazi_deep 等)时 runner 不改分支。
"""
