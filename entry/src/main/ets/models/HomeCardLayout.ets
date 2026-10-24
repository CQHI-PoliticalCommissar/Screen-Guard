/**
 * 首页卡片布局模型：完整 9 张卡片的顺序 + 每张的显隐标记。
 *
 * 为什么不用「可见卡片 id 列表」：
 * 只存可见列表时，隐藏某张卡再重新显示，它会被追加到**末尾**，
 * 丢失用户原本设定的位置。存「完整顺序 + visible 标记」才能还原原位。
 *
 * 本文件是纯函数内核：不读单例、不读 prefs、不调 Date.now()，
 * 时间戳/上下文一律由调用方传入，便于 LocalUnit 直接覆盖。
 */
import { HOME_CARD_ITEMS, HomeCardItem } from './HealthTypes';

/** 单张卡片的布局条目：id + 是否在首页显示 */
export interface HomeCardConfigEntry {
  /** 卡片唯一标识 */
  id: string;
  /** 是否显示在首页 */
  visible: boolean;
}

/** 合法卡片 id 集合 */
function validHomeCardIds(): Set<string> {
  const ids: Set<string> = new Set<string>();
  for (let i = 0; i < HOME_CARD_ITEMS.length; i++) {
    ids.add(HOME_CARD_ITEMS[i].id);
  }
  return ids;
}

/** 深拷贝（纯数据拷贝，不共享引用） */
function cloneHomeCardConfig(config: HomeCardConfigEntry[]): HomeCardConfigEntry[] {
  const out: HomeCardConfigEntry[] = [];
  for (let i = 0; i < config.length; i++) {
    const e: HomeCardConfigEntry = config[i];
    if (e && typeof e.id === 'string') {
      const entry: HomeCardConfigEntry = { id: e.id, visible: e.visible === true };
      out.push(entry);
    }
  }
  return out;
}

/**
 * 默认布局：按 defaultOrder 排序，visible 取 defaultVisible。
 * 全部卡片 id 都在，且顺序即默认首页顺序。
 */
export function defaultHomeCardConfig(): HomeCardConfigEntry[] {
  const sorted: HomeCardItem[] = HOME_CARD_ITEMS.slice()
    .sort((a: HomeCardItem, b: HomeCardItem) => a.defaultOrder - b.defaultOrder);
  const out: HomeCardConfigEntry[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const entry: HomeCardConfigEntry = { id: sorted[i].id, visible: sorted[i].defaultVisible };
    out.push(entry);
  }
  return out;
}

/**
 * 归一化：剔除未知 id 与重复 id，缺失的已知 id 按默认顺序补到末尾。
 *
 * prefs 是沙箱内可被手工改写/跨版本迁移的存储，元素形状不可信
 * （与 UsageStatsManager.filterValidScreenOnRecords 同一判据），
 * 故逐个校验 id 类型与合法性。
 */
function normalizeHomeCardConfig(config: HomeCardConfigEntry[]): HomeCardConfigEntry[] {
  const ids: Set<string> = validHomeCardIds();
  const seen: Set<string> = new Set<string>();
  const out: HomeCardConfigEntry[] = [];
  for (let i = 0; i < config.length; i++) {
    const e: HomeCardConfigEntry = config[i];
    if (e && typeof e.id === 'string' && ids.has(e.id) && !seen.has(e.id)) {
      seen.add(e.id);
      const entry: HomeCardConfigEntry = { id: e.id, visible: e.visible === true };
      out.push(entry);
    }
  }
  for (let i = 0; i < HOME_CARD_ITEMS.length; i++) {
    const id: string = HOME_CARD_ITEMS[i].id;
    if (!seen.has(id)) {
      const entry: HomeCardConfigEntry = { id: id, visible: HOME_CARD_ITEMS[i].defaultVisible };
      out.push(entry);
    }
  }
  return out;
}

/**
 * 解析新格式的持久化字符串（`[{id, visible}, ...]`）。
 * 解析失败/为空/结构非法一律返回 null，由调用方回退默认布局。
 */
export function parseHomeCardConfig(raw: string): HomeCardConfigEntry[] | null {
  if (!raw) {
    return null;
  }
  let parsed: HomeCardConfigEntry[] = [];
  try {
    parsed = JSON.parse(raw) as HomeCardConfigEntry[];
  } catch (err) {
    return null;
  }
  if (!Array.isArray(parsed) || parsed.length === 0) {
    return null;
  }
  const normalized: HomeCardConfigEntry[] = normalizeHomeCardConfig(parsed);
  return normalized.length > 0 ? normalized : null;
}

/**
 * 迁移旧格式（`["usage", "trend", ...]`，仅可见列表）到新格式。
 *
 * 旧格式丢失了隐藏卡片的位置，只能尽力还原：把**可见卡片**按旧顺序
 * 填回默认骨架，隐藏卡片留在各自的默认位置。这样迁移后「隐藏→重新显示」
 * 至少会回到一个合理位置，而不是被丢到末尾。
 *
 * 解析失败/空列表返回 null（调用方回退默认布局）。
 */
