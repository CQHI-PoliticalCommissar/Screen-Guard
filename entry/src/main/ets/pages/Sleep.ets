import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HealthStateManager } from '../managers/HealthStateManager';
import { SleepData, WEEKDAY_FULL_LABELS, formatHourMinute } from '../models/HealthTypes';
import { showToastSafe } from '../models/UiUtils';
import { GlassCard } from '../components/GlassCard';
import { AmbientLight } from '../components/AmbientLight';
import { curves } from '@kit.ArkUI';
import { PreferenceManager } from '../managers/PreferenceManager';
import { AppLifecycleTracker } from '../managers/AppLifecycleTracker';
import {
  MIN_SLEEP_DURATION_MINUTES,
  MAX_SLEEP_DURATION_MINUTES,
  MIN_PRE_SLEEP_USAGE_MINUTES,
  MAX_PRE_SLEEP_USAGE_MINUTES
, HealthSyncOutcome } from '../managers/SleepManager';
import {
  IOS26_WHITE,
  ThemeColor
} from '../components/iOS26Theme';

const LAST_SYNC_TIME_PREFS_KEY = 'last_health_sync_time';

/** 两位补零；提为模块级函数，供formatDateTime 等复用，避免每次调用新建闭包 */
function pad2(n: number): string {
  return n.toString().padStart(2, '0');
}

/**
 * 睡前屏幕 - 作为 HdsTabs 的 TabContent 组件
 * 沉浸光感液态玻璃风格，与首页统一设计语言
 */
@Component
export struct Sleep {
  /** 用户强调色（跟随设置页「强调色」选择，全应用一致） */
  @StorageLink('accentColorHex') accentColorHex: string = '#0066CC';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @State sleepData: SleepData = HealthStateManager.getInstance().sleepManager.getSleepData();
  /**
   * 是否已有可评分的睡眠数据。
   *
   * 必须是 @State：`hasSleepData` 读的是 manager 内的字段（不参与 ArkUI 依赖追踪），
   * 若不落成状态，用户同步/手填数据后"暂无数据"文案不会消失。值由 refreshData 维护。
   */
  @State hasSleepData: boolean = HealthStateManager.getInstance().sleepManager.hasSleepData();
  /**
   * 睡眠目标（分钟）。
   *
   * ⚠️ 必须是 @State：`getSleepGoalMinutes()` 读的是 manager 字段，不参与 ArkUI 依赖追踪。
   * 2026-10-19 实机复现：设置页把目标 6小时→7小时 后，同屏「改善建议」已按 7 小时生成
   * （它由 refreshData 重算的 @State advices 驱动），而「目标 6小时」文案与进度条纹丝不动
   * ——因为 Tabs 会保留已挂载的页面，切回睡前 Tab 不重建，build 期直接读 manager 的节点
   * 永远不会被标脏。属「UI 不刷新」家族第 7 例（前 6 例：ForEach key ×4、@Builder 参数 ×2）。
   */
  @State sleepGoalMinutes: number = HealthStateManager.getInstance().sleepManager.getSleepGoalMinutes();
  /**
   * 父级 Index 在切换到「睡前」Tab 时自增的刷新信号。
   *
   * 为什么需要它：HdsTabs 会保留已挂载的 Tab 页面，切 Tab **不重建组件**，
   * `onPageShow` 也不会触发（2026-10-19 实机：设置页把睡眠目标 6→7 小时后切回本页，
   * 「目标 7小时」与进度条仍是旧值，直到 30s 可见期轮询才更新）。
   * 页面 build 期直接读 manager 字段不参与 ArkUI 依赖追踪，故由父级用 @Prop
   * 推一个变化信号进来，在 @Watch 内立即重拉数据，不必等轮询。
   */
  @Prop @Watch('onTabActivated') tabActivation: number = 0;
  @State advices: string[] = [];
  @State inputPreSleepMinutes: string = '';
  @State inputSleepMinutes: string = '';
  @State isSyncingHealth: boolean = false;
  @State lastSyncTimeText: string = '';
  @State todayDateText: string = '';

  // 入场动画状态
  @State scoreCardOpacity: number = 0;
  @State scoreCardY: number = 30;
  @State metricsCardOpacity: number = 0;
  @State metricsCardY: number = 30;
  @State adviceCardOpacity: number = 0;
  @State adviceCardY: number = 30;
  @State formCardOpacity: number = 0;
  @State formCardY: number = 30;

  // 按压状态 - 由 GlassCard 内部管理

