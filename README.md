# 分账本 FenBen

鸿蒙（HarmonyOS NEXT）原生分账应用。聚餐后每人碰一下手机，认领自己吃掉的那几道菜，实时算出各自应付多少，并给出「谁转给谁」的最少转账方案。

> 选这个方向的前置调研：GitHub 上 `鸿蒙 分账`、`碰一碰 分账`、`harmonyos split bill AA` 均为 **0 个项目**；
> 现有 AA 记账类应用都是**事后手动录入**，没有人做「碰一碰参与者认领」这条链路。

## 当前状态（P0 已完成）

**跨设备房间已接通，碰一碰触发已实现，但尚未在真机上验证。**

| 能力 | 状态 |
| --- | --- |
| 建账单（加人 / 加菜 / 份数 / 价格） | ✅ 已完成 |
| 认领（点选 + 碰一碰入口） | ✅ 已完成 |
| 分摊计算（含除不尽余数、服务费均摊） | ✅ 已完成，15 条断言全过 |
| 结算（每人应付 + 最少转账方案） | ✅ 已完成 |
| 复制账单文本发群 | ✅ 已完成 |
| 本地持久化（preferences） | ✅ 已完成 |
| **房间模型（主从：付款人为权威）** | ✅ 已完成 |
| **跨设备账本同步（distributedDataObject）** | ✅ 已完成，未上真机 |
| **碰一碰邀请（harmonyShare.knockShare）** | ✅ 已完成，未上真机 |
| 认领意图幂等 / 去重 / 乱序 | ✅ 已完成，23 条断言全过 |
| 离线降级（手输房间号） | ✅ 已完成 |

已验证的构建方式（DevEco Studio SDK API 26 / hvigor 6.26.8）：

```
hvigorw assembleHap --mode module -p product=default
→ BUILD SUCCESSFUL
→ entry/build/default/outputs/default/entry-default-unsigned.hap（约 270 KB）
```

## 为什么工程放在这个路径

hvigor 对项目路径有硬性限制（错误码 `00306003`），路径只允许字母、数字、`-_.()@` 和空格。
**含中文的路径（例如 `桌面/代码/`）会导致构建直接失败**，所以本工程放在 `C:\Users\86185\Desktop\fenben`。
用 DevEco Studio 打开时也请保持这个 ASCII 路径，不要把工程拖回中文目录。

## 目录结构

```
fenben/
├── AppScope/
│   ├── app.json5                      bundleName / 版本
│   └── resources/base/                应用级图标与名称
├── entry/
│   └── src/main/
│       ├── module.json5               模块声明与权限
│       ├── ets/
│       │   ├── entryability/EntryAbility.ets
│       │   ├── model/Bill.ets         领域模型 + 分摊算法（全部金额在此计算）
│       │   ├── room/
│       │   │   ├── Protocol.ets       房间协议：意图、快照、合并规则
│       │   │   ├── RoomService.ets    DDO 会话，host/guest 角色
│       │   │   └── KnockService.ets   碰一碰（knockShare）凭证传递
│       │   ├── store/BillStore.ets    账单增删改 + preferences 持久化
│       │   ├── store/AppContext.ets   应用级单例（账单 + 房间的唯一入口）
│       │   ├── utils/TapService.ets   分布式能力探测与降级
│       │   └── pages/
│       │       ├── Index.ets          建账单：加人、加菜
│       │       ├── ClaimPage.ets      认领：host 直改 / guest 提意图
│       │       ├── RoomPage.ets       开房间 / 入房 / 退出
│       │       └── SettlePage.ets     结算：每人应付 + 转账方案
│       └── resources/                 页面清单、字符串、颜色、图标
└── scripts/
    ├── verify-split.cjs               分摊算法断言（15 条）
    └── verify-room.cjs                房间协议断言（23 条）
```

## P0 设计：主从房间

选型理由：认领是**低频操作**，用主从模型换「可验证性」。多主同步要为字段级合并和冲突提示付出代价，
而一旦出现「我的认领被悄悄覆盖」这类问题，在真机上极难复现。

```
付款人（host）                      参与者（guest）
   │                                   │
   │  ① 开房间 → sessionId             │
   │  ② 碰一碰分享凭证 ──────────────► │  ③ 收到凭证 → 加入
   │                                   │
   │                                   │  ④ 点菜 → submitIntent（不改账本）
   │  ⑤ 收到意图 → 应用到权威账单      │
   │  ⑥ 广播新快照 (version+1) ──────► │  ⑦ 收到快照 → 刷新界面
```

**关键约束**：任何时刻只有 host 持有权威账单。guest 只提交意图，不直接改数据。

### 协议要点

