"""T8 手测对话 v2(2026-11-23)——产线忠实脚手架,全程落盘。

与首轮(2026-11-22 手搓上下文)的差异:
- 真实排盘:BaziEngine.calculate(1990-05-15 10:30 男 上海)取真实四柱/日主/喜忌
- 真实今日运势:compute_daily_fortune(target_date=今天)
- 上下文:与 iOS PromptContextBuilder.buildDailyFortune **逐字段同款格式**(17 字段;
  含其写死的中文:元素转中文、「时/冲/无」、「、」分隔)。问事端点不做
  translate_context,en 模板里填的就是这些值(其中 12 个是中文值,day_master_element /
  day_master_strength 是英文 key;时辰条与喜忌列表不在 daily_ask 模板里)——与产线一致
- 今日解读:产线 interpret 路径(translate_context + daily_fortune 模板 + LLM)
  取五段,按 iOS DailyInsight.parse 同款口径校验与归一后,用
  DailyAskContext.interpretationText 同款 "\\n" 连接
- 对话上文:产线 _build_conversation(「问：/答：」全角冒号,三语同款);
  第二轮 history 只含第一轮问答(当前反驳不重复进上文,与端点一致)

运行:cd backend && set -a && source .env && set +a && <venv>/python <本文件>
产物:同目录「对话原始输出.json」(全量:上下文/解读/三组对话)+ stdout 可读稿。
同盘同日重跑 = 续跑(复用既有落盘,不重复烧已完成的调用;落盘记录的 prompt 版本与当前
不一致时报错退出、不续跑);换盘或换日 = 整文件覆盖。
本次证据另存为「对话原始输出-2026-11-23.json」,本脚本不会写它。

入库说明(2026-11-23 双 review 后如实追记):
- 路径:产出证据的那次运行里,输出路径是 /tmp 下的临时文件、模板源是绝对路径;入库版
  把这两处改成相对路径常量。落盘原件逐字节复制为「对话原始输出-2026-11-23.json」。
- 原件由两段运行合成。17:18 的首段用的是本脚本的较早版本(已被续跑版覆盖,未留存),
  写入了 meta(键名 ran_at)、zh 解读与 ZH-1 / ZH-2;17:24 的续跑段复用首段落盘,只新生成
  了 en 降级模板与 EN-1。因此:原件 meta 的键名是 ran_at,而本脚本新起一盘时写的是
  started_at;原件里 zh 解读的来源标注(reading_provenance.zh)是续跑时由 main() 里
  「旧落盘补齐」一行回填的,不是首段落盘时记录的。
- 入库版相对 17:24 续跑版的改动如下(均不改变已落盘的证据)。入库版**没有**做过真实
  LLM 运行,只做过不调 LLM 的自检(函数级 + 桩件 main 全流程:首跑 / 续跑 / 版本拒绝 / 换盘
  重跑)——LLM 输出非确定,重跑也得不到同一批回答:
  1. 今日解读与问事按模块各取路由 client(产线同款);续跑版两次调用都取 daily_ask 路由。
  2. 降级模板按语言取 EngineReadingTemplates 的 zh / hant / en 表;续跑版只解析 en 表。
  3. 解读失败分两段归因:只有渲染段(translate_context / render_prompt)的 KeyError 记为
     「产线路径失败」;LLM 调用失败或输出不合五键契约另记一类。续跑版把整条链的
     KeyError 都记成前者。
  4. 五键非空校验 + 仅 headline 归一字面 \\n(iOS / 后端同款);续跑版五段都做归一、
     不校验非空(本次原件其余四段无换行,结果相同)。
  5. 围栏剥离改用产线 _strip_code_fences(精确镜像 iOS 算法);续跑版是自写正则,只在
     LLM 违约带围栏时才有差异。
  6. meta 新起时增记两个模块的 provider / model;原件无此字段。
  7. stdout 的今日解读标题按 reading_provenance 打印;续跑版对降级模板也印「产线路径」。
  8. 读落盘与读模板源文件改用 with 打开;llm() docstring 的「指数退避」更正为线性退避
     (行为未变:15 / 30 / 45 / 60 秒)。
  9. save() 改为「写临时文件 + os.replace 原子替换」——续跑版直接以 "w" 打开目标文件,
     崩溃落在 dump 中间会把唯一一份证据写成半截 JSON。
  10. 续跑前置校验:meta 里记录的两个 prompt_version 与当前 PROMPT_VERSIONS 不一致即
      显式报错退出(续跑版不校验,模板 bump 后续跑会静默混用版本、meta 仍记旧版本号)。
      产出本次证据的两段运行版本一致(daily_ask v2 / daily_fortune v6)。
"""

