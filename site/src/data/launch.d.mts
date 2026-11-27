// launch.mjs 的类型声明(裸 Node 与 Vite 共用一份实现,TS 侧经此拿到类型;
// 匹配规则的完整说明见 launch.mjs docstring——两侧改动须同步)。

export interface LaunchSection {
  enabled: boolean;
  prefixes: string[];
}

export type LaunchSections = Record<string, LaunchSection>;

export function matchSection(sections: LaunchSections, rest: string): boolean;