- **载体**：`distributedDataObject`，同一 `sessionId` 的可信设备自动同步
- **共享对象**：`{ sessionId, snapshot, version, intents, hostName, phase }`
- **意图幂等**：`applyIntent` 对已存在的 claim 返回 false，重复投递不会重复计价
- **乱序安全**：先 release 后 claim 以最后一次为准，不依赖到达顺序
- **去重**：host 记录已消费的 `intentId`，同一条意图只应用一次
- **坏数据隔离**：`decodeIntents`/`restoreSnapshot` 解析失败返回空值，一条坏数据不会卡死整个房间

## 权限与能力核实（重要）

P0 实现前逐一核实了 SDK 中所有相关能力，结论如下：

| 能力 | 权限 | 级别 | 结论 |
| --- | --- | --- | --- |
| `harmonyShare.knockShare` | **无 `@permission`** | 普通 | ✅ 可用，API 12+ |
| `distributedDataObject` | `DISTRIBUTED_DATASYNC` | user_grant / normal | ✅ 可用 |
| `nfc.tag` readerMode | `NFC_TAG` | system_grant / normal | ✅ 可用 |
| `serviceInteraction` | `KNOCK_COLLABORATION` | **system_basic** | ❌ 普通应用不可用 |

**注意别把 `knockShare` 和 `KNOCK_COLLABORATION` 搞混**：前者是系统敲一敲分享，无权限标注；
后者属于 `serviceInteraction` 接口，是 `system_basic` 级，上架过不了。

**能力边界**：`knockShare` 只提供**单向 `share(data)`**，不是双向通道。
所以它只负责把「入房凭证」递给对方，账本同步仍走 DDO。

## 分摊规则（与 UI 上一致）

1. 每道菜按「份」计价，`单价 × 份数` 是这份菜的钱。
2. 一份菜由**认领它的人平均分摊**；没人认领则该金额计入「未认领」，不会悄悄消失。
3. 服务费 / 折扣（`extraCents`）按**人头**均摊，可为负。
4. 全程用整数「分」运算，除不尽时余数补给第一个认领人，**保证合计守衡**。
5. 转账方案用贪心撮合，让「欠最多」和「应收最多」配对，转账笔数最少。

## 验证

```bash
node scripts/verify-split.cjs   # 15 passed
node scripts/verify-room.cjs    # 23 passed
```

分摊侧覆盖：两人共吃、三人除不尽（100 分 → 34/33/33 且合计守衡）、未认领、份数计价、服务费+折扣、无转账。
房间侧覆盖：基本认领、重复投递、二次 claim、release、release 不存在、乱序、多人共吃、sessionId 校验、意图序列化、快照往返、混合批次。

## 真机验证清单（下一步）

以下**都还没做**，因为当前没有可用设备：

- [ ] 两台鸿蒙设备是否能在 `distributedDeviceManager` 中发现彼此（**这是前置条件，不通则后续全不成立**）
- [ ] `DISTRIBUTED_DATASYNC` 授权弹窗是否正常弹出
- [ ] 开房间 → 碰一碰 → 对端是否真的收到凭证并入房
- [ ] guest 提交认领后，host 账本是否在 1 秒内更新
- [ ] host 加菜后，guest 是否收到新快照
- [ ] 杀掉 guest 再重进，快照是否正确重拉
- [ ] 两机同时认领不同菜，是否都不丢
- [ ] 深色配色在真实屏幕上的观感、软键盘是否顶起按钮

## Roadmap

### P1 · 结算体验
- 收款码 / 支付拉起：需要企业资质与支付 SDK，当前只做到「复制账单文本」。
- guest 端结算页展示（现在 guest 能看到账本，但复制文案里应标注「以付款人账单为准」）。

### P2 · 产品化
- 历史账单列表与统计。
- 服务卡片（元服务）：未结束的账单显示在桌面。
- 实况窗：把「还有 3 人没认领」做成常驻胶囊。
- NFC 标签路径：付款人写一张贴纸，他人碰一下入房（`NFC_TAG` 权限已声明，监听逻辑待补）。

## 已知限制

- **未签名**：产出 `entry-default-unsigned.hap`，装机需在 DevEco 配置签名。
- **未上真机**：房间同步与碰一碰只在编译和逻辑层面验证，跨设备行为完全没跑过。
- **依赖可信网络**：DDO 的同步前提是设备处于可信/已组网状态，未组网时房间不会生效，UI 会显示离线。
- **guest 无本地历史**：guest 的账单来自快照，退出房间后本地不留存。
- **碰一碰不可用时**：自动降级为手动粘贴房间号，功能不受影响。

## 运行

```bash
# 构建
export DEVECO_SDK_HOME="E:/deveco-studio/DevEco Studio/sdk"
"E:/deveco-studio/DevEco Studio/tools/hvigor/bin/hvigorw.bat" \
  assembleHap --mode module -p product=default

# 校验
node scripts/verify-split.cjs
node scripts/verify-room.cjs
```

日常开发直接用 DevEco Studio 打开 `C:\Users\86185\Desktop\fenben` 即可。