import asyncio
import json
import os
import re
import sys
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, ".")

from app.ai.prompts import PROMPT_VERSIONS, render_prompt
from app.ai.router import resolve_ai_client
from app.api.daily_ask import _FRESH_NOTE, _build_conversation, _parse_daily_ask_output
from app.api.interpret import _strip_code_fences
from app.engine.bazi_engine import BaziEngine
from app.engine.daily_fortune import compute_daily_fortune
from app.engine.term_translations import translate_context
from app.errors import AIProviderError
from app.main import _build_ai_client
from app.models.daily_ask import DailyAskTurn
from app.models.daily_fortune import ChartPayload, PillarRef

# iOS PromptContextBuilder.elementToChinese 同款
GAN_ELEMENT_ZH = {"甲": "木", "乙": "木", "丙": "火", "丁": "火", "戊": "土",
                  "己": "土", "庚": "金", "辛": "金", "壬": "水", "癸": "水"}
ZHI_ELEMENT_ZH = {"子": "水", "亥": "水", "寅": "木", "卯": "木", "巳": "火",
                  "午": "火", "申": "金", "酉": "金",
                  "辰": "土", "戌": "土", "丑": "土", "未": "土"}

BIRTH = datetime(1990, 5, 15, 10, 30, 0, tzinfo=ZoneInfo("Asia/Shanghai"))
GENDER = "male"
LONGITUDE = 121.47

DIALOGUES = [
    ("zh", "ZH-1", "今天适合去谈判吗?",
     "这完全不是我现在的情况,我最近明明很顺,根本没什么压力,你说的那些压力在哪?"),
    ("zh", "ZH-2", "今天适合提离职吗?",
     "你说得不准,我现在工作挺好的,没有你说的那些阻滞,别再按那个说法答了。"),
    ("en", "EN-1", "Should I have a difficult conversation with my manager today?",
     "This doesn't match my situation at all — things are actually going "
     "smoothly for me, there's no pressure like you described."),
]


def build_context(result: dict, fortune, business_date: date) -> dict:
    """镜像 iOS PromptContextBuilder.buildDailyFortune(字段与格式逐项对齐)。"""
    pillars = result["pillars"]
    day_stem, day_branch = fortune.day_pillar[0], fortune.day_pillar[-1]
    if fortune.day_chong:
        targets = ("" if not fortune.day_chong_targets
                   else "(冲" + "、".join(fortune.day_chong_targets) + ")")
        day_chong_display = f"{fortune.day_chong}{targets}"
    else:
        day_chong_display = "无"
    hour_lines = []
    for hp in fortune.hour_pillars:
        line = f"- {hp.hour}时({hp.time_range}):{hp.pillar} {hp.relation}"
        if hp.chong:
            t = ("" if not hp.chong_targets
                 else "(冲" + "、".join(hp.chong_targets) + ")")
            line += f" 冲{hp.chong}{t}"
        hour_lines.append(line)
    return {
        "day_master": pillars["day"]["gan"],
        "day_master_element": pillars["day"]["gan_element"],
        "day_master_strength": result["day_master_strength"],
        "favorable_elements": ", ".join(result["favorable_elements"]),
        "unfavorable_elements": ", ".join(result["unfavorable_elements"]),
        "date": f"{business_date.year}年{business_date.month}月{business_date.day}日",
        "lunar_date": fortune.lunar_date,
        "day_pillar": fortune.day_pillar,
        "day_stem": day_stem,
        "day_stem_element": GAN_ELEMENT_ZH.get(day_stem, day_stem),
        "day_branch": day_branch,
        "day_branch_element": ZHI_ELEMENT_ZH.get(day_branch, day_branch),
        "day_relation": fortune.day_relation_to_day_master,
        "day_chong": day_chong_display,
        "hour_pillars_with_relations": "\n".join(hour_lines),
        "huangli_yi": "、".join(fortune.huangli_yi),
        "huangli_ji": "、".join(fortune.huangli_ji),
    }


