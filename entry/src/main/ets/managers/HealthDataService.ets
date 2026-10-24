import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { healthStore } from '@kit.HealthServiceKit';
import { common } from '@kit.AbilityKit';

const TAG = 'HealthDataService';

interface SleepSummary {
  durationMinutes: number;
  score: number;
  deepSleepMinutes: number;
  shallowSleepMinutes: number;
  dreamSleepMinutes: number;
}

interface HealthSyncResult {
  authorized: boolean;
  sleep?: SleepSummary;
  /**
   * 「拿不到授权」与「这台设备/这次调用根本不具备该能力」是两回事，
   * 原实现把两者压进同一个 `authorized: false`，
   * 于是界面一律提示「请在系统设置中允许」—— 而用户根本找不到那个开关（真实原因只留在 hilog）。
   * 该字段为 true 时表示：未注入 Context、或设备不支持 HealthStore 能力。
   */
  unavailable?: boolean;
}

/**
 * 华为健康数据服务封装
 * 通过 HealthServiceKit 读取华为运动健康中的睡眠等真实数据
 * 真机运行需：登录华为账号、同意健康隐私协议、授予健康数据读取权限
 */
export class HealthDataService {
  private static instance: HealthDataService;
  private initialized: boolean = false;
  private context?: common.Context;

  static getInstance(): HealthDataService {
    if (!HealthDataService.instance) {
      HealthDataService.instance = new HealthDataService();
    }
    return HealthDataService.instance;
  }

  setContext(context: common.Context): void {
    this.context = context;
  }

  async init(): Promise<boolean> {
    if (this.initialized) {
      return true;
    }
    if (!this.context) {
      hilog.warn(0x0000, TAG, '%{public}s', '未设置 Context，无法初始化健康数据服务');
      return false;
    }
    if (!this.isHealthStoreAvailable()) {
      hilog.warn(0x0000, TAG, '%{public}s', '当前设备不支持 HealthStore 能力');
      return false;
    }
    try {
      await healthStore.init(this.context);
      this.initialized = true;
      hilog.info(0x0000, TAG, '%{public}s', '健康数据服务初始化成功');
      return true;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '健康数据服务初始化失败：' + formatError(err));
      return false;
    }
  }

  /** 惰性初始化守卫：未初始化时尝试先初始化 */
  private async ensureInitialized(): Promise<boolean> {
    return this.initialized || await this.init();
  }

  /**
   * 请求健康数据读取授权
   * 先查询已授权类型，未全部授权时拉起华为账号授权页面
   */
