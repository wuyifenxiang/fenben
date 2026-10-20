/**
 * 认领页：本项目的核心交互。
 *
 * 两种角色走不同路径：
 * - host（付款人）：直接改本地账单，然后 pushSnapshot 广播；
 * - guest：不碰账本，只 submitIntent 给 host，等快照回来再刷新。
 * 这样保证任何时刻只有 host 持有权威账单。
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppContext } from '../store/AppContext';
import { Bill, Participant, Dish, computeBill, formatCents, dishLineTotal, hasClaimed, claimCountOf } from '../model/Bill';
import { toggleClaim } from '../store/BillStore';
import { RoomState } from '../room/RoomService';
import { RoomRole } from '../room/Protocol';
import { TapService, TapCapability } from '../utils/TapService';

@Entry
@Component
struct ClaimPage {
  @State bill: Bill = AppContext.instance().ensureBill();
  @State activeId: string = AppContext.instance().activeParticipantId;
  @State tapCap: TapCapability = {
    dmAvailable: false, granted: false, trustedDeviceCount: 0, summary: '正在检查碰一碰能力…'
  };
  @State roomState: RoomState = AppContext.instance().room.state();
  @State tapHint: string = '';
  private ctx: AppContext = AppContext.instance();
  private probed: boolean = false;

  aboutToAppear(): void {
    if (this.activeId.length === 0 && this.bill.participants.length > 0) {
      this.activeId = this.bill.participants[0].id;
    }
    this.ctx.addBillListener(this.onBillChanged);
    this.ctx.room.addListener(this.onRoomChanged);
    this.roomState = this.ctx.room.state();
    this.probe();
  }

  aboutToDisappear(): void {
    this.ctx.removeBillListener(this.onBillChanged);
    this.ctx.room.removeListener(this.onRoomChanged);
  }

  private onBillChanged = (): void => {
    this.bill = this.ctx.ensureBill();
  };

  private onRoomChanged = (s: RoomState): void => {
    this.roomState = s;
  };

  private async probe(): Promise<void> {
    if (this.probed) {
      return;
    }
    this.probed = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      let cap = await TapService.probe(context);
      if (!cap.granted) {
        const ok = await TapService.requestPermission(context);
        if (ok) {
          cap = await TapService.probe(context);
        }
      }
      this.tapCap = cap;
    } catch (_e) {
      this.tapCap = {
        dmAvailable: false, granted: false, trustedDeviceCount: 0, summary: '碰一碰不可用，用点选认领'
      };
    }
  }

  private activeName(): string {
    const p = this.bill.participants.find(x => x.id === this.activeId);
    return p ? p.name : '未选择';
  }

  /**
   * 认领一道菜。
   * host 直接改并广播；guest 只发意图，等 host 回传快照。
   */
  private onClaimDish(dish: Dish): void {
    if (this.activeId.length === 0) {
      this.tapHint = '先在上方选一下现在是谁';
      return;
    }
    const role = this.ctx.room.state().role;
    if (role === RoomRole.GUEST) {
      const already = hasClaimed(this.bill, dish.id, this.activeId);
      this.ctx.room.submitIntent(already ? 'release' : 'claim', dish.id, this.activeId);
      this.tapHint = already
        ? `已请求撤销「${dish.name}」，等付款人确认`
        : `已把「${dish.name}」的认领发给付款人`;
      return;
    }
    toggleClaim(this.bill, dish.id, this.activeId);
    this.tapHint = `${this.activeName()} 的认领状态已更新`;
    this.ctx.commit().catch(() => {});
  }

  private onToggle(dish: Dish, p: Participant): void {
    const role = this.ctx.room.state().role;
    if (role === RoomRole.GUEST) {
      const already = hasClaimed(this.bill, dish.id, p.id);
      this.ctx.room.submitIntent(already ? 'release' : 'claim', dish.id, p.id);
      this.tapHint = `已请求更新「${p.name}」的认领`;
      return;
    }
    toggleClaim(this.bill, dish.id, p.id);
    this.ctx.commit().catch(() => {});
  }

  /** 房间状态条文案 */
  private roomBanner(): string {
    const s = this.roomState;
    if (s.role === RoomRole.NONE) {
      return '未加入房间 · 单机模式';
    }
    const roleText = s.role === RoomRole.HOST ? '付款人（权威）' : '参与者';
    return `${roleText} · ${s.lastMessage}`;
  }

  private roomColor(): string {
    const s = this.roomState;
    if (s.role === RoomRole.NONE) {
      return '#5C6577';
    }
    if (s.phase === 'online') {
      return '#26DE81';
    }
    if (s.phase === 'error') {
      return '#FF6B6B';
    }
    return '#FFD93D';
  }

  build(): void {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#8E97A8')
          .onClick(() => { router.back(); })
        Blank()
        Text(`合计 ¥${formatCents(computeBill(this.bill).totalCents)}`)
          .fontSize(15)
          .fontColor('#E8ECF4')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 52, bottom: 10 })

      // 房间状态 + 入房入口
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 }).fill(this.roomColor())
        Text(this.roomBanner())
          .fontSize(12)
          .fontColor('#8E97A8')
          .layoutWeight(1)
        Text(this.roomState.role === RoomRole.NONE ? '开房间' : '房间')
          .fontSize(12)
          .fontColor('#4162FF')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('#1E222C')
          .borderRadius(12)
          .onClick(() => { router.pushUrl({ url: 'pages/RoomPage' }).catch(() => {}); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 10 })

      // 当前认领人
      Column({ space: 8 }) {
        Text('现在是谁在认领')
          .fontSize(12)
          .fontColor('#8E97A8')
          .width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.bill.participants, (p: Participant) => {
            Row({ space: 6 }) {
              Circle({ width: 9, height: 9 }).fill(p.color)
              Text(p.name).fontSize(13).fontColor(p.id === this.activeId ? '#12141A' : '#E8ECF4')
            }
            .padding({ left: 12, right: 14, top: 9, bottom: 9 })
            .margin({ right: 8, bottom: 8 })
            .backgroundColor(p.id === this.activeId ? '#4ECDC4' : '#1E222C')
            .borderRadius(18)
            .onClick(() => {
              this.activeId = p.id;
              this.ctx.activeParticipantId = p.id;
            })
          }, (p: Participant) => p.id)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      // 碰一碰能力提示（仅在单机时展示，避免干扰）
      if (this.roomState.role === RoomRole.NONE) {
        Row({ space: 8 }) {
          Circle({ width: 8, height: 8 })
            .fill(this.tapCap.dmAvailable ? '#26DE81' : '#FF9F43')
          Text(this.tapCap.summary)
            .fontSize(12)
            .fontColor('#8E97A8')
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 8 })
      }

      if (this.tapHint.length > 0) {
        Text(this.tapHint)
          .fontSize(12)
          .fontColor('#4ECDC4')
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 6 })
      }

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.bill.dishes, (d: Dish) => {
            Column({ space: 8 }) {
              Row() {
                Column({ space: 2 }) {
                  Text(d.name).fontSize(16).fontColor('#E8ECF4')
                  Text(`¥${formatCents(dishLineTotal(d))} · ${claimCountOf(this.bill, d.id)} 人认领`)
                    .fontSize(12)
                    .fontColor('#8E97A8')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text(this.activeId.length > 0 && hasClaimed(this.bill, d.id, this.activeId) ? '已认领' : '碰一下')
                  .fontSize(12)
                  .fontColor(this.activeId.length > 0 && hasClaimed(this.bill, d.id, this.activeId) ? '#26DE81' : '#4162FF')
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor('#222834')
                  .borderRadius(14)
                  .onClick(() => { this.onClaimDish(d); })
              }
              .width('100%')

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.bill.participants, (p: Participant) => {
                  Row({ space: 4 }) {
                    Circle({ width: 7, height: 7 })
                      .fill(hasClaimed(this.bill, d.id, p.id) ? p.color : '#3A4152')
                    Text(p.name)
                      .fontSize(11)
                      .fontColor(hasClaimed(this.bill, d.id, p.id) ? '#E8ECF4' : '#5C6577')
                  }
                  .padding({ left: 8, right: 10, top: 6, bottom: 6 })
                  .margin({ right: 6, bottom: 6 })
                  .backgroundColor(hasClaimed(this.bill, d.id, p.id) ? '#242A36' : '#191D26')
                  .borderRadius(12)
                  .onClick(() => { this.onToggle(d, p); })
                }, (p: Participant) => p.id)
              }
              .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#1A1E27')
            .borderRadius(14)
          }, (d: Dish) => d.id)
        }
        .padding({ left: 20, right: 20, bottom: 24 })
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Button('去结算')
        .width('100%')
        .height(50)
        .backgroundColor('#4162FF')
        .fontColor('#FFFFFF')
        .fontSize(16)
        .margin({ left: 20, right: 20, top: 12, bottom: 28 })
        .onClick(() => {
          router.pushUrl({ url: 'pages/SettlePage' }).catch(() => {});
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#12141A')
  }
}
