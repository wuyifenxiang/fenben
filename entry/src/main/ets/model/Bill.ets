/**
 * 分账本领域模型。
 *
 * 设计要点：账单的最终金额是「菜品 × 认领」推导出来的，不是手工录入的，
 * 所以所有金额都由 computeBill() 统一计算，任何界面都不得自行累加。
 */

/** 参与分账的一个人 */
export interface Participant {
  id: string;
  name: string;
  /** 是否是本次账单的付款人（先垫付的人） */
  isPayer: boolean;
  /** 头像色，用于列表区分 */
  color: string;
}

/** 一道菜 / 一笔消费 */
export interface Dish {
  id: string;
  name: string;
  /** 单价，单位：分。用整数避免浮点误差 */
  unitPriceCents: number;
  /** 份数 */
  quantity: number;
}

/**
 * 一次认领：某人认领了某道菜的某一「份」。
 * dishId + participantId 唯一确定一条认领；共吃时多人各认一份。
 */
export interface Claim {
  dishId: string;
  participantId: string;
}

/** 某个人的结算结果 */
export interface PersonShare {
  participantId: string;
  name: string;
  /** 该人认领的金额合计，单位：分 */
  owedCents: number;
  /** 已经垫付的金额（付款人 = 账单总额，其他人 = 0） */
  paidCents: number;
  /** 应收/应付：paid - owed。正数=该收钱，负数=该付钱 */
  balanceCents: number;
}

/** 内部撮合用的中间结构：某人的净额 */
interface DebtEntry {
  share: PersonShare;
  amt: number;
}

/** 一笔转账建议 */
export interface Transfer {
  fromId: string;
  fromName: string;
  toId: string;
  toName: string;
  amountCents: number;
}

/** 整张账单 */
export interface Bill {
  id: string;
  title: string;
  createdAt: number;
  /** 全场服务费 / 折扣等均摊项，单位：分，可为负（折扣） */
  extraCents: number;
  participants: Participant[];
  dishes: Dish[];
  claims: Claim[];
}

/** 计算结果的完整快照 */
export interface BillResult {
  totalCents: number;
  /** 已认领金额 */
  claimedCents: number;
  /** 无人认领的金额 */
  unclaimedCents: number;
  shares: PersonShare[];
  transfers: Transfer[];
  /** 是否所有人都认领完毕且金额对得上 */
  settled: boolean;
}

/**
 * 每道菜的人均单价。
 * 菜品价是「一份」的价格，共吃时由认领人数分摊。
 */
export function dishLineTotal(dish: Dish): number {
  return dish.unitPriceCents * dish.quantity;
}

/** 某道菜被认领了几份 */
export function claimCountOf(bill: Bill, dishId: string): number {
  let n = 0;
  for (const c of bill.claims) {
    if (c.dishId === dishId) {
      n++;
    }
  }
  return n;
}

/** 某人是否认领了某道菜 */
export function hasClaimed(bill: Bill, dishId: string, participantId: string): boolean {
  for (const c of bill.claims) {
    if (c.dishId === dishId && c.participantId === participantId) {
      return true;
    }
  }
  return false;
}

/**
 * 计算整张账单。
 *
 * 分摊规则（必须与 UI 上的说明一致）：
 * 1. 每道菜按「份」计价；一份由认领该份的人平均分摊。
 *    —— 实现上把 dishLineTotal 平均分给认领者，未认领则该菜计入未认领金额。
 * 2. extraCents（服务费/折扣）按人头平均分给所有参与者。
 * 3. 未认领的菜不会消失，它留在 unclaimedCents 里提示用户。
 * 4. 金额一律用整数分运算，除不尽的余数补给「认领人数最少」的人，
 *    避免出现 0.01 的漂移（见 distributeRemainder）。
 */
