/**
 * 房间协议断言：验证认领意图的幂等性、去重、快照往返。
 * 这些是跨设备同步最容易出错、又最难在真机上复现的部分，所以单独测。
 */

// ---- 与 Protocol.ets 同源的实现 ----
function isValidSessionId(id) {
  if (id.length === 0 || id.length > 128) return false;
  return /^[A-Za-z0-9_]+$/.test(id);
}
function decodeIntents(raw) {
  if (!raw || raw.length === 0) return [];
  try {
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return [];
    return arr.filter(i => i.intentId !== undefined && i.dishId !== undefined);
  } catch { return []; }
}
function applyIntent(bill, intent) {
  const exists = bill.claims.some(c => c.dishId === intent.dishId && c.participantId === intent.participantId);
  if (intent.op === 'claim') {
    if (exists) return false;
    bill.claims.push({ dishId: intent.dishId, participantId: intent.participantId });
    return true;
  }
  if (intent.op === 'release') {
    if (!exists) return false;
    const idx = bill.claims.findIndex(c => c.dishId === intent.dishId && c.participantId === intent.participantId);
    bill.claims.splice(idx, 1);
    return true;
  }
  return false;
}
function applyIntents(bill, intents) {
  let n = 0;
  for (const it of intents) if (applyIntent(bill, it)) n++;
  return n;
}

let pass = 0, fail = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) pass++;
  else { fail++; console.log(`FAIL ${name}\n  got      ${JSON.stringify(actual)}\n  expected ${JSON.stringify(expected)}`); }
}

const mkBill = () => ({
  participants: [{ id: 'me', name: '我', isPayer: true }, { id: 'liu', name: '小刘', isPayer: false }],
  dishes: [{ id: 'd1', name: '火锅', unitPriceCents: 10000, quantity: 1 }],
  claims: [], extraCents: 0
});

const intent = (id, op, dishId, pid) => ({ intentId: id, op, dishId, participantId: pid, fromDevice: 'g', at: 1 });

// 1. 基本认领
let b = mkBill();
check('单条 claim 生效', applyIntents(b, [intent('i1', 'claim', 'd1', 'liu')]), 1);
check('claim 后状态', b.claims.length, 1);

// 2. 重复投递同一条意图 -> 不应重复生效
check('重复意图不生效', applyIntents(b, [intent('i1', 'claim', 'd1', 'liu')]), 0);
check('重复后仍只有一条', b.claims.length, 1);

// 3. 同一个人对同一道菜的两次不同意图 -> 第二次也不应重复
check('同目标二次 claim 不生效', applyIntents(b, [intent('i2', 'claim', 'd1', 'liu')]), 0);

// 4. release 生效
check('release 生效', applyIntents(b, [intent('i3', 'release', 'd1', 'liu')]), 1);
check('release 后为空', b.claims.length, 0);

// 5. release 不存在的认领 -> 不生效
check('release 不存在不生效', applyIntents(b, [intent('i4', 'release', 'd1', 'liu')]), 0);

// 6. 乱序：先 release 后 claim -> claim 最终生效
b = mkBill();
applyIntents(b, [intent('a', 'release', 'd1', 'liu'), intent('b', 'claim', 'd1', 'liu')]);
check('乱序后以最后一次为准', b.claims.length, 1);

// 7. 多人各认各的
b = mkBill();
applyIntents(b, [intent('x', 'claim', 'd1', 'me'), intent('y', 'claim', 'd1', 'liu')]);
check('两人共吃各一条', b.claims.length, 2);

// 8. sessionId 校验
check('合法 sessionId', isValidSessionId('fenben_abc123_xyz'), true);
check('空 sessionId 非法', isValidSessionId(''), false);
check('中文 sessionId 非法', isValidSessionId('fenben_中文'), false);
check('超长 sessionId 非法', isValidSessionId('a'.repeat(129)), false);
check('带横线非法（DDO 不允许）', isValidSessionId('fenben-abc'), false);

// 9. 意图序列化往返
const raw = JSON.stringify([intent('i9', 'claim', 'd1', 'me')]);
check('意图往返', decodeIntents(raw).length, 1);
check('坏数据返回空数组', decodeIntents('{not json').length, 0);
check('非数组返回空', decodeIntents('{"a":1}').length, 0);
check('空串返回空', decodeIntents('').length, 0);

// 10. 快照往返：账单 JSON 解析后结构完整
b = mkBill();
applyIntents(b, [intent('s1', 'claim', 'd1', 'liu')]);
const snap = JSON.stringify(b);
const restored = JSON.parse(snap);
check('快照保留认领', restored.claims.length, 1);
check('快照保留菜品', restored.dishes.length, 1);

// 11. 重复意图 + 新意图混合：只应用新的
b = mkBill();
applyIntents(b, [intent('m1', 'claim', 'd1', 'me')]);
const applied = applyIntents(b, [intent('m1', 'claim', 'd1', 'me'), intent('m2', 'claim', 'd1', 'liu')]);
check('混合批次只算新的', applied, 1);
check('混合后两条认领', b.claims.length, 2);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
