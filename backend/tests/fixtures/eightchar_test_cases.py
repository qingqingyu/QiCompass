"""封装层四柱对盘用例(EightCharTest.py 提取,7 条)。

来源:https://github.com/6tail/lunar-python/blob/master/test/EightCharTest.py
目的:验证 BaziEngine 封装正确调用 lunar_python 并结构化输出四柱。

关键:
- 经度统一 120.0(东八区中心),消除经度时差,只留 EoT 均时差
- EoT ±16 分钟,非时辰边界用例不跨桶 → 结果 == 纯 lunar_python sect=1
- test10/test11 是子时 23:30,sect=1 下日柱=次日(上游 sect=2 是当日,差异符合产品决策)
- 期望值由 lunar_python 1.4.8 sect=1 实测得出(非抄上游,因为 sect 不同)
"""

EIGHTCHAR_CASES = [
    {
        "name": "test_gan_zhi",
        "input": {
            "birth_datetime": "2005-12-23T08:37:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_pillars": {
            "year": "乙酉", "month": "戊子", "day": "辛巳", "hour": "壬辰",
        },
        "source": "EightCharTest.test_gan_zhi",
    },
    {
        "name": "test7",
        "input": {
            "birth_datetime": "2022-08-28T01:50:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_pillars": {
            "year": "壬寅", "month": "戊申", "day": "癸丑", "hour": "癸丑",
        },
        "source": "EightCharTest.test7",
    },
    {
        # test8 农历 2022-8-2 == 公历 2022-8-28,与 test7 同
        "name": "test8_lunar_eq_solar",
        "input": {
            "birth_datetime": "2022-08-28T01:50:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_pillars": {
            "year": "壬寅", "month": "戊申", "day": "癸丑", "hour": "癸丑",
        },
        "source": "EightCharTest.test8(农历→公历等价)",
    },
    {
        "name": "test9_fromDate",
        "input": {
            "birth_datetime": "2022-08-28T01:50:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_pillars": {
            "year": "壬寅", "month": "戊申", "day": "癸丑", "hour": "癸丑",
        },
        "source": "EightCharTest.test9",
    },
    {
        # 子时 23:30 —— sect=1 下日柱=次日辛丑(上游 sect=2 是当日庚子)
        "name": "test10_zi_hour_sect1",
        "input": {
            "birth_datetime": "1988-02-15T23:30:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_pillars": {
            "year": "戊辰", "month": "甲寅", "day": "辛丑", "hour": "戊子",
        },
        "source": "EightCharTest.test10(sect=1 验证:23:00 换日→次日日柱)",
    },
    {
        # test11 农历 1987-12-28 == 公历 1988-2-15,与 test10 同
        "name": "test11_lunar_zi_hour_sect1",
        "input": {
            "birth_datetime": "1988-02-15T23:30:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_pillars": {
            "year": "戊辰", "month": "甲寅", "day": "辛丑", "hour": "戊子",
        },
        "source": "EightCharTest.test11(农历→公历等价,sect=1)",
    },
    {
        "name": "test13",
        "input": {
            "birth_datetime": "1991-05-18T03:37:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_pillars": {
            "year": "辛未", "month": "癸巳", "day": "戊子", "hour": "甲寅",
        },
        "source": "EightCharTest.test13(农历 1991-4-5 → 公历 1991-5-18)",
    },
]
