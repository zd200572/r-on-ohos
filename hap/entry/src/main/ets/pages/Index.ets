import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { unpackTar, startR, writeR, interruptR, pollOutput } from 'libentry.so';

const TAG = 'RHost';

@Entry
@Component
struct Index {
  @State output: string = 'R on HarmonyOS —— 正在初始化...\n';
  @State input: string = '';
  @State showInstallDialog: boolean = false;
  @State installPkgName: string = '';
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private pollTimer: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.initR();
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private nativeLibDir(): string {
    return `${this.ctx.bundleCodeDir}/libs`;
  }

  private async initR(): Promise<void> {
    try {
      const base = this.ctx.filesDir + '/rdata';
      if (!fs.accessSync(base)) {
        fs.mkdirSync(base);
      }
      const tarPath = `${base}/rhome.tar`;
      if (!fs.accessSync(tarPath) && !fs.accessSync(`${base}/R/bin/exec/R`)) {
        hilog.info(0x0000, TAG, '解包 rawfile/rhome.tar -> %{public}s', base);
        const data = await this.ctx.resourceManager.getRawFileContent('rhome.tar');
        const f = fs.openSync(tarPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, data.buffer as ArrayBuffer);
        fs.closeSync(f);
        if (!unpackTar(tarPath, base)) {
          throw new Error('unpackTar 失败');
        }
        fs.unlinkSync(tarPath);
      }
      const rHome = `${base}/R`;
      if (!fs.accessSync(`${base}/rlibs`)) {
        fs.mkdirSync(`${base}/rlibs`);
      }
      if (!fs.accessSync(`${base}/work`)) {
        fs.mkdirSync(`${base}/work`);
      }

      const started = startR(`${rHome}/bin/exec/R`, rHome, `${base}/work`, `${base}/rlibs`,
        (chunk: string) => { /* 占位 */ });
      if (started < 0) {
        hilog.info(0x0000, TAG, '沙箱 exec 失败，回退 nativeLibraryDir');
        const nl = this.nativeLibDir();
        startR(`${nl}/librbin.so`, rHome, `${base}/work`, `${base}/rlibs`,
          (chunk: string) => { /* 占位 */ });
      }

      this.pollTimer = setInterval(() => {
        const chunk = pollOutput();
        if (chunk.length > 0) {
          this.output += chunk;
          // 自动滚动到底部
          this.scroller.scrollEdge(Edge.Bottom);
        }
      }, 100);
    } catch (e) {
      hilog.error(0x0000, TAG, 'initR 失败: %{public}s', String(e));
      this.output += `\n[启动失败] ${String(e)}\n`;
    }
  }

  private submit(): void {
    const line = this.input;
    this.input = '';
    this.output += `> ${line}\n`;
    writeR(line);
  }

  // 菜单触发的 R 命令：显示在输出区 + 发送给 R
  private runR(cmd: string): void {
    this.output += `> ${cmd}\n`;
    writeR(cmd);
  }