/**
   * 本设备/本次调用是否根本不具备健康数据能力（未注入 Context 或系统不支持 HealthStore）。
   *
   * ⚠️ 刻意与「用户未授权」分开：两者在原实现里都是 `requestAuthorization()` 返回 false，
   * 界面只能提示「请在系统设置中允许」，而这两种情况下系统设置里都没有可开的开关，
   * 用户反复重试毫无进展。
   */
  isAvailable(): boolean {
    return this.context !== undefined && this.isHealthStoreAvailable();
  }

  async requestAuthorization(): Promise<boolean> {
    if (!(await this.ensureInitialized())) {
      return false;
    }
    if (!this.context) {
      hilog.warn(0x0000, TAG, '%{public}s', '未设置 Context，无法请求健康数据授权');
      return false;
    }

    const request = this.buildAuthorizationRequest();

    try {
      // 先查询是否已授权
      const queryResponse = await healthStore.getAuthorizations(request);
      if (queryResponse.readDataTypes.length === request.readDataTypes.length) {
        hilog.info(0x0000, TAG, '%{public}s', '健康数据已授权');
        return true;
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, '%{public}s', '查询健康数据授权失败：' + formatError(err));
    }

    try {
      // 拉起授权页面，需传入 UIAbilityContext
      const response = await healthStore.requestAuthorizations(this.context as common.UIAbilityContext, request);
      const allGranted = response.readDataTypes.length === request.readDataTypes.length;
      hilog.info(0x0000, TAG, '%{public}s', '健康数据授权结果：' + String(allGranted));
      return allGranted;
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '请求健康数据授权失败：' + formatError(err));
      return false;
    }
  }

  /** 设备是否支持 HealthStore 能力 */
  private isHealthStoreAvailable(): boolean {
    return canIUse('SystemCapability.Health.HealthStore');
  }

  /** 构造健康数据授权请求（仅需睡眠数据的读权限） */
  private buildAuthorizationRequest(): healthStore.AuthorizationRequest {
    return {
      readDataTypes: [
        healthStore.healthSequenceHelper.sleepRecord.DATA_TYPE
      ],
      writeDataTypes: []
    };
  }


  /**
   * 读取昨晚睡眠数据
   */
  async readLastNightSleep(): Promise<SleepSummary | undefined> {
    if (!(await this.ensureInitialized())) {
      return undefined;
    }

    const now = new Date();
    const yesterday = new Date(now.getTime() - 24 * 60 * 60 * 1000);
    const startTime = new Date(yesterday.getFullYear(), yesterday.getMonth(), yesterday.getDate(), 18, 0, 0).getTime();
    const endTime = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12, 0, 0).getTime();

    const request: healthStore.HealthSequenceReadRequest = {
      startTime,
      endTime,
      healthSequenceDataType: healthStore.healthSequenceHelper.sleepRecord.DATA_TYPE
    };

    try {
      const records = await healthStore.readData<healthStore.healthModels.SleepRecord>(request);
      if (!records || records.length === 0) {
        hilog.info(0x0000, TAG, '%{public}s', '未读取到睡眠记录');
        return undefined;
      }

      // 取最近一条睡眠记录
      const lastRecord = records[records.length - 1];
      const model = lastRecord.summaries;
      const durationSeconds = model.duration ||
        (model.shallowDuration ?? 0) + (model.deepDuration ?? 0) + (model.dreamDuration ?? 0);
      const durationMinutes = Math.floor(durationSeconds / 60);
      const score = model.sleepScore ?? 0;

      return {
        durationMinutes,
        score: score > 0 ? score : this.estimateScore(durationMinutes),
        deepSleepMinutes: Math.floor((model.deepDuration ?? 0) / 60),
        shallowSleepMinutes: Math.floor((model.shallowDuration ?? 0) / 60),
        dreamSleepMinutes: Math.floor((model.dreamDuration ?? 0) / 60)
      };
    } catch (err) {
      hilog.error(0x0000, TAG, '%{public}s', '读取睡眠数据失败：' + formatError(err));
      return undefined;
    }
  }

  /**
   * 同步睡眠数据
   * 授权通过后读取睡眠记录
   */
async syncHealthData(): Promise<HealthSyncResult> {
    const unavailable = !this.isAvailable();
    const authorized = await this.requestAuthorization();
    const result: HealthSyncResult = { authorized: authorized, unavailable: unavailable };
    if (!authorized) {
      hilog.warn(0x0000, TAG, '%{public}s',
        unavailable ? '健康数据能力不可用（未注入 Context 或设备不支持 HealthStore）' : '健康数据授权未通过');
      return result;
    }

    const sleep = await this.readLastNightSleep();
    if (sleep) {
      result.sleep = sleep;
    }

    hilog.info(0x0000, TAG, '%{public}s', '健康数据同步完成：' + JSON.stringify({
      sleepMinutes: result.sleep?.durationMinutes
    }));
    return result;
  }

  /** 缺少系统睡眠评分时按时长粗估（7-9 小时最佳） */
  private estimateScore(durationMinutes: number): number {
    if (durationMinutes >= 420 && durationMinutes <= 540) {
      return 85;
    }
    if (durationMinutes >= 360) {
      return 75;
    }
    return 65;
  }
}
