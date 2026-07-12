"""城市 → 经度映射表。

手动整理,不引地理库(遵循 CLAUDE.md「不擅自加依赖」约束)。
查不到 → 抛 CityNotFoundError(不静默用默认值)。
"""

from ..errors import CityNotFoundError, InvalidInputError

# 约 30 个常用城市(中国主要城市 + 部分海外华人聚集地)
CITY_LONGITUDE: dict[str, float] = {
    # 一线 / 新一线
    "北京": 116.41,
    "上海": 121.47,
    "广州": 113.23,
    "深圳": 114.06,
    "成都": 104.07,
    "重庆": 106.55,
    "杭州": 120.16,
    "武汉": 114.30,
    "西安": 108.93,
    "南京": 118.78,
    "天津": 117.20,
    "苏州": 120.62,
    "长沙": 112.93,
    "郑州": 113.62,
    "青岛": 120.38,
    # 省会 / 重要城市
    "沈阳": 123.43,
    "哈尔滨": 126.65,
    "长春": 125.32,
    "大连": 121.62,
    "济南": 117.00,
    "福州": 119.30,
    "厦门": 118.09,
    "合肥": 117.27,
    "南昌": 115.89,
    "太原": 112.55,
    "石家庄": 114.51,
    "呼和浩特": 111.75,
    "兰州": 103.83,
    "西宁": 101.78,
    "银川": 106.23,
    "乌鲁木齐": 87.62,
    "拉萨": 91.13,
    "昆明": 102.83,
    "贵阳": 106.71,
    "南宁": 108.37,
    "海口": 110.32,
    "三亚": 109.51,
    "台北": 121.56,
    "香港": 114.17,
    "澳门": 113.55,
    # 海外
    "新加坡": 103.85,
    "东京": 139.69,
    "首尔": 126.99,
    "纽约": -74.01,
    "旧金山": -122.42,
    "洛杉矶": -118.24,
    "温哥华": -123.12,
    "多伦多": -79.38,
    "伦敦": -0.13,
    "巴黎": 2.35,
    "悉尼": 151.21,
    "墨尔本": 144.96,
}


def resolve_longitude(city: str | None, longitude: float | None) -> float:
    """解析经度:longitude 优先级高于 city;二者至少传一个。

    Args:
        city: 城市名(中文)
        longitude: 经度(十进制度,东正西负)

    Returns:
        经度数值

    Raises:
        CityNotFoundError: city 非空但查表失败
        InvalidInputError: city 和 longitude 都为空
    """
    if longitude is not None:
        return longitude
    if city is None:
        raise InvalidInputError("city 和 longitude 至少传一个")
    if city not in CITY_LONGITUDE:
        raise CityNotFoundError(city)
    return CITY_LONGITUDE[city]