  private sleepManager = HealthStateManager.getInstance().sleepManager;
  /** 入场动画定时器句柄（页面消失时统一清理，避免重复进入导致动画叠加打架） */
  private entranceTimerIds: number[] = [];

  /**
   * 可见期数据刷新定时器。
   * getSleepData() 已改为返回副本（避免页面持有 manager 活对象），
   * 因此跨日归零等 manager 侧变化不会自动反映到本页，需要周期性重拉。
   * 30s 与后台聚合节奏一致，开销可忽略。
   */
  private refreshTimerId: number = -1;

  /** 用户是否正在手动编辑输入框：编辑期间不得回填，避免打断输入 */
  private isEditingInputs: boolean = false;

  aboutToAppear(): void {
    this.sleepManager.updatePreSleepUsageFromRecords();
    this.refreshData();
    this.todayDateText = this.formatDate(new Date());
    this.loadLastSyncTime();

    this.startRefreshTimer();

    this.entranceTimerIds.push(setTimeout(() => {
      this.scoreCardOpacity = 1;
      this.scoreCardY = 0;
    }, 100));

    this.entranceTimerIds.push(setTimeout(() => {
      this.metricsCardOpacity = 1;
      this.metricsCardY = 0;
    }, 200));

    this.entranceTimerIds.push(setTimeout(() => {
      this.adviceCardOpacity = 1;
      this.adviceCardY = 0;
    }, 300));

    this.entranceTimerIds.push(setTimeout(() => {
      this.formCardOpacity = 1;
      this.formCardY = 0;
    }, 400));
  }

  /** 页面每次显示时立即刷新一次（切回本 Tab 时先补一次，不必等轮询） */
  onPageShow(): void {
    this.sleepManager.updatePreSleepUsageFromRecords();
    this.refreshData();
    this.startRefreshTimer();
  }

  /**
   * 父级切换到本 Tab 时的刷新入口（@Prop tabActivation 变化触发）。
   * 保留用户正在编辑的输入框内容，只重拉卡片数据与睡眠目标。
   */
  private onTabActivated(): void {
    this.sleepManager.updatePreSleepUsageFromRecords();
    this.refreshData(this.isEditingInputs);
    this.startRefreshTimer();
    hilog.info(0x0000, 'SleepPage', '%{public}s',
      'tab activated refresh, goal=' + this.sleepGoalMinutes);
  }

  aboutToDisappear(): void {
    for (let i = 0; i < this.entranceTimerIds.length; i++) {
      clearTimeout(this.entranceTimerIds[i]);
    }
    this.entranceTimerIds = [];
    if (this.refreshTimerId >= 0) {
      clearInterval(this.refreshTimerId);
      this.refreshTimerId = -1;
    }
  }

  /** 启动可见期轮询；已存在则不重复创建 */
  private startRefreshTimer(): void {
    if (this.refreshTimerId >= 0) {
      return;
    }
    this.refreshTimerId = setInterval(() => {
      // 退到后台即跳过：本轮要跑 updatePreSleepUsageFromRecords（遍历全部亮屏记录）
      // + generateAdvice，纯后台空耗；回前台后下一周期自动恢复（与 Index 同策略）
      if (!AppLifecycleTracker.getInstance().isForeground()) {
        return;
      }
      // 用户正在输入时不碰输入框，但卡片数据仍需同步（跨日归零 / 记录更新）
      const editing: boolean = this.isEditingInputs;
      this.sleepManager.updatePreSleepUsageFromRecords();
      this.refreshData(editing);
    }, 30000);
  }

  /** 读取上次健康同步时间的显示文案，无记录则显示"尚未同步" */
  private loadLastSyncTime(): void {
    try {
      const stored = PreferenceManager.getInstance().getString(LAST_SYNC_TIME_PREFS_KEY, '');
      if (stored) {
        this.lastSyncTimeText = stored;
      } else {
        this.lastSyncTimeText = '尚未同步';
      }
    } catch (err) {
      this.lastSyncTimeText = '尚未同步';
    }
  }

  /** 保存本次同步时间文案到偏好存储（仅记录展示用，失败静默） */
  private saveLastSyncTime(): void {
    const now = new Date();
    const text = this.formatDateTime(now);
    this.lastSyncTimeText = text;
    // setString 是 async，异常会转成 rejected Promise，外层 try/catch 永不执行（假兜底）。
    // 写入失败的真实日志由 PreferenceManager 内部输出，这里不再挂永不触发的 catch。
    PreferenceManager.getInstance().setString(LAST_SYNC_TIME_PREFS_KEY, text);
  }

