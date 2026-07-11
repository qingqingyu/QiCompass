"""封装层大运对盘用例(YunTest.py 提取,3 条)。

来源:https://github.com/6tail/lunar-python/blob/master/test/YunTest.py
目的:验证 BaziEngine 封装正确构造大运(跳过 index=0 童限)。

关键:
- 本项目强制 sect=1;上游 YunTest 用默认 sect=2
- 起运 Solar 日期对非子时出生用例不受 sect 影响,与上游一致
- 期望 luck_pillars[0] 由 lunar_python 1.4.8 sect=1 实测得出
- 经度 120.0(时区中心),消除经度时差,确保 == 纯 lunar_python sect=1
"""

YUN_CASES = [
    {
        # YunTest.test:女,1981-01-29 23:37(子时),起运 1989-02-18
        "name": "yun_test_female",
        "input": {
            "birth_datetime": "1981-01-29T23:37:00+08:00",
            "gender": "female",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_first_luck": {
            "gan_zhi": "戊子",
            "start_year": 1989,
            "end_year": 1998,
            "start_age": 9,
            "end_age": 18,
        },
        "source": "YunTest.test(gender=0,sect=1 实测)",
    },
    {
        # YunTest.test2:男,农历 2019-12-12 11:22 == 公历 2020-01-06,起运 2020-02-06
        "name": "yun_test2_male",
        "input": {
            "birth_datetime": "2020-01-06T11:22:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_first_luck": {
            "gan_zhi": "丙子",
            "start_year": 2020,
            "end_year": 2029,
            "start_age": 1,
            "end_age": 10,
        },
        "source": "YunTest.test2(gender=1,sect=1 实测)",
    },
    {
        # YunTest.test4:男,2022-03-09 20:51,起运 2030-12-19
        "name": "yun_test4_male",
        "input": {
            "birth_datetime": "2022-03-09T20:51:00+08:00",
            "gender": "male",
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
        },
        "expected_first_luck": {
            "gan_zhi": "甲辰",
            "start_year": 2030,
            "end_year": 2039,
            "start_age": 9,
            "end_age": 18,
        },
        "source": "YunTest.test4(gender=1,sect=1 实测)",
    },
]
