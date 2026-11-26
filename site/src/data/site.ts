// 站点常量与 i18n UI 词条(S01 基础版;术语译名一律等 S02 从 backend 导出,不在这里另起)。

export const SITE = {
  domain: 'https://knowfate.app',
  email: 'hello@knowfate.app',
  /** <title> 后缀与品牌字样,按语言取(规格 README §13) */
  brand: {
    en: { word: 'KNOWFATE', titleSuffix: '| KnowFate', seal: '观', copyright: '© 2026 KnowFate' },
    'zh-hant': { word: '觀命', titleSuffix: '| 觀命 KnowFate', seal: '觀', copyright: '© 2026 觀命 KnowFate' },
  },
} as const;

export type Lang = keyof typeof SITE.brand;

export const LANGS: Lang[] = ['en', 'zh-hant'];

export function isLang(v: string): v is Lang {
  return v === 'en' || v === 'zh-hant';
}

/** en 页面中文用 SC 字体族;zh-hant 页面用 TC */
export function zhFamily(lang: Lang): string {
  return lang === 'en' ? 'zh' : 'tc';
}

/** 从任意 path 剥掉语言前缀 */
export function stripLang(path: string): { lang: Lang; rest: string } {
  const parts = path.replace(/\/+$/, '').split('/').filter(Boolean);
  const first = parts[0];
  if (isLang(first)) {
    return { lang: first, rest: '/' + parts.slice(1).join('/') };
  }
  // 无语言前缀(理论只在 _redirects 前的 / 出现)按默认语言 en
  return { lang: 'en', rest: path };
}

/** 给 rest 加上目标语言前缀;根为 /en */
export function langPath(lang: Lang, rest: string): string {
  const clean = rest.replace(/\/+$/, '');
  return '/' + lang + (clean === '' || clean === '/' ? '' : clean);
}

type UiStrings = {
  nav: { calculator: string; library: string; guides: string; today: string; app: string };
  getTheApp: string;
  /** 未上线灰显占位的悬停提示(Header 导航) */
  comingSoon: string;
  /** 主导航 aria-label(Header <nav>) */
  navAria: string;
  skipToContent: string;
  langSwitch: { current: string; other: string };
  menuLabel: string;
  homeAria: string;
  footer: {
    tagline: string;
    colDayMasters: string;
    colTenGods: string;
    colElements: string;
    colTools: string;
    allDayPillars: string;
    disclaimer: string;
  };
};

export const UI: Record<Lang, UiStrings> = {
  en: {
    nav: { calculator: 'Calculator', library: 'Library', guides: 'Guides', today: 'Today', app: 'The App' },
    getTheApp: 'Get the app',
    comingSoon: 'Coming soon',
    navAria: 'Primary',
    skipToContent: 'Skip to content',
    langSwitch: { current: 'EN', other: '繁' },
    menuLabel: 'Menu',
    homeAria: 'KnowFate home',
    footer: {
      tagline: 'A BaZi (Four Pillars) reference and free calculator. Deterministic charts, careful words — for self-reflection, not prediction.',
      colDayMasters: 'Day Masters',
      colTenGods: 'Ten Gods',
      colElements: 'Elements & Stars',
      colTools: 'Tools & Guides',
      allDayPillars: 'All 60 day pillars',
      disclaimer: 'For entertainment and self-reflection only. No predictions, no promises.',
    },
  },
  'zh-hant': {
    nav: { calculator: '排盤器', library: '辭典', guides: '指南', today: '今日', app: 'App' },
    getTheApp: '取得 App',
    comingSoon: '即將上線',
    navAria: '主選單',
    skipToContent: '跳到主要內容',
    langSwitch: { current: '繁', other: 'EN' },
    menuLabel: '選單',
    homeAria: '觀命 KnowFate 首頁',
    footer: {
      tagline: '八字(四柱)知識站與免費排盤器。確定性排盤,措辭克制——供自我認識,不作預測。',
      colDayMasters: '十日主',
      colTenGods: '十神',
      colElements: '五行與神煞',
      colTools: '工具與指南',
      allDayPillars: '六十甲子日柱',
      disclaimer: '內容僅供娛樂與自我認識參考,不作預測與承諾。',
    },
  },
};

// 上线开关(2026-11-27 外评修复:页头/页脚只链已上线区块,未上线条目灰显
// 不出 <a>——防 S08 最小上线时搜索引擎首抓即撞 404;规格 S04「未发布页面
// 灰色不出链」提前到导航层)。键对齐 NAV.key 与页脚各列;建一批发一批,
// 某区块内容页 + 模板就绪后翻 true 并同步 check_site_content.py 白名单。
export const LAUNCH = {
  calculator: false, library: false, guides: false, today: false, app: false,
  dayMaster: false, tenGods: false, fiveElements: false, stars: false,
  dayPillars: false, tools: false, about: false, privacy: false,
} as const;

/** 页头主导航(hreflang 互指 + 面包屑都以这些路径为骨架)。
 * path 一律存「rest 形态」(不带语言前缀)——langPath(lang, path) 的契约如此,
 * 带前缀的字面量会被二次前缀(曾产出 /en/en/bazi-calculator 全站断链)。 */
export const NAV = [
  { key: 'calculator', path: '/bazi-calculator' },
  { key: 'library', path: '/library' },
  { key: 'guides', path: '/guides' },
  { key: 'today', path: '/today' },
  { key: 'app', path: '/app' },
] as const;
