/**
 * 房间同步协议。
 *
 * 模型（A：主从房间）：
 * - 付款人设备是 host，持有权威账单快照（BillSnapshot）。
 * - 其他人是 guest，通过 DDO 会话加入，提交「认领意图」（ClaimIntent）。
 * - host 收到意图后应用到自己的账单，再把新快照广播回去。
 *
 * 为什么不让 guest 直接写账单：认领是低频操作，主从模型下不存在字段级合并冲突，
 * guest 断线重连时只需重新拉一次快照即可，逻辑可验证。
 *
 * 同步载体：distributedDataObject 的共享对象（结构必须可 JSON 序列化）。
 * 注意 DDO 的同步是「整个对象属性的变化」，所以这里刻意把三类数据分开存放，
 * 避免一次认领导致整张账单重传。
 */

import { Bill, Claim } from '../model/Bill';

/** 会话角色 */
export enum RoomRole {
  /** 未入房 */
  NONE = 'none',
  /** 付款人，权威方 */
  HOST = 'host',
  /** 参与者 */
  GUEST = 'guest'
}

/** 一条认领意图：guest 提交给 host 的最小指令 */
export interface ClaimIntent {
  /** 意图唯一 id，用于 host 去重（重复投递不会重复生效） */
  intentId: string;
  /** 操作类型 */
  op: 'claim' | 'release';
  dishId: string;
  participantId: string;
  /** 发起方设备标识，便于排查 */
  fromDevice: string;
  /** 客户端时间戳，仅用于展示，不参与合并判定 */
  at: number;
}

/** DDO 上承载的共享对象结构 */
export interface RoomDoc {
  /** 会话 id，同时是 DDO 的 sessionId */
  sessionId: string;
  /** 账单快照 JSON（host 写，guest 读） */
  snapshot: string;
  /** 快照版本号，host 每应用一次变更 +1 */
  version: number;
  /** 待处理的认领意图（guest 追加，host 消费后清空） */
  intents: string;
  /** host 的设备名，用于 UI 展示 */
  hostName: string;
  /** 房间状态 */
  phase: string;
}

/** 房间状态常量 */
export class ROOM_PHASE {
  static readonly OPEN: string = 'open';
  static readonly CLOSED: string = 'closed';
}

/**
 * 生成 sessionId。
 * DDO 要求：只允许字母、数字、下划线，长度 ≤ 128。
 */
export function newSessionId(): string {
  const ts = Date.now().toString(36);
  const rand = Math.floor(Math.random() * 1e9).toString(36);
  return `fenben_${ts}_${rand}`;
}

/** 校验一个 sessionId 是否合法（用于扫码/碰一碰传入的参数） */
export function isValidSessionId(id: string): boolean {
  if (id.length === 0 || id.length > 128) {
    return false;
  }
  return /^[A-Za-z0-9_]+$/.test(id);
}

/** 把账单序列化为快照字符串 */
export function snapshotOf(bill: Bill): string {
  return JSON.stringify(bill);
}

/** 从快照还原账单；损坏的快照返回 null，由调用方决定是否降级 */
export function restoreSnapshot(snapshot: string): Bill | null {
  if (snapshot.length === 0) {
    return null;
  }
  try {
    const b = JSON.parse(snapshot) as Bill;
    if (!b.participants || !b.dishes || !b.claims) {
      return null;
    }
    return b;
  } catch (_e) {
    return null;
  }
}

/** 序列化意图列表 */
export function encodeIntents(list: ClaimIntent[]): string {
  return JSON.stringify(list);
}

/** 解析意图列表；非法内容返回空数组，避免一条坏数据卡死整个房间 */
export function decodeIntents(raw: string): ClaimIntent[] {
  if (raw.length === 0) {
    return [];
  }
  try {
    const arr = JSON.parse(raw) as ClaimIntent[];
    if (!Array.isArray(arr)) {
      return [];
    }
    return arr.filter(i => i.intentId !== undefined && i.dishId !== undefined);
  } catch (_e) {
    return [];
  }
}

/**
 * 把一条意图应用到账单上（host 侧调用）。
 *
 * 幂等性：claim 已在则跳过，release 不存在则跳过，
 * 所以重复投递、乱序投递都不会把账算错。
 * 返回是否真的改变了账单。
 */
export function applyIntent(bill: Bill, intent: ClaimIntent): boolean {
  const exists = bill.claims.some(c => c.dishId === intent.dishId && c.participantId === intent.participantId);
  if (intent.op === 'claim') {
    if (exists) {
      return false;
    }
    const c: Claim = { dishId: intent.dishId, participantId: intent.participantId };
    bill.claims.push(c);
    return true;
  }
  if (intent.op === 'release') {
    if (!exists) {
      return false;
    }
    const idx = bill.claims.findIndex(c => c.dishId === intent.dishId && c.participantId === intent.participantId);
    bill.claims.splice(idx, 1);
    return true;
  }
  return false;
}

/** 应用一批意图，返回实际生效的条数 */
export function applyIntents(bill: Bill, intents: ClaimIntent[]): number {
  let applied = 0;
  for (const it of intents) {
    if (applyIntent(bill, it)) {
      applied++;
    }
  }
  return applied;
}