# iOS 降级模板事实源(EngineReadingTemplates):产线每日解读请求失败(如 translate_context
# 处 KeyError → 500)时,iOS .failed 态按当前语言取 zh / hant / en 表作 daily_interpretation。
# 机械解析源文件,不手抄(防转录误差);解析失败显式抛错。
_REPO_ROOT = Path(__file__).resolve().parents[2]  # docs/<证据目录>/本文件
_ENGINE_TEMPLATE_SRC = (
    _REPO_ROOT / "ios/QiCompass/QiCompass/Features/DailyFortune/"
    "DailyInterpretationSection.swift")
_TEMPLATE_TABLE = {"zh": "zh", "zh-hant": "hant", "en": "en"}  # 语言 → Swift 静态表名
_INSIGHT_KEYS = ("headline", "work", "relationships", "energy", "reminder")
# 落盘原件(全量:上下文/解读/三组对话);续跑时同盘同日复用
_OUTPUT_JSON = (
    _REPO_ROOT / "docs/竞品差评对照-T8证据" / "对话原始输出.json")


def engine_template(relation: str, language: str) -> str:
    """按语言机械解析 EngineReadingTemplates 的一格,五段以 "\\n" 连接(iOS joined 同款)。"""
    table_name = _TEMPLATE_TABLE.get(language)
    if table_name is None:
        raise ValueError(f"引擎降级模板无此语言的表: language={language!r}")
    with open(_ENGINE_TEMPLATE_SRC, encoding="utf-8") as f:
        src = f.read()
    start = src.index(f"static let {table_name}: [String: DailyInsight]")
    table = src[start:src.index("\n    ]", start)]  # 止于本表收尾,不越到下一张表
    block_start = table.index(f'"{relation}": .init(')
    block = table[block_start:table.index("),", block_start)]
    fields = []
    for key in _INSIGHT_KEYS:
        m = re.search(rf'{key}: "((?:[^"\\]|\\.)*)"', block)
        if not m:
            raise ValueError(f"引擎降级模板解析失败: language={language!r} "
                             f"relation={relation!r} field={key!r}")
        fields.append(m.group(1))
    return "\n".join(fields)


# 可重试的瞬时错误:z.ai 429 限流 / 经代理的网络断连与超时。
# 其余(4xx 契约错、解析失败等)原样抛——不吞非瞬时错误。
_TRANSIENT_MARKERS = ("限流", "ConnectError", "ReadTimeout", "ConnectTimeout",
                      "ReadError", "RemoteProtocolError")


async def llm(client, prompt: str, module: str) -> str:
    """瞬时错误(限流/网络)线性退避(15/30/45/60 秒)重试,合计至多 5 次;非瞬时错误原样抛。"""
    for attempt in range(5):
        try:
            return await client.interpret(prompt, module=module)
        except AIProviderError as e:
            transient = any(m in str(e) for m in _TRANSIENT_MARKERS)
            if attempt == 4 or not transient:
                raise
            wait = 15 * (attempt + 1)
            print(f"[retry] 瞬时错误退避 {wait}s(attempt {attempt + 1}): "
                  f"{str(e)[:60]}")
            await asyncio.sleep(wait)


class ReadingContractError(ValueError):
    """daily_fortune 输出不合五键契约(五键须为非空字符串)。"""


def reading_prompt(context: dict, language: str) -> str:
    """产线 interpret 路径的渲染段(translate_context → daily_fortune 模板),与
    interpret._prepare_prompt_and_key 同序;术语未注册的 KeyError 原样上抛,由调用方归因。"""
    translated = translate_context(dict(context), language, "daily_fortune")
    return render_prompt("daily_fortune", translated, language=language)


