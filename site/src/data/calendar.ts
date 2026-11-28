// calendar.json 消费层(S04):类型 + 今日查找 + 双语格式化。
// 数据由 tools/export_site_calendar.py 构建期生成(backend lunar_python,
// setSect(1),锚定每日 12:00 +08:00);本文件只做展示格式化,禁止任何历法计算。

import raw from "./calendar.json";

export interface CalendarDay {
  date: string; // ISO yyyy-MM-dd
  y: string; // 年柱干支
  m: string; // 月柱干支
  d: string; // 日柱干支
  lunarM: number; // 阴历月,负数 = 闰月
  lunarD: number; // 阴历日 1-30
  jieqi: string; // 当前节气(中文)
  jieqiEn: string;
  nextJieqi: string;
  nextJieqiEn: string;
  nextDate: string; // 下一节气日期 ISO
}

export interface JiaziEntry {
  i: number; // 1-60
  gz: string; // 干支两字
  en: string; // "Ren Yin"(terms.json 罗马化拼接)
  elS: string; // 天干五行,global.css .el-* 类名
  elB: string; // 地支五行
  nayin: string; // 纳音(中文,terms.json 键)
  nayinEn: string;
  nayinHant: string; // 纳音繁体(zh-hant 页展示)
}

const data = raw as { buildDay: string; days: CalendarDay[]; jiazi: JiaziEntry[] };

if (!Array.isArray(data.days) || data.days.length === 0) {
  throw new Error("calendar.json days 为空——先跑 tools/export_site_calendar.py");
}
if (!Array.isArray(data.jiazi) || data.jiazi.length !== 60) {
  throw new Error(`calendar.json jiazi 应为 60 条,实得 ${data.jiazi.length}`);
}

export const buildDay: string = data.buildDay;
export const days: CalendarDay[] = data.days;
export const jiazi: JiaziEntry[] = data.jiazi;

/** 今日条数据;buildDay 不在窗口内 = 生成器坏了,fail-loud 不静默。 */
export function todayEntry(): CalendarDay {
  const hit = days.find((x) => x.date === buildDay);
  if (!hit) {
    throw new Error(`calendar.json buildDay ${buildDay} 不在 days 窗口内,重新导出`);
  }
  return hit;
}

// ---------- 双语格式化(纯展示) ----------

const EN_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "2026-12-07" → "Dec 7" */
export function shortDateEn(iso: string): string {
  const d = new Date(`${iso}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) throw new Error(`非法日期 ${iso}`);
  return `${EN_MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}

/** "2026-11-28" → "28 Nov 2026"(今日条格式,设计稿 home.html 同款) */
export function longDateEn(iso: string): string {
  const d = new Date(`${iso}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) throw new Error(`非法日期 ${iso}`);
  return `${d.getUTCDate()} ${EN_MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

/** "2026-12-07" → "12月7日" */
export function shortDateZh(iso: string): string {
  const d = new Date(`${iso}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) throw new Error(`非法日期 ${iso}`);
  return `${d.getUTCMonth() + 1}月${d.getUTCDate()}日`;
}

const EN_WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const ZH_WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"];

/** "2026-11-28" → "Sat" */
export function weekdayEn(iso: string): string {
  const d = new Date(`${iso}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) throw new Error(`非法日期 ${iso}`);
  return EN_WEEKDAYS[d.getUTCDay()];
}

/** "2026-11-28" → "六"(用于「週六」) */
export function weekdayZh(iso: string): string {
  const d = new Date(`${iso}T12:00:00Z`);
  if (Number.isNaN(d.getTime())) throw new Error(`非法日期 ${iso}`);
  return ZH_WEEKDAYS[d.getUTCDay()];
}

const ORDINALS = ["th", "st", "nd", "rd"];

/** 阴历月英文:负数 = 闰月;10 → "10th month",12 → "12th month" */
export function lunarMonthEn(m: number): string {
  const leap = m < 0;
  const n = Math.abs(m);
  if (n < 1 || n > 12) throw new Error(`阴历月越界 ${m}`);
  // 英语序数:11-13 特例(11th/12th/13th,非 11st/12nd/13rd);其余按个位,
  // 个位 0/4-9 均为 th(ORDINALS[0] 即 "th",4-9 落空 ?? "th")。
  const teens = n % 100;
  const suffix = teens >= 11 && teens <= 13 ? "th" : ORDINALS[n % 10] ?? "th";
  return `${leap ? "leap " : ""}${n}${suffix} month`;
}

/** 阴历日英文:16 → "day 16" */
export function lunarDayEn(d: number): string {
  if (d < 1 || d > 30) throw new Error(`阴历日越界 ${d}`);
  return `day ${d}`;
}

const ZH_MONTHS = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"];
const ZH_DAY_TENS = ["初", "十", "廿", "三"];
const ZH_DAY_ONES = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"];

/** 阴历日中文:1 → 初一,16 → 十六,20 → 二十,21 → 廿一,30 → 三十 */
export function lunarDayZh(d: number): string {
  if (d < 1 || d > 30) throw new Error(`阴历日越界 ${d}`);
  if (d === 10) return "初十";
  if (d === 20) return "二十";
  if (d === 30) return "三十";
  const tens = Math.floor((d - 1) / 10); // 0..2
  const ones = (d - 1) % 10; // 0..9
  return `${ZH_DAY_TENS[tens]}${ZH_DAY_ONES[ones]}`;
}

/** 阴历月中文:10 → 十月;-6 → 閏六月 */
export function lunarMonthZh(m: number): string {
  const leap = m < 0;
  const n = Math.abs(m);
  if (n < 1 || n > 12) throw new Error(`阴历月越界 ${m}`);
  return `${leap ? "閏" : ""}${ZH_MONTHS[n - 1]}月`;
}

// 24 节气里简繁字形不同的只有这 5 个(lunar_python 输出简体);
// 其余 19 个简繁同形,原样返回。
const JIEQI_HANT: Record<string, string> = {
  惊蛰: "驚蟄",
  谷雨: "穀雨",
  小满: "小滿",
  芒种: "芒種",
  处暑: "處暑",
};

/** 节气繁体:惊蛰 → 驚蟄;同形节气原样返回 */
export function jieqiHant(j: string): string {
  return JIEQI_HANT[j] ?? j;
}