  /**
   * 比较两份睡眠数据是否在「页面实际渲染的字段」上等价。
   * 用于 30s 可见期轮询的 diff 守卫：数据未变时跳过 @State 赋值，
   * 避免整页（评分环/建议列表/统计文本）无谓重建，与 Index 的
   * isWeeklyTrendEqual/isUnlockInsightsEqual 守卫同一目的。
   */
  private isSleepDataEqual(a: SleepData, b: SleepData): boolean {
    return a.sleepDurationMinutes === b.sleepDurationMinutes &&
      a.preSleepUsageMinutes === b.preSleepUsageMinutes &&
      a.score === b.score &&
      (a.deepSleepMinutes || 0) === (b.deepSleepMinutes || 0) &&
      (a.shallowSleepMinutes || 0) === (b.shallowSleepMinutes || 0) &&
      (a.dreamSleepMinutes || 0) === (b.dreamSleepMinutes || 0);
  }

  /** 比较建议列表是否逐项相同（长度 + 每个元素） */
  private isStringArrayEqual(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 从 SleepManager 拉取最新数据与建议。
   * @param keepInputs 为 true 时不回填手动输入框（用户正在编辑，避免输入被覆盖）
   */
  private refreshData(keepInputs: boolean = false): void {
    try {
      const nextData: SleepData = this.sleepManager.getSleepData();
      const nextAdvices: string[] = this.sleepManager.generateAdvice();
      // diff 守卫：只有渲染字段真的变了才写 @State，30s 轮询常态下无变化
      if (!this.isSleepDataEqual(this.sleepData, nextData)) {
        this.sleepData = nextData;
      }
      if (!this.isStringArrayEqual(this.advices, nextAdvices)) {
        this.advices = nextAdvices;
      }
      const nextHasData = this.sleepManager.hasSleepData();
      if (this.hasSleepData !== nextHasData) {
        this.hasSleepData = nextHasData;
      }
      // 目标值同样落成 @State（见字段注释）；设置页改目标后切回本 Tab 时在此刷新
      const nextGoalMinutes = this.sleepManager.getSleepGoalMinutes();
      if (this.sleepGoalMinutes !== nextGoalMinutes) {
        this.sleepGoalMinutes = nextGoalMinutes;
      }
      // 日期同样随轮询刷新：页面在 HdsTabs 中常驻，跨过 00:00 后若不更新，
      // 「手动记录」卡会一直显示昨天，用户容易把数据记到错误的一天。
      const nextDateText: string = this.formatDate(new Date());
      if (this.todayDateText !== nextDateText) {
        this.todayDateText = nextDateText;
      }
    } catch (err) {
      hilog.error(0x0000, 'SleepPage', '%{public}s', 'Sleep refreshData failed: ' + formatError(err));
    }
    if (keepInputs) {
      return;
    }
    this.inputPreSleepMinutes = this.sleepData.preSleepUsageMinutes > 0 ? String(this.sleepData.preSleepUsageMinutes) : '';
    this.inputSleepMinutes = this.sleepData.sleepDurationMinutes > 0 ? String(this.sleepData.sleepDurationMinutes) : '';
  }

  /** 推荐入睡时间文本（HH:mm，来自 SleepManager 智能推算） */
  private getSuggestedBedtimeText(): string {
    const bedtime = this.sleepManager.getSuggestedBedtime();
    // 改用公共 formatHourMinute：此处是“HH:mm 收敛为一处”那一轮漏掉的第 6 份，
    // 与 formatHourMinute 逐字符等价（且该函数有“不钳位”契约单测锁定）
    return formatHourMinute(bedtime.hour, bedtime.minute);
  }

  /**
   * 睡眠目标达成进度（0~1），目标未配置时返回 0
   *
   * 读 @State sleepGoalMinutes 而不是 manager：二者语义相同，但只有前者会在
   * 设置页改动目标后触发重渲染（见字段注释的实机复现记录）。
   */
  private getSleepGoalProgress(): number {
    const goalMinutes = this.sleepGoalMinutes;
    if (goalMinutes <= 0) {
      return 0;
    }
    return Math.min(1, this.sleepData.sleepDurationMinutes / goalMinutes);
  }

  /** 睡眠目标文案，如 "目标 8小时" / "目标 7小时30分"（读 @State，理由同上） */
  private getSleepGoalText(): string {
    const goalMinutes = this.sleepGoalMinutes;
    const goalHours = Math.floor(goalMinutes / 60);
    const goalMins = goalMinutes % 60;
    return `目标 ${goalHours}小时${goalMins > 0 ? goalMins + '分' : ''}`;
  }

  /**
   * 提交手动输入的睡前使用/睡眠时长。
   *
   * ⚠️ 留空视为「不修改该项」并放行：两个输入框彼此独立，用户只想改睡眠时长时
   * 睡前使用那一栏往往留空，原实现 `parseInt('')` → NaN 会把整次提交拦下并弹报错，
   * 用户会困惑于"我没碰这个字段为什么不让保存"。
   */
  private submitManualData(): void {
    const rawPreSleep = this.inputPreSleepMinutes.trim();
    const rawSleep = this.inputSleepMinutes.trim();

    if (rawPreSleep.length === 0 && rawSleep.length === 0) {
      this.showToast('请至少填写一项');
      return;
    }

    let preSleepMinutes = this.sleepData.preSleepUsageMinutes;
    let sleepMinutes = this.sleepData.sleepDurationMinutes;

    if (rawPreSleep.length > 0) {
      const parsed = parseInt(rawPreSleep, 10);
      if (Number.isNaN(parsed) || parsed < MIN_PRE_SLEEP_USAGE_MINUTES || parsed > MAX_PRE_SLEEP_USAGE_MINUTES) {
        this.showToast(`睡前使用请输入 ${MIN_PRE_SLEEP_USAGE_MINUTES}-${MAX_PRE_SLEEP_USAGE_MINUTES} 分钟，留空表示不修改`);
        return;
      }
      preSleepMinutes = parsed;
    }

    if (rawSleep.length > 0) {
      const parsed = parseInt(rawSleep, 10);
      if (Number.isNaN(parsed) || parsed < MIN_SLEEP_DURATION_MINUTES || parsed > MAX_SLEEP_DURATION_MINUTES) {
        this.showToast(`睡眠时长请输入 ${MIN_SLEEP_DURATION_MINUTES}-${MAX_SLEEP_DURATION_MINUTES} 分钟，留空表示不修改`);
        return;
      }
      sleepMinutes = parsed;
    }

    try {
      this.sleepManager.syncFromInput(sleepMinutes, preSleepMinutes);
      this.refreshData();
      this.showToast('已保存');
    } catch (err) {
      hilog.error(0x0000, 'SleepPage', '%{public}s', 'Sleep submitManualData failed: ' + formatError(err));
      this.showToast('保存失败');
    }
  }

  /** 从华为运动健康同步睡眠数据；无授权/无数据时回退本地数据 */
  private async syncFromWearable(): Promise<void> {
    if (this.isSyncingHealth) {
      return;
    }
    this.isSyncingHealth = true;
    try {
      const outcome = await this.sleepManager.syncFromWearable();
      if (outcome === HealthSyncOutcome.SUCCESS) {
        this.refreshData();
        this.saveLastSyncTime();
        this.showToast('已从华为运动健康同步');
      } else if (outcome === HealthSyncOutcome.UNAVAILABLE) {
        // ⚠️ 与「未授权」分开：这种设备/系统根本没有可开的相关开关，
        // 让用户去系统设置里找是把他引向一个不存在的入口、反复重试也无进展。
        this.showToast('本设备不支持读取华为运动健康数据');
      } else if (outcome === HealthSyncOutcome.NOT_AUTHORIZED) {
        // 与「没有睡眠记录」区分开：前者用户该去授权，后者他已经授权了、只是那天没数据
        this.showToast('未获得健康数据授权，请在系统设置中允许');
      } else if (outcome === HealthSyncOutcome.NO_DATA) {
        this.showToast('华为运动健康中没有近两日的睡眠记录');
      } else {
        this.showToast('同步失败，请稍后重试');
      }
    } catch (err) {
      hilog.error(0x0000, 'SleepPage', '%{public}s', 'Sleep syncFromWearable failed: ' + formatError(err));
      this.showToast('同步失败');
    } finally {
      this.isSyncingHealth = false;
    }
  }

  /** 格式化为 "X月X日 周X" 用于今日日期展示 */
  private formatDate(date: Date): string {
    return `${date.getMonth() + 1}月${date.getDate()}日 ${WEEKDAY_FULL_LABELS[date.getDay()]}`;
  }

  /** 格式化为 "X月X日 HH:mm" 用于同步时间展示 */
  private formatDateTime(date: Date): string {
    // pad 用模块级 pad2，避免每次调用都新建一个箭头函数闭包
    return `${date.getMonth() + 1}月${date.getDate()}日 ${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
  }

  /** 轻提示；getPromptAction 异常时兜底 hilog 记录 */
  private showToast(message: string): void {
    showToastSafe(this.getUIContext(), 'SleepPage', 'SleepPage', message);
  }

  /** 数字输入净化：仅保留数字并截断到上限（超限取最大值） */
  private sanitizeNumberInput(value: string, maxValue: number): string {
    const digits = value.replace(/\D/g, '');
    if (digits === '') {
      return '';
    }
    const num = parseInt(digits, 10);
    if (Number.isNaN(num)) {
      return '';
    }
    if (num > maxValue) {
      return String(maxValue);
    }
    return String(num);
  }

  /**
 * 分钟数格式化为 "X小时Y分"；不足 1 小时只显示 "Y分钟"。
 * 整小时省略零分（与 Index.formatMinutes 同口径）——否则 420 分钟会显示成
 * 「7小时0分」，而同页「目标 7小时」是省略的，同一张页两套写法。
 */
  private formatMinutes(minutes: number): string {
    const hrs = Math.floor(minutes / 60);
    const mins = minutes % 60;
    if (hrs <= 0) {
      return mins + '分钟';
    }
    if (mins === 0) {
      return hrs + '小时';
    }
    return hrs + '小时' + mins + '分';
  }

  /** 评分颜色：>=80 绿，>=60 橙，其余红 */
  private getScoreColor(): string {
    if (this.sleepData.score >= 80) {
      return ThemeColor.accentGreen(this.isDarkMode);
    } else if (this.sleepData.score >= 60) {
      return ThemeColor.accentOrange(this.isDarkMode);
    }
    return ThemeColor.accentRed(this.isDarkMode);
  }

  /** 评分等级文案：>=80 习惯良好，>=60 有待改善，其余需要注意 */
  private getScoreLabel(): string {
    if (this.sleepData.score >= 80) {
      return '习惯良好';
    } else if (this.sleepData.score >= 60) {
      return '有待改善';
    }
    return '需要注意';
  }

  build() {
    Stack() {
      // 全局多彩液态渐变背景
      Column().width('100%').height('100%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: ThemeColor.gradient(this.isDarkMode)
        })

      // 随手机姿态变化的环境光晕
      AmbientLight()

      Scroll() {
        Column({ space: 16 }) {
          // 评分卡片
          GlassCard({ delay: 0, cardOpacity: this.scoreCardOpacity, cardTranslateY: this.scoreCardY }) {
            Column({ space: 20 }) {
              Stack() {
// 外圈细描边，营造液态玻璃层次
                // ⚠️ 本 SDK 上 shape 的 **.border() 同样按矩形绘制**（实机截图取证：环外围出现方框）。
                // 画"环"必须用 .stroke() + .strokeWidth()；.border() 只对矩形容器有效。
                Circle().width(180).height(180).fill('transparent')
                  .strokeWidth(0.5)
                  .stroke(ThemeColor.separator(this.isDarkMode))

                // 环的未填充轨道：独立 Circle，**只描边不填充**。
                // ⚠️ 此前这段轨道是挂在 Progress 上的 `.backgroundColor(...)`，
                // 而 Progress 的 backgroundColor 在 Ring 模式下会被 ArkUI 当作**组件矩形背景**绘制，
                // 于是环周围出现一个方框（浅色模式下白底 + 浅背景，方框边界格外刺眼；实机截图取证）。
                // ⚠️ 第二版踩的坑：改用 `.fill(fill色)` 画 Circle 会把整个圆盘填成灰色饼，
                // 盖住玻璃质感 —— Circle 必须 fill('transparent') + 描边才是"环"。
                Circle().width(160).height(160).fill('transparent')
                  .strokeWidth(8)
                  .stroke(ThemeColor.fill(this.isDarkMode))

// 评分环形进度
                // ⚠️ 本页评分环**只有这一个 Progress**，且不挂 backgroundColor / shadow。
                // 实机四轮取证（勿再尝试这几条路，每条都产生矩形方框/方块）：
                //   ① Progress.backgroundColor 在 Ring 模式下被当作**组件矩形背景** → 白方框；
                //   ② 轨道改由独立 Circle 承载后，Progress 的 .shadow() 按**矩形边界**渲染 → 方框仍在；
                //   ③ 阴影挪到 Circle 上，本 SDK 上 shape 的 shadow 同样按矩形渲染 → 变成方块；
                //   ④ 删掉 Progress 的 backgroundColor 后**方框仍在** —— 真正来源是**第二个**（内层细环）
                //      Progress：两个同尺寸 Ring 叠放时，后一个的未填充 track 以默认样式绘制成一个矩形。
                // ⇒ 单个 Ring + 独立描边 Circle 作轨道，是本 SDK 上唯一不出矩形的组合。
                // 层次由「外圈细描边(180) + 底环(160) + 进度环(160) + 内圈细描边(140)」四层轮廓承担。
                // 零数据时（全新安装 / 未同步 / 未手填）不画环也不给分：
                // 0 < 360 会算成「扣 20 → 80 分 → 习惯良好」，一个字数据都没有却拿到正面评价。
                if (this.hasSleepData) {
                  Progress({ value: this.sleepData.score, total: 100, type: ProgressType.Ring })
                    .width(160).height(160)
                    .color(this.getScoreColor()).style({ strokeWidth: 8 })
                    .animation({ duration: 800, curve: Curve.EaseInOut })
                    .accessibilityLevel('no')
                }

                Circle().width(140).height(140).fill('transparent')
                  .strokeWidth(0.5)
                  .stroke(ThemeColor.separator(this.isDarkMode))

                // 环内数字 + 标题
                Column({ space: 6 }) {
                  if (this.hasSleepData) {
                    Text('' + this.sleepData.score).fontSize(48).fontWeight(FontWeight.Bold).fontColor(this.getScoreColor())
                      .animation({ duration: 300, curve: Curve.EaseOut })
                    Text('睡前习惯评分').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                  } else {
                    Text('暂无数据').fontSize(24).fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColor.systemGray(this.isDarkMode))
                    Text('记录一次睡眠或同步后开始评分').fontSize(12)
                      .fontColor(ThemeColor.systemGray(this.isDarkMode))
                      .textAlign(TextAlign.Center)
                  }
                }
              }
              .width('100%').height(200).alignContent(Alignment.Center)
// 无障碍：外圈描边 + Progress 环自身均无文本，由本 Stack 承载唯一语义，
// 否则读屏只会把"80"这个裸数字播报出去且不知含义。
// 环设 'no'（只隐藏自身、不影响子节点），语义只在本节点声明一次。
              .accessibilityLevel('yes')
              .accessibilityText(this.hasSleepData ?
                '睡前习惯评分 ' + this.sleepData.score + ' 分，' + this.getScoreLabel() :
                '睡前习惯评分，暂无数据。记录一次睡眠或同步后开始评分')

              if (this.hasSleepData) {
                Text(this.getScoreLabel()).fontSize(13).fontColor(this.getScoreColor()).fontWeight(FontWeight.Medium)
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .backgroundColor(ThemeColor.withAlpha(this.getScoreColor(), '22')).borderRadius(14)
                  .animation({ duration: 300, curve: Curve.EaseOut })
              }
            }.width('100%')
          }

          // 核心指标卡片
          GlassCard({ delay: 100, cardOpacity: this.metricsCardOpacity, cardTranslateY: this.metricsCardY }) {
            Column({ space: 16 }) {
              Row() {
                Column({ space: 6 }) {
                  // 单位与数值同行（此前"分钟"单独占一行、"睡前使用"再占一行，
                  // 一个指标占三行、四个指标纵向拉得很长），与首页主数字同一排版口径
                  Row({ space: 3 }) {
                    Text('' + this.sleepData.preSleepUsageMinutes).fontSize(32).fontWeight(FontWeight.Bold)
                      .fontColor(this.sleepData.preSleepUsageMinutes > 30 ? ThemeColor.accentRed(this.isDarkMode) : ThemeColor.accentGreen(this.isDarkMode))
                      .animation({ duration: 300, curve: Curve.EaseOut })
                    Text('分钟').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                      .margin({ bottom: 8 })
                  }.alignItems(VerticalAlign.Bottom)
                  Text('睡前使用').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                }.layoutWeight(1).alignItems(HorizontalAlign.Center)

                Column().width(0.5).height(60).backgroundColor(ThemeColor.separator(this.isDarkMode))

                Column({ space: 6 }) {
                  Text(this.formatMinutes(this.sleepData.sleepDurationMinutes))
                    .fontSize(24).fontWeight(FontWeight.Bold).fontColor(ThemeColor.label(this.isDarkMode))
                  Text('昨晚睡眠').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                }.layoutWeight(1).alignItems(HorizontalAlign.Center)
              }.width('100%')

              Column().width('100%').height(0.5).backgroundColor(ThemeColor.separator(this.isDarkMode))

              Row() {
                Column({ space: 6 }) {
                  Text(this.getSuggestedBedtimeText()).fontSize(24).fontWeight(FontWeight.Bold).fontColor(ThemeColor.accentIndigo(this.isDarkMode))
                  Text('建议入睡').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                }.layoutWeight(1).alignItems(HorizontalAlign.Center)

                Column().width(0.5).height(60).backgroundColor(ThemeColor.separator(this.isDarkMode))

                Column({ space: 6 }) {
                  Text((this.getSleepGoalProgress() * 100).toFixed(0) + '%')
                    .fontSize(24).fontWeight(FontWeight.Bold)
                    .fontColor(this.getSleepGoalProgress() >= 1 ? ThemeColor.accentGreen(this.isDarkMode) : ThemeColor.accentOrange(this.isDarkMode))
                  Text(this.getSleepGoalText()).fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                  // 目标达成度此前只有一个孤立的百分数，用户不知道"离目标还差多少"。
                  // 补一条与首页今日使用进度条同款的线性进度条：
                  // 轨道为填充色、填充为达成色（达标绿 / 未达标橙），无需任何文字解释。
                  Stack({ alignContent: Alignment.Start }) {
                    Row().width('100%').height(4).borderRadius(2)
                      .backgroundColor(ThemeColor.fill(this.isDarkMode))
                    Row()
                      .width(Math.min(1, this.getSleepGoalProgress()) * 100 + '%')
                      .height(4).borderRadius(2)
                      .backgroundColor(this.getSleepGoalProgress() >= 1
                        ? ThemeColor.accentGreen(this.isDarkMode)
                        : ThemeColor.accentOrange(this.isDarkMode))
                      .animation({ duration: 600, curve: Curve.EaseOut })
                  }
                  .width('72%')
                  .height(4)
                  .margin({ top: 2 })
                }.layoutWeight(1).alignItems(HorizontalAlign.Center)
              }.width('100%')
            }.width('100%')
          }

          // 改善建议卡片
          GlassCard({ delay: 200, cardOpacity: this.adviceCardOpacity, cardTranslateY: this.adviceCardY }) {
            Column({ space: 12 }) {
              Text('改善建议').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode)).alignSelf(ItemAlign.Start)

              // 改善建议条目：序号圆点 + 文案，交错入场动画
              ForEach(this.advices, (advice: string, index: number) => {
                Row({ space: 12 }) {
                  Text('' + (index + 1)).fontSize(13).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                    .width(26).height(26).textAlign(TextAlign.Center)
                    .backgroundColor(ThemeColor.accentTint('0,122,255', 0.13, this.isDarkMode)).borderRadius(13)

                  Text(advice).fontSize(14).fontColor(ThemeColor.labelSecondary(this.isDarkMode)).lineHeight(20).layoutWeight(1)
                }
                .width('100%').padding({ top: 8, bottom: 8 })
                .opacity(this.adviceCardOpacity)
                .translate({ x: this.adviceCardOpacity === 1 ? 0 : -16 })
                .animation({ delay: 400 + index * 80, duration: 500, curve: curves.interpolatingSpring(0, 1, 170, 12) })
              }, (advice: string, index: number) => index + '_' + advice)
            }.width('100%')
          }

          // 手动记录卡片
          GlassCard({ delay: 300, cardOpacity: this.formCardOpacity, cardTranslateY: this.formCardY }) {
            Column({ space: 16 }) {
              Row() {
                Text('手动记录').fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemeColor.label(this.isDarkMode)).alignSelf(ItemAlign.Start)
                Blank()
                Text(this.todayDateText).fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
              }.width('100%')

              Column({ space: 12 }) {
                Column({ space: 6 }) {
                  Text('睡前使用（分钟）').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                  TextInput({ placeholder: '分钟', text: $$this.inputPreSleepMinutes })
                    .height(48).width('100%').backgroundColor(ThemeColor.inputBg(this.isDarkMode)).fontColor(ThemeColor.label(this.isDarkMode))
                    .placeholderColor(ThemeColor.systemGray(this.isDarkMode)).borderRadius(12).type(InputType.Number)
                    .maxLength(4).accessibilityText('睡前使用时长，单位分钟')
                    .onFocus(() => { this.isEditingInputs = true; })
                    .onBlur(() => { this.isEditingInputs = false; })
                    .onChange((value: string) => { this.inputPreSleepMinutes = this.sanitizeNumberInput(value, MAX_PRE_SLEEP_USAGE_MINUTES); })
                  Text(`范围 ${MIN_PRE_SLEEP_USAGE_MINUTES}-${MAX_PRE_SLEEP_USAGE_MINUTES} 分钟`).fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
                }.width('100%')

                Column({ space: 6 }) {
                  Text('昨晚睡眠（分钟）').fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode))
                  TextInput({ placeholder: '分钟', text: $$this.inputSleepMinutes })
                    .height(48).width('100%').backgroundColor(ThemeColor.inputBg(this.isDarkMode)).fontColor(ThemeColor.label(this.isDarkMode))
                    .placeholderColor(ThemeColor.systemGray(this.isDarkMode)).borderRadius(12).type(InputType.Number)
                    .maxLength(4).accessibilityText('昨晚睡眠时长，单位分钟')
                    .onFocus(() => { this.isEditingInputs = true; })
                    .onBlur(() => { this.isEditingInputs = false; })
                    .onChange((value: string) => { this.inputSleepMinutes = this.sanitizeNumberInput(value, MAX_SLEEP_DURATION_MINUTES); })
                  Text(`范围 ${MIN_SLEEP_DURATION_MINUTES}-${MAX_SLEEP_DURATION_MINUTES} 分钟`).fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
                }.width('100%')

                Button('保存').fontSize(15).height(48).width('100%').fontColor(IOS26_WHITE).backgroundColor(ThemeColor.accentColorFill(this.accentColorHex, this.isDarkMode)).borderRadius(24)
                  .shadow({ radius: 10, color: ThemeColor.withAlpha(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode), '33'), offsetX: 0, offsetY: 3 })
                  .onClick(() => { this.submitManualData(); })

                Row() {
                  Text('睡前使用时长已根据真实记录自动更新').fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode)).layoutWeight(1)
                  Text('最近同步：' + this.lastSyncTimeText)
                    .fontSize(11).fontColor(ThemeColor.systemGray(this.isDarkMode))
                }.width('100%')

                Row() {
                  Text('从华为运动健康同步').fontSize(13).fontColor(ThemeColor.accentIndigo(this.isDarkMode))
                    .layoutWeight(1).height(36).textAlign(TextAlign.Center)
                    .backgroundColor(ThemeColor.accentTint('88,86,214', 0.13, this.isDarkMode)).borderRadius(18)
                    .margin({ right: 6 })
                    .enabled(!this.isSyncingHealth)
                    .opacity(this.isSyncingHealth ? 0.5 : 1)
                    // 纯 Text 伪按钮：补可聚焦语义与明确标签，读屏才知道这是可点的同步动作
                    .accessibilityLevel('yes')
                    .accessibilityText(this.isSyncingHealth ? '正在从华为运动健康同步' : '从华为运动健康同步，点击开始')
                    .onClick(() => { this.syncFromWearable(); })

                  Text('重新计算').fontSize(13).fontColor(ThemeColor.accentColor(this.accentColorHex, this.isDarkMode))
                    .layoutWeight(1).height(36).textAlign(TextAlign.Center)
                    .backgroundColor(ThemeColor.accentTint('0,122,255', 0.13, this.isDarkMode)).borderRadius(18)
                    .margin({ left: 6 })
                    // 同上：Text 伪按钮补可聚焦语义
                    .accessibilityLevel('yes')
                    .accessibilityText('按真实亮屏记录重新计算睡前使用时长')
                    .onClick(() => {
                      this.sleepManager.updatePreSleepUsageFromRecords();
                      this.refreshData();
                      this.showToast('已根据真实记录重新计算');
                    })
                }.width('100%')
              }.width('100%')
            }.width('100%')
          }

          Text('睡前使用 = 统计窗口内的手机亮屏总时长（数据来自手机屏幕点亮记录）')
            .fontSize(12).fontColor(ThemeColor.systemGray(this.isDarkMode)).textAlign(TextAlign.Center)
            .padding({ left: 8, right: 8, bottom: 20 })

          Column().height(120)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12, bottom: 16 })
      }
      .width('100%').layoutWeight(1).backgroundColor('transparent')
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    }
    .width('100%').height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
