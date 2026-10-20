/**
 * 碰一碰（knockShare）触发层。
 *
 * 能力边界（已核实 SDK，见 README）：
 * - harmonyShare.knockShare 自 API 12 起对普通应用开放，无特殊权限；
 * - 但它只提供「单向发送 SharedData」的能力，不是双向通道；
 * - 所以它在这里只负责把「入房凭证」递给对方，账本同步仍走 RoomService 的 DDO。
 *
 * 同时保留 NFC 标签这条路（NFC_TAG 是 normal 级 system_grant），
 * 两条路都不可用时降级为手动输入 sessionId。
 */
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { common } from '@kit.AbilityKit';

/** 碰一碰传入的凭证文本前缀，便于和对端识别是本应用的数据 */
export const SHARE_PREFIX = 'fenben://join?sid=';

/** 探测碰一碰能力是否可用 */
export interface KnockCapability {
  available: boolean;
  summary: string;
}

export class KnockService {
  private registered: boolean = false;
  private onCredential: (sessionId: string) => void = () => {};

  /** 把 sessionId 编码成可分享的文本 */
  static encodeCredential(sessionId: string): string {
    return `${SHARE_PREFIX}${sessionId}`;
  }

  /** 从分享文本里解出 sessionId；不是本应用的凭证返回空串 */
  static decodeCredential(text: string): string {
    if (!text.startsWith(SHARE_PREFIX)) {
      return '';
    }
    return text.substring(SHARE_PREFIX.length).trim();
  }

  /**
   * 注册碰一碰监听。
   * 只有 host 需要注册——碰一碰的语义是「我把房间递给对方」。
   */
  register(onCredential: (sessionId: string) => void): KnockCapability {
    this.onCredential = onCredential;
    if (this.registered) {
      return { available: true, summary: '碰一碰已就绪' };
    }
    try {
      harmonyShare.on('knockShare', (target: harmonyShare.SharableTarget) => {
        // 拿到目标后，把凭证分享出去
        this.shareTo(target).catch(() => {});
      });
      this.registered = true;
      return { available: true, summary: '碰一碰已就绪，碰一下即可分享房间' };
    } catch (e) {
      const err = e as ShareError;
      return {
        available: false,
        summary: `碰一碰不可用（${err.message ?? '当前设备不支持'}），可手动告诉对方房间号`
      };
    }
  }

  /** 当前待分享的凭证，由外部在创建房间后设置 */
  pendingCredential: string = '';

  private async shareTo(target: harmonyShare.SharableTarget): Promise<void> {
    if (this.pendingCredential.length === 0) {
      return;
    }
    try {
      const record: systemShare.SharedRecord = {
        utd: 'general.plain-text',
        content: this.pendingCredential
      };
      const data = new systemShare.SharedData(record);
      await target.share(data);
      const sid = KnockService.decodeCredential(this.pendingCredential);
      if (sid.length > 0) {
        this.onCredential(sid);
      }
    } catch (_e) {
      // 分享失败时不影响本地房间，用户仍可手动报房间号
    }
  }

  /** 注销监听 */
  unregister(): void {
    if (!this.registered) {
      return;
    }
    try {
      harmonyShare.off('knockShare');
    } catch (_e) {
      // 注销失败无实际影响
    }
    this.registered = false;
  }

  isRegistered(): boolean {
    return this.registered;
  }
}

interface ShareError {
  code?: number;
  message?: string;
}
