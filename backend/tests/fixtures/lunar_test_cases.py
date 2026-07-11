"""库层对盘用例(LunarTest.py 提取,20 条)。

来源:https://github.com/6tail/lunar-python/blob/master/test/LunarTest.py
目的:验证 lunar_python 1.4.8 与上游测试期望一致(库层一致性)。

每条用例:
- build: 构造对象 (类名, 方法名, 参数元组)
- checks: 方法链 + 期望值列表(方法链以 obj. 开头,白名单字符校验)
"""

LUNAR_CASES = [
    {
        "name": "test1",
        "build": ("Solar", "fromYmdHms", (100, 1, 1, 12, 0)),
        "checks": [("obj.getLunar().toString()", "九九年腊月初二")],
    },
    {
        "name": "test2",
        "build": ("Solar", "fromYmdHms", (3218, 12, 31, 12, 0)),
        "checks": [("obj.getLunar().toString()", "三二一八年冬月廿二")],
    },
    {
        "name": "test3",
        "build": ("Lunar", "fromYmdHms", (5, 1, 6, 12, 0)),
        "checks": [("obj.getSolar().toString()", "0005-02-03")],
    },
    {
        "name": "test4",
        "build": ("Lunar", "fromYmdHms", (9997, 12, 21, 12, 0)),
        "checks": [("obj.getSolar().toString()", "9998-01-11")],
    },
    {
        "name": "test7",
        "build": ("Lunar", "fromYmdHms", (2020, -4, 2, 13, 0)),
        "checks": [
            ("obj.toString()", "二〇二〇年闰四月初二"),
            ("obj.getSolar().toString()", "2020-05-24"),
        ],
    },
    {
        "name": "test13",
        "build": ("Solar", "fromYmdHms", (1582, 10, 4, 12, 0)),
        "checks": [("obj.getLunar().toString()", "一五八二年九月十八")],
    },
    {
        "name": "test14",
        "build": ("Solar", "fromYmdHms", (1582, 10, 15, 12, 0)),
        "checks": [("obj.getLunar().toString()", "一五八二年九月十九")],
    },
    {
        "name": "test17",
        "build": ("Lunar", "fromYmdHms", (2019, 12, 12, 11, 22)),
        "checks": [("obj.getSolar().toString()", "2020-01-06")],
    },
    {
        "name": "test18",
        "build": ("Lunar", "fromYmd", (2021, 12, 29)),
        "checks": [("obj.getFestivals()[0]", "除夕")],
    },
    {
        "name": "test19",
        "build": ("Lunar", "fromYmd", (2020, 12, 30)),
        "checks": [("obj.getFestivals()[0]", "除夕")],
    },
    {
        "name": "test21",
        "build": ("Solar", "fromYmd", (2022, 1, 31)),
        "checks": [("obj.getLunar().getFestivals()[0]", "除夕")],
    },
    {
        "name": "test22",
        "build": ("Lunar", "fromYmd", (2033, -11, 1)),
        "checks": [("obj.getSolar().toYmd()", "2033-12-22")],
    },
    {
        "name": "test25",
        "build": ("Solar", "fromYmdHms", (2021, 6, 7, 21, 18)),
        "checks": [("obj.getLunar().toString()", "二〇二一年四月廿七")],
    },
    {
        "name": "test26",
        "build": ("Lunar", "fromYmdHms", (2021, 6, 7, 21, 18)),
        "checks": [("obj.getSolar().toString()", "2021-07-16")],
    },
    {
        "name": "test27",
        "build": ("Solar", "fromYmd", (1989, 4, 28)),
        "checks": [("obj.getLunar().getDay()", 23)],
    },
    {
        "name": "test28",
        "build": ("Solar", "fromYmd", (1990, 10, 8)),
        "checks": [("obj.getLunar().getMonthInGanZhiExact()", "乙酉")],
    },
    {
        "name": "test29",
        "build": ("Solar", "fromYmd", (1990, 10, 9)),
        "checks": [("obj.getLunar().getMonthInGanZhiExact()", "丙戌")],
    },
    {
        "name": "test34",
        "build": ("Lunar", "fromYmd", (37, -12, 1)),
        "checks": [("obj.getMonthInChinese()", "闰腊")],
    },
    {
        "name": "test37",
        "build": ("Solar", "fromYmd", (7013, 12, 24)),
        "checks": [("obj.getLunar().toString()", "七〇一三年闰冬月初四")],
    },
    {
        "name": "test41",
        "build": ("Solar", "fromYmd", (4, 2, 10)),
        "checks": [("obj.getLunar().getYearShengXiao()", "鼠")],
    },
]
