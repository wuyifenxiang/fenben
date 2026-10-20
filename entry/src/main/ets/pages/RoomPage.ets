/**
 * 房间页：建房 / 入房 / 退出。
 *
 * host：开房间 → 拿到 sessionId → 碰一碰把凭证递给对方（降级：口头/手输房间号）
 * guest：碰一碰收到凭证自动入房（降级：手动粘贴房间号）
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppContext } from '../store/AppContext';
import { RoomState } from '../room/RoomService';
import { RoomRole } from '../room/Protocol';
import { KnockService } from '../room/KnockService';
import { TapService } from '../utils/TapService';

@Entry
@Component
struct RoomPage {
  @State roomState: RoomState = AppContext.instance().room.state();
  @State joinInput: string = '';
  @State sessionId: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  @State knockSummary: string = '未检测';
  private ctx: AppContext = AppContext.instance();
  private knock: KnockService = new KnockService();
  private probed: boolean = false;

  aboutToAppear(): void {
    this.ctx.room.addListener(this.onRoomChanged);
    this.roomState = this.ctx.room.state();
    this.sessionId = this.ctx.room.currentSessionId();
    this.probe();
  }

  aboutToDisappear(): void {
    this.ctx.room.removeListener(this.onRoomChanged);
  }

  private onRoomChanged = (s: RoomState): void => {
    this.roomState = s;
    if (s.sessionId.length > 0) {
      this.sessionId = s.sessionId;
    }
  };

  private async probe(): Promise<void> {
    if (this.probed) {
      return;
    }
    this.probed = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      await TapService.probe(context);
      const cap = this.knock.register((sid: string) => {
        this.joinInput = sid;
        this.message = '收到碰一碰凭证，正在入房…';
        this.doJoin(sid);
      });
      this.knockSummary = cap.summary;
    } catch (e) {
      const err = e as PageError;
      this.knockSummary = `碰一碰不可用：${err.message ?? '未知'}`;
    }
  }

  private async doCreate(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.message = '';
    try {
      const bill = this.ctx.ensureBill();
      const sid = await this.ctx.room.createRoom(bill);
      this.sessionId = sid;
      this.knock.pendingCredential = KnockService.encodeCredential(sid);
      this.message = '房间已创建，碰一下对方的手机即可邀请';
    } catch (e) {
      const err = e as PageError;
      this.message = `创建失败：${err.message ?? '未知错误'}`;
    } finally {
      this.busy = false;
    }
  }

  private async doJoin(sid?: string): Promise<void> {
    if (this.busy) {
      return;
    }
    const target = (sid ?? this.joinInput).trim();
    if (target.length === 0) {
      this.message = '先把房间号填上';
      return;
    }
    this.busy = true;
    try {
      await this.ctx.room.joinRoom(target);
      this.sessionId = target;
      this.message = '已入房，等付款人的账本同步过来';
    } catch (e) {
      const err = e as PageError;
      this.message = `入房失败：${err.message ?? '未知错误'}`;
    } finally {
      this.busy = false;
    }
  }

  private async doLeave(): Promise<void> {
    await this.ctx.room.leave();
    this.knock.unregister();
    this.sessionId = '';
    this.message = '已退出房间';
  }

  private roleText(): string {
    if (this.roomState.role === RoomRole.HOST) {
      return '付款人（权威账本）';
    }
    if (this.roomState.role === RoomRole.GUEST) {
      return '参与者';
    }
    return '未入房';
  }

  build(): void {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#8E97A8')
          .onClick(() => { router.back(); })
        Blank()
        Text('房间')
          .fontSize(15)
          .fontColor('#E8ECF4')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 52, bottom: 16 })

      Scroll() {
        Column({ space: 16 }) {
          // 当前状态
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Circle({ width: 8, height: 8 })
                .fill(this.roomState.phase === 'online' ? '#26DE81' : '#FFD93D')
              Text(this.roleText())
                .fontSize(15)
                .fontColor('#E8ECF4')
              Blank()
              if (this.roomState.peerCount > 0) {
                Text(`${this.roomState.peerCount} 台设备`)
                  .fontSize(12)
                  .fontColor('#8E97A8')
              }
            }
            .width('100%')

            if (this.sessionId.length > 0) {
              Text(`房间号：${this.sessionId}`)
                .fontSize(12)
                .fontColor('#8E97A8')
                .width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }
            Text(this.roomState.lastMessage)
              .fontSize(12)
              .fontColor('#5C6577')
              .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#1A1E27')
          .borderRadius(14)

          // 建房
          Button(this.busy ? '处理中…' : '我来付钱，开一个房间')
            .width('100%')
            .height(48)
            .backgroundColor('#4162FF')
            .fontColor('#FFFFFF')
            .enabled(!this.busy)
            .onClick(() => { this.doCreate(); })

          // 碰一碰说明
          Row({ space: 8 }) {
            Circle({ width: 7, height: 7 }).fill('#4ECDC4')
            Text(this.knockSummary)
              .fontSize(12)
              .fontColor('#8E97A8')
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 4, right: 4 })

          // 入房
          Column({ space: 10 }) {
            Text('加入别人的房间')
              .fontSize(13)
              .fontColor('#8E97A8')
              .width('100%')
            TextInput({ placeholder: '粘贴房间号，或用碰一碰接收', text: this.joinInput })
              .width('100%')
              .height(44)
              .backgroundColor('#1E222C')
              .fontColor('#E8ECF4')
              .placeholderColor('#5C6577')
              .onChange((v: string) => { this.joinInput = v; })
            Button(this.busy ? '处理中…' : '加入')
              .width('100%')
              .height(44)
              .backgroundColor('#2C3240')
              .fontColor('#E8ECF4')
              .enabled(!this.busy)
              .onClick(() => { this.doJoin(); })
          }
          .width('100%')

          if (this.roomState.role !== RoomRole.NONE) {
            Button('退出房间')
              .width('100%')
              .height(44)
              .backgroundColor('#2A1E1E')
              .fontColor('#FF6B6B')
              .onClick(() => { this.doLeave(); })
          }

          if (this.message.length > 0) {
            Text(this.message)
              .fontSize(12)
              .fontColor('#4ECDC4')
              .width('100%')
          }

          // 能力边界说明，避免误以为所有设备都能碰
          Text('说明：碰一碰依赖系统分享能力，仅在支持该能力的设备上可用；不支持时可手动输入房间号，功能不受影响。')
            .fontSize(11)
            .fontColor('#4A5262')
            .width('100%')
            .padding({ top: 8 })
        }
        .padding({ left: 20, right: 20, bottom: 32 })
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#12141A')
  }
}

interface PageError {
  code?: number;
  message?: string;
}
