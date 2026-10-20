/**
 * 结算页：每人应付、谁该转给谁、以及未认领提醒。
 */
import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppContext } from '../store/AppContext';
import { Bill, PersonShare, Transfer, computeBill, formatCents } from '../model/Bill';

@Entry
@Component
struct SettlePage {
  @State bill: Bill = AppContext.instance().ensureBill();
  @State copied: string = '';
  private ctx: AppContext = AppContext.instance();

  private copySummary(): void {
    const r = computeBill(this.bill);
    const lines: string[] = [];
    lines.push(`${this.bill.title} · 合计 ¥${formatCents(r.totalCents)}`);
    for (const s of r.shares) {
      lines.push(`${s.name}：应付 ¥${formatCents(s.owedCents)}`);
    }
    if (r.transfers.length > 0) {
      lines.push('——');
      for (const t of r.transfers) {
        lines.push(`${t.fromName} → ${t.toName} ¥${formatCents(t.amountCents)}`);
      }
    }
    const text = lines.join('\n');
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.copied = '已复制，去群里粘贴';
      }).catch(() => {
        this.copied = '复制失败，可手动截图';
      });
    } catch (_e) {
      this.copied = '复制失败，可手动截图';
    }
  }

  private restart(): void {
    this.ctx.resetBill().then(() => {
      this.bill = this.ctx.ensureBill();
      router.replaceUrl({ url: 'pages/Index' }).catch(() => {});
    }).catch(() => {});
  }

  build(): void {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#8E97A8')
          .onClick(() => { router.back(); })
        Blank()
        Text('重新开一单')
          .fontSize(15)
          .fontColor('#8E97A8')
          .onClick(() => { this.restart(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 52, bottom: 10 })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 6 }) {
            Text(`¥${formatCents(computeBill(this.bill).totalCents)}`)
              .fontSize(38)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text(computeBill(this.bill).settled
              ? '已全部认领'
              : `还有 ¥${formatCents(computeBill(this.bill).unclaimedCents)} 没人认领`)
              .fontSize(13)
              .fontColor(computeBill(this.bill).settled ? '#26DE81' : '#FFD93D')
          }
          .width('100%')
          .padding(20)
          .backgroundColor('#1A1E27')
          .borderRadius(16)

          Column({ space: 10 }) {
            Text('每人应付')
              .fontSize(14)
              .fontColor('#8E97A8')
              .width('100%')
            ForEach(computeBill(this.bill).shares, (s: PersonShare) => {
              Row() {
                Text(s.name).fontSize(15).fontColor('#E8ECF4').layoutWeight(1)
                Text(`¥${formatCents(s.owedCents)}`)
                  .fontSize(15)
                  .fontColor('#E8ECF4')
              }
              .width('100%')
              .padding(14)
              .backgroundColor('#1A1E27')
              .borderRadius(12)
            }, (s: PersonShare) => s.participantId)
          }

          if (computeBill(this.bill).transfers.length > 0) {
            Column({ space: 10 }) {
              Text('这样转账最省事')
                .fontSize(14)
                .fontColor('#8E97A8')
                .width('100%')
              ForEach(computeBill(this.bill).transfers, (t: Transfer) => {
                Row({ space: 8 }) {
                  Text(t.fromName).fontSize(14).fontColor('#E8ECF4')
                  Text('→').fontSize(14).fontColor('#5C6577')
                  Text(t.toName).fontSize(14).fontColor('#4ECDC4')
                  Blank()
                  Text(`¥${formatCents(t.amountCents)}`)
                    .fontSize(15)
                    .fontColor('#FFFFFF')
                }
                .width('100%')
                .padding(14)
                .backgroundColor('#1A1E27')
                .borderRadius(12)
              }, (t: Transfer) => `${t.fromId}_${t.toId}`)
            }
          }

          if (this.copied.length > 0) {
            Text(this.copied)
              .fontSize(12)
              .fontColor('#4ECDC4')
              .width('100%')
          }
        }
        .padding({ left: 20, right: 20, bottom: 24 })
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Button('复制账单发群里')
        .width('100%')
        .height(50)
        .backgroundColor('#4162FF')
        .fontColor('#FFFFFF')
        .fontSize(16)
        .margin({ left: 20, right: 20, top: 12, bottom: 28 })
        .onClick(() => { this.copySummary(); })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#12141A')
  }
}
