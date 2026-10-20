/**
 * 首页：建账单 —— 加人、加菜、去认领。
 *
 * 交互原则：一屏内完成，不跳设置页；每次改动立刻重算并落盘。
 */
import { router } from '@kit.ArkUI';
import { AppContext } from '../store/AppContext';
import { Bill, Participant, Dish, computeBill, formatCents, parseYuanToCents, dishLineTotal, claimCountOf } from '../model/Bill';
import { addParticipant, addDish } from '../store/BillStore';

@Entry
@Component
struct Index {
  @State bill: Bill = AppContext.instance().ensureBill();
  @State personInput: string = '';
  @State dishName: string = '';
  @State dishPrice: string = '';
  @State dishQty: string = '1';
  @State errorMsg: string = '';
  private ctx: AppContext = AppContext.instance();

  private refresh(): void {
    this.bill = this.ctx.ensureBill();
    this.ctx.persist().catch(() => {});
  }

  private onAddPerson(): void {
    const name = this.personInput.trim();
    if (name.length === 0) {
      this.errorMsg = '先给这个人起个名字';
      return;
    }
    if (this.bill.participants.some(p => p.name === name)) {
      this.errorMsg = `已经有「${name}」了`;
      return;
    }
    addParticipant(this.bill, name);
    this.personInput = '';
    this.errorMsg = '';
    this.refresh();
  }

  private onAddDish(): void {
    const name = this.dishName.trim();
    if (name.length === 0) {
      this.errorMsg = '菜名不能为空';
      return;
    }
    const cents = parseYuanToCents(this.dishPrice);
    if (isNaN(cents) || cents <= 0) {
      this.errorMsg = '价格填个正数，最多两位小数';
      return;
    }
    const qty = parseInt(this.dishQty, 10);
    const quantity = (isNaN(qty) || qty <= 0) ? 1 : qty;
    addDish(this.bill, name, cents, quantity);
    this.dishName = '';
    this.dishPrice = '';
    this.dishQty = '1';
    this.errorMsg = '';
    this.refresh();
  }

  build(): void {
    Column() {
      Column({ space: 6 }) {
        Text(this.bill.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text(`合计 ¥${formatCents(computeBill(this.bill).totalCents)}`)
          .fontSize(15)
          .fontColor('#8E97A8')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 20, right: 20, top: 56, bottom: 14 })

      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 10 }) {
            Text(`都有谁（${this.bill.participants.length}）`)
              .fontSize(14)
              .fontColor('#8E97A8')
              .width('100%')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.bill.participants, (p: Participant) => {
                Row({ space: 6 }) {
                  Circle({ width: 10, height: 10 }).fill(p.color)
                  Text(p.name).fontSize(13).fontColor('#E8ECF4')
                  if (p.isPayer) {
                    Text('付款')
                      .fontSize(10)
                      .fontColor('#12141A')
                      .backgroundColor('#FFD93D')
                      .borderRadius(4)
                      .padding({ left: 4, right: 4 })
                  }
                }
                .padding({ left: 10, right: 12, top: 8, bottom: 8 })
                .margin({ right: 8, bottom: 8 })
                .backgroundColor('#1E222C')
                .borderRadius(18)
              }, (p: Participant) => p.id)
            }
            .width('100%')

            Row({ space: 8 }) {
              TextInput({ placeholder: '加一个人，如「小刘」', text: this.personInput })
                .layoutWeight(1)
                .height(40)
                .backgroundColor('#1E222C')
                .fontColor('#E8ECF4')
                .placeholderColor('#5C6577')
                .onChange((v: string) => { this.personInput = v; })
                .onSubmit(() => { this.onAddPerson(); })
              Button('加人')
                .height(40)
                .backgroundColor('#2C3240')
                .fontColor('#E8ECF4')
                .onClick(() => { this.onAddPerson(); })
            }
            .width('100%')
          }

          Column({ space: 10 }) {
            Text(`吃了什么（${this.bill.dishes.length} 道）`)
              .fontSize(14)
              .fontColor('#8E97A8')
              .width('100%')

            ForEach(this.bill.dishes, (d: Dish) => {
              Row() {
                Column({ space: 3 }) {
                  Text(d.name).fontSize(15).fontColor('#E8ECF4')
                  Text(`¥${formatCents(d.unitPriceCents)}${d.quantity > 1 ? ' × ' + d.quantity : ''}`)
                    .fontSize(12)
                    .fontColor('#8E97A8')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Row({ space: 8 }) {
                  Text(`${claimCountOf(this.bill, d.id)} 人认领`)
                    .fontSize(12)
                    .fontColor('#8E97A8')
                  Text(`¥${formatCents(dishLineTotal(d))}`)
                    .fontSize(14)
                    .fontColor('#4ECDC4')
                }
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#1A1E27')
              .borderRadius(12)
            }, (d: Dish) => d.id)

            Row({ space: 8 }) {
              TextInput({ placeholder: '菜名', text: this.dishName })
                .layoutWeight(2)
                .height(40)
                .backgroundColor('#1E222C')
                .fontColor('#E8ECF4')
                .placeholderColor('#5C6577')
                .onChange((v: string) => { this.dishName = v; })
              TextInput({ placeholder: '价格', text: this.dishPrice })
                .layoutWeight(1)
                .height(40)
                .type(InputType.NUMBER_DECIMAL)
                .backgroundColor('#1E222C')
                .fontColor('#E8ECF4')
                .placeholderColor('#5C6577')
                .onChange((v: string) => { this.dishPrice = v; })
              TextInput({ placeholder: '份', text: this.dishQty })
                .width(52)
                .height(40)
                .type(InputType.Number)
                .backgroundColor('#1E222C')
                .fontColor('#E8ECF4')
                .placeholderColor('#5C6577')
                .onChange((v: string) => { this.dishQty = v; })
              Button('加')
                .height(40)
                .backgroundColor('#2C3240')
                .fontColor('#E8ECF4')
                .onClick(() => { this.onAddDish(); })
            }
            .width('100%')
          }

          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(12)
              .fontColor('#FF6B6B')
              .width('100%')
          }
        }
        .padding({ left: 20, right: 20, bottom: 24 })
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Column({ space: 8 }) {
        Button('开始认领')
          .width('100%')
          .height(50)
          .backgroundColor('#4162FF')
          .fontColor('#FFFFFF')
          .fontSize(16)
          .enabled(this.bill.dishes.length > 0 && this.bill.participants.length > 0)
          .opacity(this.bill.dishes.length > 0 ? 1 : 0.4)
          .onClick(() => {
            router.pushUrl({ url: 'pages/ClaimPage' }).catch(() => {});
          })
        Text('每人碰一下手机，认领自己吃掉的那道菜')
          .fontSize(11)
          .fontColor('#5C6577')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 28 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#12141A')
  }
}