  build() {
    Stack() {
      // ---- 主内容 ----
      Column() {
        // 菜单栏
        Row() {
          Text('R Console').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#e6e6e6')
          Blank()
          Text('文件').fontSize(13).fontColor('#b0b0b0').margin({ right: 10 })
            .bindMenu([
              { value: '清屏', action: () => { this.output = ''; } },
              { value: '保存工作空间', action: () => { this.runR('save.image()'); } },
              { value: '加载工作空间', action: () => { this.runR('load(".RData")'); } },
              { value: '列出文件', action: () => { this.runR('list.files()'); } },
              { value: '退出 R', action: () => { this.runR('q(save="no")'); } },
            ])
          Text('编辑').fontSize(13).fontColor('#b0b0b0').margin({ right: 10 })
            .bindMenu([
              { value: '清屏', action: () => { this.output = ''; } },
              { value: '中断计算', action: () => { interruptR(); } },
            ])
          Text('包').fontSize(13).fontColor('#b0b0b0').margin({ right: 10 })
            .bindMenu([
              { value: '安装包…', action: () => { this.showInstallDialog = true; } },
              { value: '已安装包列表', action: () => { this.runR('rownames(installed.packages())'); } },
              { value: '已加载包', action: () => { this.runR('loadedNames()'); } },
            ])
          Text('设置').fontSize(13).fontColor('#b0b0b0').margin({ right: 10 })
            .bindMenu([
              { value: 'TUNA CRAN 镜像', action: () => {
                this.runR('options(repos=c(CRAN="https://mirrors.tuna.tsinghua.edu.cn/CRAN/"))');
              } },
              { value: '显示工作目录', action: () => { this.runR('getwd()'); } },
              { value: '设置输出宽度 120', action: () => { this.runR('options(width=120)'); } },
              { value: '显示 R 选项', action: () => { this.runR('options()'); } },
            ])
          Text('帮助').fontSize(13).fontColor('#b0b0b0')
            .bindMenu([
              { value: 'R 版本', action: () => { this.runR('R.version.string'); } },
              { value: '关于', action: () => {
                this.output += '\n— R 4.5.1 on HarmonyOS —\nHAP 内嵌 R REPL (轮询模式)\n';
              } },
            ])
        }
        .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 8 })
        .backgroundColor('#161b22')

        // 输出区
        Scroll(this.scroller) {
          Text(this.output)
            .fontSize(13).fontFamily('monospace').fontColor('#d0d0d0')
            .width('100%').padding(12)
        }
        .layoutWeight(1).width('100%').align(Alignment.Top)
        .backgroundColor('#101418')
        .scrollBar(BarState.Auto)

        // 输入区
        Row({ space: 8 }) {
          TextInput({ text: this.input, placeholder: '输入 R 表达式，回车执行' })
            .layoutWeight(1)
            .fontSize(14)
            .fontColor('#e8e8e8')
            .placeholderColor('#666666')
            .backgroundColor('#1e242c')
            .borderRadius(6)
            .enterKeyType(EnterKeyType.Send)
            .onChange((v: string) => { this.input = v; })
            .onSubmit(() => { this.submit(); })
          Button('发送').height(36).onClick(() => { this.submit(); })
        }
        .width('100%').padding(12)
        .backgroundColor('#161b22')
      }
      .width('100%').height('100%')
      .backgroundColor('#101418')

      // ---- 安装包弹窗 ----
      if (this.showInstallDialog) {
        // 遮罩层
        Column()
          .width('100%').height('100%')
          .backgroundColor('rgba(0,0,0,0.5)')
          .onClick(() => { this.showInstallDialog = false; })

        // 弹窗主体
        Column({ space: 12 }) {
          Text('安装 R 包').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#e6e6e6')
          Text('输入包名，从 CRAN 下载安装').fontSize(12).fontColor('#888888')
          TextInput({ placeholder: '包名（如 ggplot2）' })
            .width('100%')
            .fontSize(14)
            .fontColor('#e8e8e8')
            .placeholderColor('#666666')
            .backgroundColor('#101418')
            .borderRadius(6)
            .height(40)
            .onChange((v: string) => { this.installPkgName = v; })
          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .backgroundColor('#333333')
              .onClick(() => {
                this.showInstallDialog = false;
                this.installPkgName = '';
              })
            Button('安装')
              .layoutWeight(1)
              .onClick(() => {
                if (this.installPkgName.length > 0) {
                  this.runR(`install.packages("${this.installPkgName}")`);
                }
                this.showInstallDialog = false;
                this.installPkgName = '';
              })
          }.width('100%').margin({ top: 8 })
        }
        .padding(24)
        .backgroundColor('#1e242c')
        .borderRadius(12)
        .width('50%')
      }
    }
    .width('100%').height('100%')
  }
}
