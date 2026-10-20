/**
 * 房间服务：把 distributedDataObject 包成 host/guest 两种角色。
 *
 * 生命周期：
 *   createRoom()  → host，写入初始快照
 *   joinRoom(id)  → guest，等 host 的快照同步过来
 *   leave()       → 退出会话
 *
 * 设计取舍（见 README「同步模型」）：
 *   认领是低频操作，用主从模型换「可验证性」。guest 不直接改账单，
 *   只提交意图；host 应用后广播新快照。断线重连时 guest 重新拉一次快照即可。
 */
import { distributedDataObject } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Bill } from '../model/Bill';
import {
  ClaimIntent, RoomDoc, RoomRole, ROOM_PHASE,
  newSessionId, isValidSessionId, snapshotOf, restoreSnapshot,
  encodeIntents, decodeIntents, applyIntents
} from './Protocol';

/** 同步状态，给 UI 展示用 */
export type SyncPhase = 'idle' | 'connecting' | 'online' | 'offline' | 'error';

export interface RoomState {
  role: RoomRole;
  sessionId: string;
  phase: SyncPhase;
  peerCount: number;
  lastMessage: string;
  version: number;
}

export type RoomListener = (state: RoomState) => void;

export class RoomService {
  private ddo?: distributedDataObject.DataObject;
  private doc: RoomDoc | null = null;
  private role: RoomRole = RoomRole.NONE;
  private phase: SyncPhase = 'idle';
  private listeners: RoomListener[] = [];
  private version: number = 0;
  private peerCount: number = 0;
  private lastMessage: string = '';
  /** host 侧：已经消费过的意图 id，防止重复应用 */
  private consumed: Set<string> = new Set<string>();
  private deviceName: string = 'guest';
  private ctx?: common.Context;

  attach(context: common.Context): void {
    this.ctx = context;
  }

  addListener(l: RoomListener): void {
    this.listeners.push(l);
  }

  removeListener(l: RoomListener): void {
    this.listeners = this.listeners.filter(x => x !== l);
  }

  state(): RoomState {
    return {
      role: this.role,
      sessionId: this.doc ? this.doc.sessionId : '',
      phase: this.phase,
      peerCount: this.peerCount,
      lastMessage: this.lastMessage,
      version: this.version
    };
  }

  private emit(): void {
    const s = this.state();
    for (const l of this.listeners) {
      l(s);
    }
  }

  private setPhase(p: SyncPhase, msg: string): void {
    this.phase = p;
    this.lastMessage = msg;
    this.emit();
  }

  /**
   * 创建房间（host）。
   * 返回 sessionId，调用方负责把它通过碰一碰/二维码传给其他人。
   */
  async createRoom(bill: Bill): Promise<string> {
    if (!this.ctx) {
      throw new Error('RoomService not attached');
    }
    await this.leave();
    this.setPhase('connecting', '正在创建房间…');

    const sessionId = newSessionId();
    const doc: RoomDoc = {
      sessionId: sessionId,
      snapshot: snapshotOf(bill),
      version: 1,
      intents: encodeIntents([]),
      hostName: this.deviceName,
      phase: ROOM_PHASE.OPEN
    };
    this.doc = doc;
    this.version = 1;
    this.role = RoomRole.HOST;

    try {
      const ddo = distributedDataObject.create(this.ctx, doc as object);
      this.ddo = ddo;
      this.bindEvents();
      await ddo.setSessionId(sessionId);
      this.setPhase('online', '房间已创建');
      return sessionId;
    } catch (e) {
      const err = e as BusinessError;
      this.setPhase('error', `创建房间失败：${err.message ?? '未知错误'}`);
      this.role = RoomRole.NONE;
      throw new Error(err.message ?? 'createRoom failed');
    }
  }

  /**
   * 加入房间（guest）。
   * 只设置 sessionId，等 host 的快照同步过来。
   */
  async joinRoom(sessionId: string): Promise<void> {
    if (!this.ctx) {
      throw new Error('RoomService not attached');
    }
    if (!isValidSessionId(sessionId)) {
      throw new Error('sessionId 不合法');
    }
    await this.leave();
    this.setPhase('connecting', '正在加入房间…');

    const doc: RoomDoc = {
      sessionId: sessionId,
      snapshot: '',
      version: 0,
      intents: encodeIntents([]),
      hostName: '',
      phase: ROOM_PHASE.OPEN
    };
    this.doc = doc;
    this.role = RoomRole.GUEST;

    try {
      const ddo = distributedDataObject.create(this.ctx, doc as object);
      this.ddo = ddo;
      this.bindEvents();
      await ddo.setSessionId(sessionId);
      this.setPhase('online', '已加入，等待账本同步');
    } catch (e) {
      const err = e as BusinessError;
      this.setPhase('error', `加入失败：${err.message ?? '未知错误'}`);
      this.role = RoomRole.NONE;
      throw new Error(err.message ?? 'joinRoom failed');
    }
  }

