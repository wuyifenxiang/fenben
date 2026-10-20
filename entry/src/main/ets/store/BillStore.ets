/**
 * 账单的内存态管理 + 本地持久化。
 *
 * 只依赖 ArkData preferences，不引入额外依赖；账单本体以 JSON 字符串存一份。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Bill, Claim, Dish, Participant } from '../model/Bill';

const STORE_NAME = 'fenben_bills';
const KEY_CURRENT = 'current_bill';

/** 头像可选色板 */
export const AVATAR_COLORS: string[] = [
  '#FF6B6B', '#4ECDC4', '#FFD93D', '#6C5CE7',
  '#FF9F43', '#26DE81', '#45AAF2', '#FD79A8'
];

export function newId(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 10000)}`;
}

/** 创建一个空账单，第一位参与者是付款人 */
export function createBill(title: string): Bill {
  const payer: Participant = {
    id: newId('p'),
    name: '我（付款人）',
    isPayer: true,
    color: AVATAR_COLORS[0]
  };
  return {
    id: newId('b'),
    title: title.length > 0 ? title : '今天的账单',
    createdAt: Date.now(),
    extraCents: 0,
    participants: [payer],
    dishes: [],
    claims: []
  };
}

/** 往账单里加人，自动分配颜色 */
export function addParticipant(bill: Bill, name: string): Participant {
  const p: Participant = {
    id: newId('p'),
    name: name,
    isPayer: false,
    color: AVATAR_COLORS[bill.participants.length % AVATAR_COLORS.length]
  };
  bill.participants.push(p);
  return p;
}

export function addDish(bill: Bill, name: string, unitPriceCents: number, quantity: number): Dish {
  const d: Dish = {
    id: newId('d'),
    name: name,
    unitPriceCents: unitPriceCents,
    quantity: quantity
  };
  bill.dishes.push(d);
  return d;
}

/** 切换认领状态，返回切换后的结果 */
export function toggleClaim(bill: Bill, dishId: string, participantId: string): boolean {
  const idx = bill.claims.findIndex(c => c.dishId === dishId && c.participantId === participantId);
  if (idx >= 0) {
    bill.claims.splice(idx, 1);
    return false;
  }
  const claim: Claim = { dishId: dishId, participantId: participantId };
  bill.claims.push(claim);
  return true;
}

/** 一次碰一碰：让某人认领某道菜（幂等，已认领则保持） */
export function claimByTap(bill: Bill, dishId: string, participantId: string): boolean {
  if (bill.claims.some(c => c.dishId === dishId && c.participantId === participantId)) {
    return false;
  }
  toggleClaim(bill, dishId, participantId);
  return true;
}

export class BillStore {
  private pf?: preferences.Preferences;

  async load(context: common.Context): Promise<void> {
    this.pf = await preferences.getPreferences(context, { name: STORE_NAME });
  }

  private ensure(): preferences.Preferences {
    if (!this.pf) {
      throw new Error('BillStore not loaded');
    }
    return this.pf;
  }

  /** 读取上次未结束的账单；没有则返回 null */
  async loadCurrent(): Promise<Bill | null> {
    const raw = this.ensure().getSync(KEY_CURRENT, '') as string;
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as Bill;
    } catch (_e) {
      return null;
    }
  }

  async saveCurrent(bill: Bill): Promise<void> {
    this.ensure().putSync(KEY_CURRENT, JSON.stringify(bill));
    await this.ensure().flush();
  }

  async clearCurrent(): Promise<void> {
    this.ensure().putSync(KEY_CURRENT, '');
    await this.ensure().flush();
  }
}
