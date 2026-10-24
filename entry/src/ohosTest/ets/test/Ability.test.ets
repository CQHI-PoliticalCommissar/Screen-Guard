import { describe, it, expect } from '@ohos/hypium';
import {
  HealthStatus,
  STATUS_COLOR_MAP,
  getDayStartTimestamp,
  formatDate
} from '../../../main/ets/models/HealthTypes';
import {
  FocusModeManager,
  FocusBackupData,
  POMODORO_DURATION_MINUTES,
  SHORT_BREAK_MINUTES,
  LONG_BREAK_MINUTES
} from '../../../main/ets/managers/FocusModeManager';
import { NotificationType } from '../../../main/ets/managers/NotificationRepostService';
import { DataBackupManager } from '../../../main/ets/managers/DataBackupManager';
import { PersistentNotificationManager } from '../../../main/ets/managers/PersistentNotificationManager';
import { notificationManager } from '@kit.NotificationKit';

/**
 * 结构完整的合法备份原文（各字段类型与 DataBackupManager.isValidBackupData 的要求一致）。
 * 直接用 JSON 文本而非对象字面量：ArkTS 禁止无类型标注的对象字面量。
 */
const VALID_BACKUP_TEXT = '{"version":1,"exportTime":"2026-10-02T00:00:00.000Z",' +
  '"sleepData":{"sleepDurationMinutes":460,"preSleepUsageMinutes":30,"score":82},' +
  '"sleepPreferences":{"sleepGoalMinutes":480,"bedtimeReminderOffsetMinutes":65,' +
  '"enablePreSleepRestriction":true,"preSleepRestrictionMinutes":60},' +
  '"downtimeRule":{"startHour":22,"startMinute":0,"endHour":7,"endMinute":0,' +
  '"restrictedCategories":[],"enabled":true},' +
  '"totalDailyLimitMinutes":180,"todayAccumulatedSeconds":1200,' +
  '"dailyHistory":[{"date":"2026-10-01","totalMinutes":100}],' +
  '"bedtimeConfig":{"hour":23,"minute":0,"enabled":true}}';

// 注意：拼接方式必须是"去掉末尾的 } 再补回去"，不能 replace('}', ...)——
// String.replace 只替换**第一个**匹配，而 VALID_BACKUP_TEXT 里第一个 } 出现在
// sleepData 对象内部（这是本轮首次跑就失败的原因：拼出的 JSON 直接语法错误）。
// 提到模块级是因为 ArkTS 禁止在 describe 回调体内定义函数（arkts-no-nested-funcs）。
function withOptionalFields(optionalJson: string): string {
  return VALID_BACKUP_TEXT.substring(0, VALID_BACKUP_TEXT.length - 1) + ',' + optionalJson + '}';
}

/**
 * 结构完整、含 4 组可选字段的合法备份片段（追加在核心字段之后）。
 */
const OPTIONAL_FIELDS = '"focusData":{"history":[],"totalPoints":0,"currentStreak":0,' +
  '"focusDurationMinutes":25},"achievementData":{"focus_novice":{"unlocked":true,"unlockedAt":1}},' +
  '"unlockData":{"records":[{"timestamp":1,"hour":9}],' +
  '"dailyHistory":[{"date":"2026-10-01","unlockCount":1,"hourlyCounts":[0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]},' +
  '"reminderData":{"sedentary":{"enabled":true,"intervalMinutes":45,"startHour":9,"startMinute":0,' +
  '"endHour":21,"endMinute":0,"weekdays":[0,1,2,3,4,5,6]},' +
  '"eye":{"enabled":false,"intervalMinutes":20,"startHour":9,"startMinute":0,"endHour":21,"endMinute":0,' +
  '"weekdays":[0,1,2,3,4,5,6]},"water":{"enabled":true,"intervalMinutes":60,"startHour":9,"startMinute":0,' +
  '"endHour":21,"endMinute":0,"weekdays":[0,1,2,3,4,5,6]},"customItems":[]}';