  private bindEvents(): void {
    if (!this.ddo) {
      return;
    }
    this.ddo.on('status', (sessionId: string, networkId: string, status: 'online' | 'offline') => {
      if (status === 'online') {
        this.peerCount++;
        this.setPhase('online', `设备已连接（${this.peerCount}）`);
      } else {
        this.peerCount = Math.max(0, this.peerCount - 1);
        this.setPhase(this.peerCount > 0 ? 'online' : 'offline', `设备已断开（${this.peerCount}）`);
      }
    });

    this.ddo.on('change', (sessionId: string, fields: Array<string>) => {
      this.onRemoteChange(fields);
    });
  }

  /**
   * 远端数据变化。
   * host：只关心 intents，收到后应用并把新快照写回；
   * guest：只关心 snapshot，收到后交给 UI 刷新。
   *
   * 注意：this.doc 与传给 create() 的对象是同一个引用，
   * DDO 会把远端写入直接反映到它的属性上，所以这里读 this.doc 即为最新值。
   */
  private onRemoteChange(fields: Array<string>): void {
    if (!this.doc) {
      return;
    }
    const remote: RoomDoc = this.doc;

    if (this.role === RoomRole.HOST) {
      const incoming = decodeIntents(remote.intents);
      const fresh = incoming.filter(i => !this.consumed.has(i.intentId));
      if (fresh.length === 0) {
        return;
      }
      for (const f of fresh) {
        this.consumed.add(f.intentId);
      }
      // 应用意图需要一张账单；用当前快照还原，避免依赖 UI 状态
      const bill = restoreSnapshot(this.doc.snapshot);
      if (!bill) {
        return;
      }
      const applied = applyIntents(bill, fresh);
      if (applied === 0) {
        // 全部是重复意图，清空意图列表即可
        this.writeDoc({ intents: encodeIntents([]) });
        return;
      }
      this.version++;
      this.writeDoc({
        snapshot: snapshotOf(bill),
        version: this.version,
        intents: encodeIntents([])
      });
      this.onHostApply(bill);
      this.setPhase('online', `已应用 ${applied} 条认领`);
    } else if (this.role === RoomRole.GUEST) {
      if (remote.snapshot.length > 0 && remote.version >= this.version) {
        this.version = remote.version;
        const bill = restoreSnapshot(remote.snapshot);
        if (bill) {
          this.onGuestSnapshot(bill);
          this.setPhase('online', `账本已同步 v${remote.version}`);
        }
      }
    }
  }

  /** host 应用完意图后回调，由 AppContext 接上本地账单 */
  onHostApply: (bill: Bill) => void = () => {};

  /** guest 收到快照后回调 */
  onGuestSnapshot: (bill: Bill) => void = () => {};

  /** 写共享对象；DDO 会自动同步到同 sessionId 的其他设备 */
  private writeDoc(patch: Partial<RoomDoc>): void {
    if (!this.doc) {
      return;
    }
    // 直接改传入 create() 的那份对象，DDO 才能观测到变更
    const target: RoomDoc = this.doc;
    if (patch.snapshot !== undefined) {
      target.snapshot = patch.snapshot;
    }
    if (patch.version !== undefined) {
      target.version = patch.version;
    }
    if (patch.intents !== undefined) {
      target.intents = patch.intents;
    }
    if (patch.phase !== undefined) {
      target.phase = patch.phase;
    }
    if (this.doc) {
      if (patch.snapshot !== undefined) {
        this.doc.snapshot = patch.snapshot;
      }
      if (patch.version !== undefined) {
        this.doc.version = patch.version;
      }
      if (patch.intents !== undefined) {
        this.doc.intents = patch.intents;
      }
    }
  }

  /** host：本地账单变了（例如新增了菜），推新快照 */
  pushSnapshot(bill: Bill): void {
    if (this.role !== RoomRole.HOST) {
      return;
    }
    this.version++;
    this.writeDoc({ snapshot: snapshotOf(bill), version: this.version });
  }

  /** guest：提交一条认领意图给 host */
  submitIntent(op: 'claim' | 'release', dishId: string, participantId: string): void {
    if (this.role !== RoomRole.GUEST || !this.ddo || !this.doc) {
      return;
    }
    const intent: ClaimIntent = {
      intentId: `${Date.now()}_${Math.floor(Math.random() * 100000)}`,
      op: op,
      dishId: dishId,
      participantId: participantId,
      fromDevice: this.deviceName,
      at: Date.now()
    };
    const list = decodeIntents(this.doc.intents);
    list.push(intent);
    this.writeDoc({ intents: encodeIntents(list) });
  }

  async leave(): Promise<void> {
    if (this.ddo) {
      try {
        await this.ddo.setSessionId('');
      } catch (_e) {
        // 退出失败不阻断流程
      }
      this.ddo = undefined;
    }
    this.doc = null;
    this.role = RoomRole.NONE;
    this.phase = 'idle';
    this.version = 0;
    this.peerCount = 0;
    this.consumed.clear();
    this.emit();
  }

  isHost(): boolean {
    return this.role === RoomRole.HOST;
  }

  isInRoom(): boolean {
    return this.role !== RoomRole.NONE;
  }

  currentSessionId(): string {
    return this.doc ? this.doc.sessionId : '';
  }
}

/** DDO 抛出的错误形状 */
interface BusinessError {
  code?: number;
  message?: string;
}