export function migrateLegacyHomeCardConfig(raw: string): HomeCardConfigEntry[] | null {
  if (!raw) {
    return null;
  }
  let parsed: string[] = [];
  try {
    parsed = JSON.parse(raw) as string[];
  } catch (err) {
    return null;
  }
  if (!Array.isArray(parsed)) {
    return null;
  }
  const ids: Set<string> = validHomeCardIds();
  const visibleOrder: string[] = [];
  for (let i = 0; i < parsed.length; i++) {
    const id: string = parsed[i];
    if (typeof id === 'string' && ids.has(id) && visibleOrder.indexOf(id) < 0) {
      visibleOrder.push(id);
    }
  }
  if (visibleOrder.length === 0) {
    return null;
  }
  const out: HomeCardConfigEntry[] = [];
  let cursor: number = 0;
  for (let i = 0; i < HOME_CARD_ITEMS.length; i++) {
    const id: string = HOME_CARD_ITEMS[i].id;
    if (visibleOrder.indexOf(id) >= 0) {
      const entry: HomeCardConfigEntry = { id: visibleOrder[cursor], visible: true };
      cursor++;
      out.push(entry);
    } else {
      const entry: HomeCardConfigEntry = { id: id, visible: false };
      out.push(entry);
    }
  }
  return out;
}

/** 布局中可见卡片的 id 列表（数组顺序即首页显示顺序） */
export function visibleHomeCardIds(config: HomeCardConfigEntry[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < config.length; i++) {
    const e: HomeCardConfigEntry = config[i];
    if (e && e.visible === true && typeof e.id === 'string') {
      out.push(e.id);
    }
  }
  return out;
}

/** 布局中可见卡片的数量（渲染期用，避免每次都分配数组） */
export function visibleHomeCardCount(config: HomeCardConfigEntry[]): number {
  let n: number = 0;
  for (let i = 0; i < config.length; i++) {
    const e: HomeCardConfigEntry = config[i];
    if (e && e.visible === true) {
      n++;
    }
  }
  return n;
}

/** 某张卡片当前是否显示；不存在返回 false */
export function isHomeCardVisible(config: HomeCardConfigEntry[], id: string): boolean {
  for (let i = 0; i < config.length; i++) {
    const e: HomeCardConfigEntry = config[i];
    if (e && e.id === id) {
      return e.visible === true;
    }
  }
  return false;
}

/**
 * 某张卡片在**可见序列**中的序号（0 起）；不可见或不存在返回 -1。
 * 设置页用它判断"是不是第一张/最后一张"来决定 ↑/↓ 是否淡化。
 */
export function visibleIndexOfHomeCard(config: HomeCardConfigEntry[], id: string): number {
  let n: number = 0;
  for (let i = 0; i < config.length; i++) {
    const e: HomeCardConfigEntry = config[i];
    if (e && e.visible === true) {
      if (e.id === id) {
        return n;
      }
      n++;
    }
  }
  return -1;
}

/**
 * 设置某张卡片的显隐状态。**不改变顺序** —— 隐藏后再显示会回到原位，
 * 这正是不存"仅可见列表"的理由。
 */
export function setHomeCardVisible(config: HomeCardConfigEntry[], id: string,
  visible: boolean): HomeCardConfigEntry[] {
  const out: HomeCardConfigEntry[] = cloneHomeCardConfig(config);
  for (let i = 0; i < out.length; i++) {
    if (out[i].id === id) {
      out[i].visible = visible;
      break;
    }
  }
  return out;
}

/**
 * 在**可见卡片序列**里把某张卡上移/下移一位。
 *
 * 实现要点：找到目标后，交换两张卡在完整列表中的**绝对位置**，
 * 隐藏卡片因此保持原位不动（只交换两张可见卡的槽位），
 * 可见序列的相对顺序则正确地前移/后移一位。
 */
export function moveHomeCardInConfig(config: HomeCardConfigEntry[], id: string,
  offset: number): HomeCardConfigEntry[] {
  const out: HomeCardConfigEntry[] = cloneHomeCardConfig(config);
  let idx: number = -1;
  for (let i = 0; i < out.length; i++) {
    if (out[i].id === id) {
      idx = i;
      break;
    }
  }
  if (idx < 0 || out[idx].visible !== true) {
    return out;
  }
  let target: number = -1;
  if (offset < 0) {
    for (let i = idx - 1; i >= 0; i--) {
      if (out[i].visible === true) {
        target = i;
        break;
      }
    }
  } else {
    for (let i = idx + 1; i < out.length; i++) {
      if (out[i].visible === true) {
        target = i;
        break;
      }
    }
  }
  if (target < 0) {
    return out;
  }
  const tmp: HomeCardConfigEntry = out[idx];
  out[idx] = out[target];
  out[target] = tmp;
  return out;
}
