/**
 * 校验 Bill.ets 的分摊算法（用 TypeScript 语义手写同一套逻辑跑断言）。
 * 目的：确认「除不尽」「未认领」「转账撮合」三个边界不会算错钱。
 */

function buildTransfers(shares) {
  const debtors = shares.filter(s => s.balanceCents < 0)
    .map(s => ({ s, amt: -s.balanceCents })).sort((a, b) => b.amt - a.amt);
  const creditors = shares.filter(s => s.balanceCents > 0)
    .map(s => ({ s, amt: s.balanceCents })).sort((a, b) => b.amt - a.amt);
  const out = [];
  let i = 0, j = 0;
  while (i < debtors.length && j < creditors.length) {
    const pay = Math.min(debtors[i].amt, creditors[j].amt);
    if (pay > 0) out.push({ from: debtors[i].s.name, to: creditors[j].s.name, amountCents: pay });
    debtors[i].amt -= pay; creditors[j].amt -= pay;
    if (debtors[i].amt === 0) i++;
    if (creditors[j].amt === 0) j++;
  }
  return out;
}

function computeBill(bill) {
  const n = bill.participants.length;
  const owed = new Map(bill.participants.map(p => [p.id, 0]));
  let totalCents = 0, claimedCents = 0;

  for (const dish of bill.dishes) {
    const lineTotal = dish.unitPriceCents * dish.quantity;
    totalCents += lineTotal;
    const claimers = bill.claims.filter(c => c.dishId === dish.id);
    if (claimers.length === 0) continue;
    claimedCents += lineTotal;
    const base = Math.floor(lineTotal / claimers.length);
    const remainder = lineTotal - base * claimers.length;
    claimers.forEach((c, i) => {
      owed.set(c.participantId, owed.get(c.participantId) + base + (i === 0 ? remainder : 0));
    });
  }
  if (bill.extraCents !== 0 && n > 0) {
    totalCents += bill.extraCents; claimedCents += bill.extraCents;
    const base = Math.trunc(bill.extraCents / n);
    const remainder = bill.extraCents - base * n;
    bill.participants.forEach((p, i) => {
      owed.set(p.id, owed.get(p.id) + base + (i === 0 ? remainder : 0));
    });
  }
  const shares = bill.participants.map(p => {
    const owedCents = owed.get(p.id);
    const paidCents = p.isPayer ? totalCents : 0;
    return { participantId: p.id, name: p.name, owedCents, paidCents, balanceCents: paidCents - owedCents };
  });
  return { totalCents, claimedCents, unclaimedCents: totalCents - claimedCents, shares, transfers: buildTransfers(shares), settled: claimedCents === totalCents && n > 0 };
}

let pass = 0, fail = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) { pass++; } else { fail++; console.log(`FAIL ${name}\n  got      ${JSON.stringify(actual)}\n  expected ${JSON.stringify(expected)}`); }
}

// 场景1：3人各认一道菜，价格 100/200/300 分
const b1 = {
  participants: [{ id: 'a', name: 'A', isPayer: true }, { id: 'b', name: 'B', isPayer: false }, { id: 'c', name: 'C', isPayer: false }],
  dishes: [{ id: 'd1', name: 'x', unitPriceCents: 100, quantity: 1 }, { id: 'd2', name: 'y', unitPriceCents: 200, quantity: 1 }, { id: 'd3', name: 'z', unitPriceCents: 300, quantity: 1 }],
  claims: [{ dishId: 'd1', participantId: 'a' }, { dishId: 'd2', participantId: 'b' }, { dishId: 'd3', participantId: 'c' }],
  extraCents: 0,
};
const r1 = computeBill(b1);
check('场景1 总额', r1.totalCents, 600);
check('场景1 已认领', r1.claimedCents, 600);
check('场景1 每人应付', r1.shares.map(s => s.owedCents), [100, 200, 300]);
check('场景1 转账', r1.transfers.map(t => [t.from, t.to, t.amountCents]),
  [['C', 'A', 300], ['B', 'A', 200]]);
check('场景1 转账合计等于应收', r1.transfers.reduce((s, t) => s + t.amountCents, 0), 500);
check('场景1 settled', r1.settled, true);

// 场景2：一道菜 100 分两人共吃 -> 各 50
const b2 = {
  participants: [{ id: 'a', name: 'A', isPayer: true }, { id: 'b', name: 'B', isPayer: false }],
  dishes: [{ id: 'd1', name: 'x', unitPriceCents: 100, quantity: 1 }],
  claims: [{ dishId: 'd1', participantId: 'a' }, { dishId: 'd1', participantId: 'b' }],
  extraCents: 0,
};
check('场景2 两人共吃各50', computeBill(b2).shares.map(s => s.owedCents), [50, 50]);

// 场景3：除不尽 100 分 3 人认领 -> 34/33/33，合计必须还是 100
const b3 = {
  participants: [{ id: 'a', name: 'A', isPayer: true }, { id: 'b', name: 'B', isPayer: false }, { id: 'c', name: 'C', isPayer: false }],
  dishes: [{ id: 'd1', name: 'x', unitPriceCents: 100, quantity: 1 }],
  claims: [{ dishId: 'd1', participantId: 'a' }, { dishId: 'd1', participantId: 'b' }, { dishId: 'd1', participantId: 'c' }],
  extraCents: 0,
};
const r3 = computeBill(b3);
check('场景3 除不尽分配', r3.shares.map(s => s.owedCents), [34, 33, 33]);
check('场景3 合计守恒', r3.shares.reduce((s, x) => s + x.owedCents, 0), 100);

// 场景4：未认领的菜要留在 unclaimed 里
const b4 = {
  participants: [{ id: 'a', name: 'A', isPayer: true }],
  dishes: [{ id: 'd1', name: 'x', unitPriceCents: 500, quantity: 1 }, { id: 'd2', name: 'y', unitPriceCents: 300, quantity: 1 }],
  claims: [{ dishId: 'd1', participantId: 'a' }],
  extraCents: 0,
};
const r4 = computeBill(b4);
check('场景4 未认领金额', r4.unclaimedCents, 300);
check('场景4 未结算', r4.settled, false);

// 场景5：份数 × 单价
const b5 = {
  participants: [{ id: 'a', name: 'A', isPayer: true }],
  dishes: [{ id: 'd1', name: 'beer', unitPriceCents: 800, quantity: 3 }],
  claims: [{ dishId: 'd1', participantId: 'a' }],
  extraCents: 0,
};
check('场景5 份数计价', computeBill(b5).totalCents, 2400);

// 场景6：服务费按人头均摊 + 折扣（负数）
const b6 = {
  participants: [{ id: 'a', name: 'A', isPayer: true }, { id: 'b', name: 'B', isPayer: false }],
  dishes: [{ id: 'd1', name: 'x', unitPriceCents: 1000, quantity: 1 }],
  claims: [{ dishId: 'd1', participantId: 'a' }, { dishId: 'd1', participantId: 'b' }],
  extraCents: 201,
};
const r6 = computeBill(b6);
check('场景6 均摊+余数', r6.shares.map(s => s.owedCents), [601, 600]);
check('场景6 总额', r6.totalCents, 1201);

// 场景7：所有人净额为0时不应产生转账
const b7 = {
  participants: [{ id: 'a', name: 'A', isPayer: true }],
  dishes: [{ id: 'd1', name: 'x', unitPriceCents: 100, quantity: 1 }],
  claims: [{ dishId: 'd1', participantId: 'a' }],
  extraCents: 0,
};
check('场景7 自己付自己吃无转账', computeBill(b7).transfers.length, 0);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
