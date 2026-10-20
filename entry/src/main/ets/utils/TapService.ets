/**
 * 碰一碰认领的可用性探测与降级说明。
 *
 * 现状（必须如实告知用户，不要假装已经接通）：
 * - 鸿蒙的「碰一碰」在系统层面由 Nearby Service / 分布式软总线承载，
 *   应用侧需要 ohos.permission.DISTRIBUTED_DATASYNC（user_grant，普通应用可用）
 *   与 distributedDeviceManager 的发现能力。
 * - 本工程只做了「能力探测 + 手动确认」的前半段：能判断设备与权限是否具备，
 *   真正的跨设备握手与消息通道尚未实现（见 README 的 Roadmap）。
 * - 因此当前版本碰一碰后走的是「选人认领」的手动确认，不假装自动完成。
 */
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';

export const PERM_DISTRIBUTED_DATASYNC: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';

export interface TapCapability {
  /** 分布式设备管理是否可用 */
  dmAvailable: boolean;
  /** 权限是否已授予 */
  granted: boolean;
  /** 当前可信设备数（0 表示附近没有已信任的鸿蒙设备） */
  trustedDeviceCount: number;
  /** 给用户看的一句话结论 */
  summary: string;
}

export class TapService {
  /**
   * 探测碰一碰链路是否具备条件。
   * 任一步失败都不抛异常，而是降级为 dmAvailable=false，让 UI 走手动路径。
   */
  static async probe(context: common.Context): Promise<TapCapability> {
    let granted = false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.checkAccessToken(
        context.applicationInfo.accessTokenId, PERM_DISTRIBUTED_DATASYNC);
      granted = result === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (_e) {
      granted = false;
    }

    let dmAvailable = false;
    let deviceCount = 0;
    if (granted) {
      try {
        const dm = distributedDeviceManager.createDeviceManager(context.applicationInfo.name);
        const devices = dm.getAvailableDeviceListSync();
        deviceCount = devices.length;
        dmAvailable = true;
        distributedDeviceManager.releaseDeviceManager(dm);
      } catch (_e) {
        dmAvailable = false;
      }
    }

    let summary: string;
    if (!granted) {
      summary = '未获得分布式权限，将使用手动认领';
    } else if (!dmAvailable) {
      summary = '本机分布式能力不可用，将使用手动认领';
    } else if (deviceCount === 0) {
      summary = '附近没有已信任的鸿蒙设备，可先手动认领';
    } else {
      summary = `附近有 ${deviceCount} 台可信设备，可碰一碰认领`;
    }
    return {
      dmAvailable: dmAvailable,
      granted: granted,
      trustedDeviceCount: deviceCount,
      summary: summary
    };
  }

  /** 申请分布式数据同步权限（首次进入碰一碰页时调用） */
  static async requestPermission(context: common.Context): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const res = await atManager.requestPermissionsFromUser(context, [PERM_DISTRIBUTED_DATASYNC]);
      return res.authResults.length > 0 && res.authResults[0] === 0;
    } catch (_e) {
      return false;
    }
  }
}
