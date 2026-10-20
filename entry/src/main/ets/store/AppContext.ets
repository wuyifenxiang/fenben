/**
 * 应用级单例：持有当前账单、存储与房间。
 *
 * 房间接入点在这里而不是页面里，原因是：
 * 账单会被 host 和 guest 两条路径修改，必须收敛到同一个地方，
 * 否则页面之间会出现「谁的账单才是权威」的分叉。
 */
import { common } from '@kit.AbilityKit';
import { Bill } from '../model/Bill';
import { BillStore, createBill } from './BillStore';
import { RoomService } from '../room/RoomService';
import { RoomRole } from '../room/Protocol';

export class AppContext {
  private static inst?: AppContext;

  store: BillStore = new BillStore();
  room: RoomService = new RoomService();
  bill?: Bill;
  /** 当前页面上「正在认领的人」，碰一碰时以他为准 */
  activeParticipantId: string = '';
  private loaded: boolean = false;
  private listeners: Array<() => void> = [];

  static instance(): AppContext {
    if (!AppContext.inst) {
      AppContext.inst = new AppContext();
    }
    return AppContext.inst;
  }

  /** 账单变化的订阅者（页面注册，用于重绘） */
  addBillListener(l: () => void): void {
    this.listeners.push(l);
  }

  removeBillListener(l: () => void): void {
    this.listeners = this.listeners.filter(x => x !== l);
  }

  private notifyBillChanged(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  async init(context: common.Context): Promise<void> {
    if (this.loaded) {
      return;
    }
    await this.store.load(context);
    this.room.attach(context);
    this.loaded = true;
    const saved = await this.store.loadCurrent();
    if (saved) {
      this.bill = saved;
      this.activeParticipantId = saved.participants.length > 0 ? saved.participants[0].id : '';
    }
    this.bindRoom();
  }

  /**
   * 把房间回调接到本地账单上。
   * host：应用完 guest 意图后，用新账单覆盖本地并落盘；
   * guest：收到 host 快照后直接替换——guest 不拥有权威数据。
   */
  private bindRoom(): void {
    this.room.onHostApply = (bill: Bill) => {
      this.bill = bill;
      this.persist().catch(() => {});
      this.notifyBillChanged();
    };
    this.room.onGuestSnapshot = (bill: Bill) => {
      this.bill = bill;
      if (this.activeParticipantId.length === 0 && bill.participants.length > 0) {
        this.activeParticipantId = bill.participants[0].id;
      }
      this.notifyBillChanged();
    };
  }

  /** 拿当前账单；没有就建一张新的 */
  ensureBill(): Bill {
    if (!this.bill) {
      this.bill = createBill('');
      this.activeParticipantId = this.bill.participants[0].id;
    }
    return this.bill;
  }

  /** 本地改动后调用：落盘 + 通知 UI；host 还要把新快照推给房间 */
  async commit(): Promise<void> {
    const bill = this.ensureBill();
    this.notifyBillChanged();
    if (this.room.isHost()) {
      this.room.pushSnapshot(bill);
    }
    await this.persist();
  }

  /** 有改动就落盘，失败不打断交互 */
  async persist(): Promise<void> {
    if (this.bill) {
      try {
        await this.store.saveCurrent(this.bill);
      } catch (_e) {
        // 存储失败不影响当前会话，下次改动会再试
      }
    }
  }

  async resetBill(): Promise<void> {
    this.bill = undefined;
    this.activeParticipantId = '';
    try {
      await this.store.clearCurrent();
    } catch (_e) {
      // 忽略
    }
    this.notifyBillChanged();
  }

  isGuest(): boolean {
    return this.room.state().role === RoomRole.GUEST;
  }

  dispose(): void {
    this.persist().catch(() => {});
    this.room.leave().catch(() => {});
  }
}
