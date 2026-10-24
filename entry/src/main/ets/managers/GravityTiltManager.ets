import { formatError } from '../models/ErrUtils';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { sensor } from '@kit.SensorServiceKit';

const TAG = 'GravityTiltManager';

/**
 * 重力姿态单例管理器
 * 多个 UI 组件共享同一条重力传感器订阅
 * 通过 AppStorage(tiltX/tiltY, 范围 -1~1) 广播手机姿态，驱动光晕位移
 */
export class GravityTiltManager {
  private static instance: GravityTiltManager = new GravityTiltManager();

  static getInstance(): GravityTiltManager {
    return GravityTiltManager.instance;
  }

  private refCount: number = 0;
  private listening: boolean = false;

  private gravityCallback: (data: sensor.GravityResponse) => void = (data: sensor.GravityResponse): void => {
    const nx = Math.max(-1, Math.min(1, data.x / 9.8));
    const ny = Math.max(-1, Math.min(1, data.y / 9.8));
    const roundedX = Math.round(nx * 100) / 100;
    const roundedY = Math.round(ny * 100) / 100;
    const lastX = AppStorage.get<number>('tiltX');
    const lastY = AppStorage.get<number>('tiltY');
    if (lastX !== roundedX || lastY !== roundedY) {
      AppStorage.setOrCreate<number>('tiltX', roundedX);
      AppStorage.setOrCreate<number>('tiltY', roundedY);
    }
  };

  acquire(): void {
    if (this.refCount <= 0 && !this.listening) {
      try {
        const options: sensor.Options = { interval: 'ui' };
        sensor.on(sensor.SensorId.GRAVITY, this.gravityCallback, options);
        this.listening = true;
        hilog.info(0x0000, TAG, '%{public}s', '重力传感器已订阅');
      } catch (err) {
        hilog.warn(0x0000, TAG, '%{public}s', '重力传感器订阅失败: ' + formatError(err));
        return;
      }
    }
    this.refCount++;
  }

  release(): void {
    if (this.refCount <= 0) {
      return;
    }
    this.refCount--;
    if (this.refCount <= 0 && this.listening) {
      try {
        sensor.off(sensor.SensorId.GRAVITY, this.gravityCallback);
        this.listening = false;
        hilog.info(0x0000, TAG, '%{public}s', '重力传感器已注销');
      } catch (err) {
        hilog.warn(0x0000, TAG, '%{public}s', '重力传感器注销失败: ' + formatError(err));
      }
      this.refCount = 0;
    }
  }
}
