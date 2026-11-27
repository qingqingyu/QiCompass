// 日主页模板的确定性常量(古典教科书事实,非译名;译名一律走 terms.json)。
// 天干五合为经典通识(与 backend 引擎同源规则)。这里只做展示推导,
// 不做任何命理判断——喜忌/旺弱仍属 App 引擎与付费内容。
// (十神查表 tenGodFromPair 已删:S03 无消费方,ten-gods 页 slice 需要时
//  从 git 历史恢复,避免无测死代码。)

export const STEM_ORDER = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"];

export const STEM_ELEMENT = {
  甲: "木", 乙: "木", 丙: "火", 丁: "火", 戊: "土",
  己: "土", 庚: "金", 辛: "金", 壬: "水", 癸: "水",
};

// 当令季节(展示用粗口径;精确月令由引擎按节气判定)
export const ELEMENT_SEASON = {
  木: { en: "Spring", zhHant: "春" },
  火: { en: "Summer", zhHant: "夏" },
  土: { en: "Season transitions", zhHant: "四季之交" },
  金: { en: "Autumn", zhHant: "秋" },
  水: { en: "Winter", zhHant: "冬" },
};

// 天干五合(甲己/乙庚/丙辛/丁壬/戊癸)
export const STEM_COMBINE = {
  甲: "己", 乙: "庚", 丙: "辛", 丁: "壬", 戊: "癸",
  己: "甲", 庚: "乙", 辛: "丙", 壬: "丁", 癸: "戊",
};

/** 日主列表里的前驱/后继(环形:癸 → 甲)。 */
export function stemNeighbor(stem, delta) {
  const idx = STEM_ORDER.indexOf(stem);
  if (idx === -1) throw new Error(`stemNeighbor: 非天干输入 ${stem}`);
  return STEM_ORDER[(idx + delta + 10) % 10];
}