async def daily_reading(client, prompt: str) -> str:
    """产线路径的 LLM 段:取五段,iOS interpretationText 同款 "\\n" 连接。

    解析口径:容忍围栏;五键 strip 后非空(同后端 _validate_daily_fortune_json,比 iOS
    的 isEmpty 略严——产线里后端先拦,用户实际所得以它为准),否则显式抛
    ReadingContractError;只有 headline 的字面 "\\n"(反斜杠 + n)归一为换行(iOS 同款)。
    """
    raw = await llm(client, prompt, "daily_fortune")
    data = json.loads(_strip_code_fences(raw))
    parts = []
    for key in _INSIGHT_KEYS:
        value = data.get(key) if isinstance(data, dict) else None
        if not isinstance(value, str) or not value.strip():
            raise ReadingContractError(
                f"daily_fortune 输出五键残缺或非字符串(缺失/空值: {key})")
        parts.append(value.replace("\\n", "\n") if key == "headline" else value)
    return "\n".join(parts)


async def ask(client, context: dict, interpretation: str, language: str,
              question: str, history: list[DailyAskTurn]) -> dict:
    ctx = dict(context)
    ctx.update({
        "user_question": question,
        "daily_interpretation": interpretation,
        "ask_conversation": _build_conversation(history),
        "ask_mode_note": _FRESH_NOTE,
    })
    prompt = render_prompt("daily_ask", ctx, language=language)
    raw = await llm(client, prompt, "daily_ask")
    return _parse_daily_ask_output(raw)