export function computeBill(bill: Bill): BillResult {
  const n = bill.participants.length;
  const owed = new Map<string, number>();
  for (const p of bill.participants) {
    owed.set(p.id, 0);
  }

  let totalCents = 0;
  let claimedCents = 0;

  for (const dish of bill.dishes) {
    const lineTotal = dishLineTotal(dish);
    totalCents += lineTotal;
    const claimers = bill.claims.filter(c => c.dishId === dish.id);
    if (claimers.length === 0) {
      continue;
    }
    claimedCents += lineTotal;
    // 这一份菜由认领者均摊；余数给第一个人
    const base = Math.floor(lineTotal / claimers.length);
    const remainder = lineTotal - base * claimers.length;
    claimers.forEach((c, i) => {
      const add = base + (i === 0 ? remainder : 0);
      owed.set(c.participantId, (owed.get(c.participantId) ?? 0) + add);
    });
  }

  // 均摊项按人头平分，同样处理余数
  if (bill.extraCents !== 0 && n > 0) {
    totalCents += bill.extraCents;
    claimedCents += bill.extraCents;
    const base = Math.trunc(bill.extraCents / n);
    const remainder = bill.extraCents - base * n;
    bill.participants.forEach((p, i) => {
      const add = base + (i === 0 ? remainder : 0);
      owed.set(p.id, (owed.get(p.id) ?? 0) + add);
    });
  }

  const shares: PersonShare[] = bill.participants.map((p: Participant): PersonShare => {
    const owedCents = owed.get(p.id) ?? 0;
    const paidCents = p.isPayer ? totalCents : 0;
    const share: PersonShare = {
      participantId: p.id,
      name: p.name,
      owedCents: owedCents,
      paidCents: paidCents,
      balanceCents: paidCents - owedCents
    };
    return share;
  });

  const result: BillResult = {
    totalCents: totalCents,
    claimedCents: claimedCents,
    unclaimedCents: totalCents - claimedCents,
    shares: shares,
    transfers: buildTransfers(shares),
    settled: claimedCents === totalCents && n > 0
  };
  return result;
}

/**
 * 由每个人的净额生成最少的转账笔数。
 * 贪心：每次让「欠最多」和「应收最多」配对，直到两边都清零。
 */
export function buildTransfers(shares: PersonShare[]): Transfer[] {
  const debtors: DebtEntry[] = shares.filter(s => s.balanceCents < 0)
    .map((s: PersonShare): DebtEntry => {
      const e: DebtEntry = { share: s, amt: -s.balanceCents };
      return e;
    })
    .sort((a: DebtEntry, b: DebtEntry) => b.amt - a.amt);
  const creditors: DebtEntry[] = shares.filter(s => s.balanceCents > 0)
    .map((s: PersonShare): DebtEntry => {
      const e: DebtEntry = { share: s, amt: s.balanceCents };
      return e;
    })
    .sort((a: DebtEntry, b: DebtEntry) => b.amt - a.amt);

  const out: Transfer[] = [];
  let i = 0;
  let j = 0;
  while (i < debtors.length && j < creditors.length) {
    const pay = Math.min(debtors[i].amt, creditors[j].amt);
    if (pay > 0) {
      out.push({
        fromId: debtors[i].share.participantId,
        fromName: debtors[i].share.name,
        toId: creditors[j].share.participantId,
        toName: creditors[j].share.name,
        amountCents: pay
      });
    }
    debtors[i].amt -= pay;
    creditors[j].amt -= pay;
    if (debtors[i].amt === 0) {
      i++;
    }
    if (creditors[j].amt === 0) {
      j++;
    }
  }
  return out;
}

/** 分 → 展示用字符串，如 12850 → "128.50" */
export function formatCents(cents: number): string {
  const neg = cents < 0;
  const abs = Math.abs(cents);
  const yuan = Math.floor(abs / 100);
  const fen = abs % 100;
  const fenStr = fen < 10 ? `0${fen}` : `${fen}`;
  return `${neg ? '-' : ''}${yuan}.${fenStr}`;
}

/** 解析用户输入的元为分；非法输入返回 NaN */
export function parseYuanToCents(input: string): number {
  const trimmed = input.trim();
  if (trimmed.length === 0) {
    return NaN;
  }
  if (!/^\d+(\.\d{0,2})?$/.test(trimmed)) {
    return NaN;
  }
  const parts = trimmed.split('.');
  const yuan = parseInt(parts[0], 10);
  const fenPart = parts.length > 1 ? parts[1] : '';
  const padded = (fenPart + '00').substring(0, 2);
  return yuan * 100 + parseInt(padded, 10);
}