export default function abilityTest() {
  describe('HealthTypes', () => {
    it('formatDate_pads_values', 0, () => {
      expect(formatDate(new Date(2026, 0, 5))).assertEqual('2026-01-05');
      expect(formatDate(new Date(2026, 9, 10))).assertEqual('2026-10-10');
    });

    it('getDayStartTimestamp_returns_midnight', 0, () => {
      const d = new Date(getDayStartTimestamp('2026-08-03'));
      expect(d.getHours()).assertEqual(0);
      expect(d.getDate()).assertEqual(3);
    });

    it('status_color_map_is_complete', 0, () => {
      expect(Object.keys(STATUS_COLOR_MAP).length).assertEqual(3);
      expect(STATUS_COLOR_MAP[HealthStatus.NORMAL].length).assertEqual(7);
      expect(STATUS_COLOR_MAP[HealthStatus.WARNING].length).assertEqual(7);
      expect(STATUS_COLOR_MAP[HealthStatus.EMERGENCY].length).assertEqual(7);
    });
  });

  describe('FocusModeManager', () => {
    it('singleton_returns_same_instance', 0, () => {
      expect(FocusModeManager.getInstance()).assertEqual(FocusModeManager.getInstance());
    });

    it('pomodoro_constants_are_sane', 0, () => {
      expect(POMODORO_DURATION_MINUTES).assertEqual(25);
      expect(SHORT_BREAK_MINUTES).assertEqual(5);
      expect(LONG_BREAK_MINUTES).assertEqual(15);
      expect(LONG_BREAK_MINUTES).assertLarger(SHORT_BREAK_MINUTES);
    });

    it('next_break_is_short_without_completed_sessions', 0, () => {
      const manager = FocusModeManager.getInstance();
      manager.resetCycle();
      expect(manager.getNextBreakType()).assertEqual('short');
    });
  });

  describe('DataBackupManager 畸形备份拒绝', () => {
    it('valid_backup_text_is_accepted', 0, () => {
      expect(DataBackupManager.getInstance().isValidBackupText(VALID_BACKUP_TEXT)).assertTrue();
    });

    it('malformed_backup_text_is_rejected', 0, () => {
      const manager = DataBackupManager.getInstance();
      // 真机曾出现的畸形形态：sleepData/sleepPreferences/downtimeRule/bedtimeConfig 全部退化为字符串或空对象
      expect(manager.isValidBackupText(
        '{"version":1,"totalDailyLimitMinutes":30,"todayAccumulatedSeconds":0,"dailyHistory":[],' +
        '"sleepData":"bad","sleepPreferences":{},"downtimeRule":{},"bedtimeConfig":{}}'
      )).assertFalse();
      // JSON 语法错误（文件被截断）
      expect(manager.isValidBackupText('{"version":1,"dailyHistory":[')).assertFalse();
      expect(manager.isValidBackupText('')).assertFalse();
      // 版本不符：未来版本或字符串版本都不应被当作 v1 恢复
      const wrongVersion = VALID_BACKUP_TEXT.replace('"version":1', '"version":2');
      expect(manager.isValidBackupText(wrongVersion)).assertFalse();
      // 负数累计秒数
      expect(manager.isValidBackupText(VALID_BACKUP_TEXT.replace('"todayAccumulatedSeconds":1200', '"todayAccumulatedSeconds":-1')))
        .assertFalse();
      // dailyHistory 非数组
      expect(manager.isValidBackupText(VALID_BACKUP_TEXT.replace('"dailyHistory":[{"date":"2026-10-01","totalMinutes":100}]', '"dailyHistory":{}')))
        .assertFalse();
      // 时刻字段为字符串（setDowntimeRule 会整体拒收，但入口就该挡住）
      expect(manager.isValidBackupText(VALID_BACKUP_TEXT.replace('"startHour":22', '"startHour":"22"'))).assertFalse();
    });
  });

  describe('DataBackupManager 可选字段校验', () => {
    // 2026-08-06 起新增的 4 组可选字段此前只被真值检查放过：
    // 一个 '"focusData":"hello"' 的备份能过校验并流入 importData，
    // 属性访问得 undefined → 后续算术产出 NaN 并经 JSON.stringify 序列化成 null 落盘续命。
    // 注意：拼接方式见模块级 withOptionalFields（不能用 replace('}')——只替换第一个匹配）。
    it('valid_backup_with_all_optional_fields_is_accepted', 0, () => {
      const manager = DataBackupManager.getInstance();
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS))).assertTrue();
    });

    it('optional_fields_are_optional', 0, () => {
      // 旧备份（BACKUP_VERSION=1 但无这 4 组字段）必须仍可恢复 —— 向后兼容不得破坏
      expect(DataBackupManager.getInstance().isValidBackupText(VALID_BACKUP_TEXT)).assertTrue();
    });

    it('string_typed_optional_fields_are_rejected', 0, () => {
      const manager = DataBackupManager.getInstance();
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace(
        '"focusData":{"history"', '"focusData":"hello"')))).assertFalse();
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace(
        '"achievementData":{"focus_novice":{"unlocked":true,"unlockedAt":1}}',
        '"achievementData":{"focus_novice":{"unlocked":"yes"}}')))).assertFalse();
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace(
        '"unlockData":{"records":[{"timestamp":1,"hour":9}]',
        '"unlockData":{"records":"nope"}')))).assertFalse();
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace(
        '"reminderData":{"sedentary":{"enabled"', '"reminderData":{"sedentary":"x","__y":{"enabled"'))))
        .assertFalse();
    });

    it('malformed_nested_elements_are_rejected', 0, () => {
      const manager = DataBackupManager.getInstance();
      // focusData.history 元素缺字段（completed/interrupted 必须是布尔）
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace('"history":[]',
        '"history":[{"startTime":1,"endTime":2,"durationMinutes":25,"pointsEarned":10}]')))).assertFalse();
      // totalPoints 为字符串
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace(
        '"totalPoints":0', '"totalPoints":"0"')))).assertFalse();
      // unlockData.dailyHistory 的 hourlyCounts 非数组（UsageStatsManager 按 24 长度数组、并按 hour 下标累加）
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace(
        '"hourlyCounts":[0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]',
        '"hourlyCounts":{}')))).assertFalse();
      // reminderData 三条内置配置缺 weekdays（缺省会在归一化时被当空数组，语义已失真）
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace(
        '"intervalMinutes":45,"startHour":9,"startMinute":0,"endHour":21,"endMinute":0,"weekdays":[0,1,2,3,4,5,6]',
        '"intervalMinutes":45,"startHour":9,"startMinute":0,"endHour":21,"endMinute":0"')))).assertFalse();
      // 自定义提醒项的 notificationId 为字符串（撤除时找不到对应常驻通知）
      expect(manager.isValidBackupText(withOptionalFields(OPTIONAL_FIELDS.replace('"customItems":[]',
        '"customItems":[{"id":"a","name":"n","content":"c","intervalMinutes":30,"enabled":true,' +
        '"startHour":9,"startMinute":0,"endHour":21,"endMinute":0,"weekdays":[],"notificationId":"2000"}]'))))
        .assertFalse();
    });
  });

  describe('FocusModeManager 专注时长钳位', () => {
    it('focus_duration_is_clamped_and_nan_keeps_current', 0, () => {
      const manager = FocusModeManager.getInstance();
      // 备份恢复与用户设置两条写入路径都必须钳位；NaN 必须回退当前值而非污染
      const probe: FocusBackupData = manager.exportData();
      const originalDuration = probe.focusDurationMinutes;

      probe.focusDurationMinutes = 9999;
      manager.importData(probe);
      expect(manager.getFocusDurationMinutes()).assertEqual(180);

      probe.focusDurationMinutes = 1;
      manager.importData(probe);
      expect(manager.getFocusDurationMinutes()).assertEqual(5);

      probe.focusDurationMinutes = Number.NaN;
      manager.importData(probe);
      expect(manager.getFocusDurationMinutes()).assertEqual(5);

      manager.setFocusDurationMinutes(Number.NaN);
      expect(manager.getFocusDurationMinutes()).assertEqual(5);

      manager.setFocusDurationMinutes(45.4);
      expect(manager.getFocusDurationMinutes()).assertEqual(45);

      // 还原设备上的真实专注数据，避免用例污染后续人工核验
      probe.focusDurationMinutes = originalDuration;
      manager.importData(probe);
      expect(manager.getFocusDurationMinutes()).assertEqual(originalDuration);
    });
  });

  describe('PersistentNotificationManager 通知 ID 段', () => {
    /**
     * 只断言进程内可观测行为。
     * 「偏好已落盘 + 旧低位 ID 已 cancel」这半段依赖 PreferenceManager.pref，
     * 而它只在 EntryAbility.init(context) 里注入，aa test 拉起的测试进程没有这一步
     * （pref 为 undefined 时读写全部落空），故迁移的落盘侧无法在用例中断言，
     * 只能靠实机「改包重启后通知栏不出现重复常驻」间接确认。
     */
    it('persistent_id_stays_in_high_segment_and_is_reused', 0, async () => {
      if (!notificationManager.isNotificationEnabledSync()) {
        // 通知总开关被系统关闭时 publishPersistent 直接返回 -1，属环境限制而非逻辑缺陷
        return;
      }
      const manager = PersistentNotificationManager.getInstance();
      const first = await manager.publishPersistent('测试通知', 'A');
      expect(first >= 9000000).assertTrue();
      expect(first < 10000000).assertTrue();
      // 同一实例复用同一 ID（跨重启覆盖同一条通知，不产生重复常驻）
      const second = await manager.publishPersistent('测试通知', 'B');
      expect(second).assertEqual(first);

      // 自清理：本用例发布的是 isUnremovable 常驻，不撤下就会永久留在通知栏，
      // 并覆盖掉应用自己的「今日使用时长」常驻条目。顺带清掉同段位的旧遗留。
      await notificationManager.cancel(first);
      const active = await notificationManager.getActiveNotifications();
      for (const req of active) {
        const id = req.id;
        if (id !== undefined && id >= 9000000) {
          await notificationManager.cancel(id);
        }
      }
    });
  });

  describe('NotificationRepostService', () => {
    it('notification_type_ids_are_unique_and_positive', 0, () => {
      const ids: number[] = [
        NotificationType.SEDENTARY,
        NotificationType.EYE,
        NotificationType.WATER,
        NotificationType.BEDTIME,
        NotificationType.DOWNTIME,
        NotificationType.DOWNTIME_ALERT,
        NotificationType.TOTAL_LIMIT_50,
        NotificationType.TOTAL_LIMIT_80,
        NotificationType.TOTAL_LIMIT_100,
        NotificationType.EYE_REST,
        NotificationType.FOCUS,
        NotificationType.CUSTOM_BASE
      ];
      expect(new Set(ids).size).assertEqual(ids.length);
      ids.forEach(id => {
        expect(id).assertLarger(0);
      });
    });
  });
}