async def main():
    result = BaziEngine().calculate(
        birth=BIRTH, gender=GENDER, longitude=LONGITUDE,
        zi_hour_rule="zi_next_day", birth_timezone="Asia/Shanghai")
    payload = ChartPayload(
        day_master=result["pillars"]["day"]["gan"],
        day_master_element=result["pillars"]["day"]["gan_element"],
        day_master_strength=result["day_master_strength"],
        favorable_elements=result["favorable_elements"],
        unfavorable_elements=result["unfavorable_elements"],
        four_pillars={
            pos: PillarRef(gan=p["gan"], zhi=p["zhi"])
            for pos, p in result["pillars"].items()},
    )
    today = date.today()
    fortune = compute_daily_fortune(
        chart_hash=result["content_hash"], target_date=today, chart_payload=payload)
    context = build_context(result, fortune, today)

    # 产线同款:按模块各取路由 client(路由表非空时两个模块可以是不同模型)
    router = _build_ai_client()
    reading_client = resolve_ai_client(router, "daily_fortune")
    ask_client = resolve_ai_client(router, "daily_ask")
    # 续跑:同盘同日的既有落盘结果复用(不重复烧已完成的调用)。
    # 版本前置校验:模板 bump 后续跑会静默混用版本(meta 仍记旧版本号),显式报错退出。
    out = None
    try:
        with open(_OUTPUT_JSON, encoding="utf-8") as f:
            cached = json.load(f)
        meta = cached.get("meta", {}) if isinstance(cached, dict) else {}
        if (meta.get("content_hash") == result["content_hash"]
                and meta.get("target_date") == today.isoformat()):
            for key, module in (("prompt_version_daily_ask", "daily_ask"),
                                ("prompt_version_daily_fortune", "daily_fortune")):
                if meta.get(key) != PROMPT_VERSIONS[module]:
                    raise RuntimeError(
                        f"续跑拒绝:落盘 {key}={meta.get(key)} 与当前 "
                        f"PROMPT_VERSIONS['{module}']={PROMPT_VERSIONS[module]} 不一致"
                        "(模板已 bump,混用版本会让证据的版本声明失真;请换文件名重跑)")
            out = cached
            print(f"[resume] 复用既有落盘:readings={list(cached.get('readings', {}))} "
                  f"dialogues={[d['tag'] for d in cached.get('dialogues', [])]}")
    except FileNotFoundError:
        pass
    if out is None:
        out = {
            "meta": {
                "started_at": datetime.now().isoformat(timespec="seconds"),
                "target_date": today.isoformat(),
                "prompt_version_daily_ask": PROMPT_VERSIONS["daily_ask"],
                "prompt_version_daily_fortune": PROMPT_VERSIONS["daily_fortune"],
                "birth": "1990-05-15 10:30 Asia/Shanghai male lon 121.47",
                "content_hash": result["content_hash"],
                "pillars": {pos: p["gan_zhi"] for pos, p in result["pillars"].items()},
                # 模型身份按模块记(续跑旧落盘不回填:首段用的模型无从由本脚本得知)
                "daily_fortune_provider": reading_client.provider,
                "daily_fortune_model": reading_client.model,
                "daily_ask_provider": ask_client.provider,
                "daily_ask_model": ask_client.model,
            },
            "context": context,
            "readings": {},
            "reading_provenance": {},
            "reading_errors": {},
            "dialogues": [],
        }
    readings = out["readings"]
    # 旧落盘(续跑)缺这两个键:补齐。「zh 解读由产线 LLM 路径生成」是对首段运行的既定
    # 事实回填(首段脚本未记录来源),不是本次运行核验出来的——见模块 docstring 入库说明
    provenance = out.setdefault("reading_provenance", {})
    out.setdefault("reading_errors", {})
    if readings.get("zh") and "zh" not in provenance:
        provenance["zh"] = "daily_fortune 模板 + LLM(产线 interpret 路径)"

    def save():
        # 逐次落盘:晚期失败不丢已完成的调用(证据可追溯)。
        # 原子替换:崩溃落在 dump 中间不损坏上一份完整落盘
        tmp = f"{_OUTPUT_JSON}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        os.replace(tmp, _OUTPUT_JSON)

    save()
    for language, tag, q1, q2 in DIALOGUES:
        if not readings.get(language):
            # 两段分别归因,不混记;两段失败都如实落 reading_errors,再按 iOS 降级态同款
            # 用引擎模板作 daily_interpretation(产线用户失败时实际所得)
            try:
                # ① 渲染段:产线术语翻译 / 模板渲染的 KeyError(iOS 收 500 → .failed)
                prompt = reading_prompt(context, language)
                # ② LLM 段:调用失败(重试耗尽)或输出不合五键契约
                readings[language] = await daily_reading(reading_client, prompt)
                out["reading_provenance"][language] = "daily_fortune 模板 + LLM(产线 interpret 路径)"
            except KeyError as e:
                out["reading_errors"][language] = f"KeyError: {e}"
                readings[language] = engine_template(context["day_relation"], language)
                out["reading_provenance"][language] = (
                    "iOS EngineReadingTemplates 降级模板(产线路径失败 → App .failed 态所用)")
                print(f"[reading] {language} 产线渲染段失败,用降级模板:{e}")
            except (AIProviderError, json.JSONDecodeError, ReadingContractError) as e:
                out["reading_errors"][language] = f"{type(e).__name__}: {e}"
                readings[language] = engine_template(context["day_relation"], language)
                out["reading_provenance"][language] = (
                    "iOS EngineReadingTemplates 降级模板(LLM 调用失败或输出不合五键契约 → "
                    "App 降级态所用)")
                print(f"[reading] {language} LLM 段失败,用降级模板:{type(e).__name__}: {e}")
            save()
        interpretation = readings[language]
        existing = next((d for d in out["dialogues"] if d["tag"] == tag), None)
        if existing is not None and "a2" in existing:
            print(f"[resume] 跳过已完成对话 {tag}")
            continue
        record = existing if existing is not None else {
            "tag": tag, "language": language, "q1": q1, "q2": q2}
        if existing is None:
            out["dialogues"].append(record)
        record["a1"] = await ask(ask_client, context, interpretation, language, q1, [])
        save()
        history = [DailyAskTurn(role="user", text=q1),
                   DailyAskTurn(role="ai", text=record["a1"]["answer"])]
        record["a2"] = await ask(ask_client, context, interpretation, language, q2, history)
        save()

    print("=== 上下文(iOS buildDailyFortune 同款)===")
    for k, v in context.items():
        print(f"{k}: {v!r}")
    for lang, text in readings.items():
        print(f"\n=== 今日解读[{lang}]("
              f"{out['reading_provenance'].get(lang, '来源未记录')})===\n{text}")
    for d in out["dialogues"]:
        print(f"\n{'=' * 62}\n[{d['tag']}] 第一轮提问:{d['q1']}\n{'-' * 62}\n"
              f"答:{d['a1']['answer']}\n接问候选:{d['a1']['follow_up_suggestions']}\n"
              f"{'-' * 62}\n[{d['tag']}] 第二轮反驳:{d['q2']}\n{'-' * 62}\n"
              f"答:{d['a2']['answer']}\n接问候选:{d['a2']['follow_up_suggestions']}\n"
              f"{'=' * 62}")
    print("\n已落盘:", _OUTPUT_JSON)


asyncio.run(main())
