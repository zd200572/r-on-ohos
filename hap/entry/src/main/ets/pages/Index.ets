import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import web_webview from '@ohos.web.webview';

import { unpackTar, startR, writeR, interruptR, pollOutput } from 'libentry.so';

const TAG = 'RHost';

// 手动 base64 编码（用 DataView 避免 ArkTS 索引限制）
function base64Encode(buf: ArrayBuffer): string {
  const view = new DataView(buf);
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let result = '';
  for (let i = 0; i < view.byteLength; i += 3) {
    const b1: number = view.getUint8(i);
    const b2: number = i + 1 < view.byteLength ? view.getUint8(i + 1) : 0;
    const b3: number = i + 2 < view.byteLength ? view.getUint8(i + 2) : 0;
    result += chars.charAt((b1 >> 2) & 0x3F);
    result += chars.charAt(((b1 << 4) | (b2 >> 4)) & 0x3F);
    result += i + 1 < view.byteLength ? chars.charAt(((b2 << 2) | (b3 >> 6)) & 0x3F) : '=';
    result += i + 2 < view.byteLength ? chars.charAt(b3 & 0x3F) : '=';
  }
  return result;
}

@Entry
@Component
struct Index {
  @State output: string = 'R on HarmonyOS —— 正在初始化...\n';
  @State input: string = '';
  @State showInstallDialog: boolean = false;
  @State installPkgName: string = '';
  @State showPlot: boolean = false;
  @State plotReady: boolean = false;
  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private pollTimer: number = -1;
  private scroller: Scroller = new Scroller();
  private webController: web_webview.WebviewController = new web_webview.WebviewController();

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

      // 通过 REPL 管道发送初始化命令（避免 R_ParseVector segfault）
      setTimeout(() => {
        writeR("library(stats)");
      }, 2000);
      setTimeout(() => {
        writeR("cat('sd(rnorm(10)) =', sd(rnorm(10)), '\\n')");
      }, 4000);
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

  // 文件选择器选择 .R 脚本，复制到工作目录后 source()
  private async runScript(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.R', '.r', '.txt'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) return;

      // 读取选中的文件
      const srcFile = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(srcFile.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(srcFile.fd, buf);
      fs.closeSync(srcFile);
      // ArrayBuffer → string（UTF-8 逐字节，R 脚本通常为 ASCII）
      const bytes = new Uint8Array(buf);
      let content = '';
      for (let i = 0; i < bytes.length; i++) {
        content += String.fromCharCode(bytes[i]);
      }

      // 写入 R 工作目录
      const scriptPath = `${this.ctx.filesDir}/rdata/work/_runscript.R`;
      const dstFile = fs.openSync(scriptPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(dstFile.fd, content);
      fs.closeSync(dstFile);

      this.output += `\n[加载脚本: ${uris[0]}]\n`;
      this.runR('source("_runscript.R")');
    } catch (e) {
      hilog.error(0x0000, TAG, 'runScript 失败: %{public}s', String(e));
      this.output += `\n[运行脚本失败] ${String(e)}\n`;
    }
  }

  // 绘图：发送 R 命令生成 PDF，读取后在 Web 组件中显示
  private async makePlot(): Promise<void> {
    try {
      // 发送 R 命令：PDF 设备 → plot → dev.off
      const cmd: string = "grDevices::pdf('last_plot.pdf');graphics::plot(1:10,type='l',main='Test Plot',col='blue');grDevices::dev.off()";
      this.output += `> [绘图命令]\n`;
      writeR(cmd);

      // 等待 R 处理（PDF 生成需要时间）
      await new Promise<void>(resolve => setTimeout(resolve, 2000));

      // 读取 PDF 文件
      const pdfPath = `${this.ctx.filesDir}/rdata/work/last_plot.pdf`;
      const file = fs.openSync(pdfPath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);

      // 转 base64
      const base64: string = base64Encode(buf);
      hilog.info(0x0000, TAG, 'PDF 大小: %{public}d, base64 长度: %{public}d', stat.size, base64.length);

      // 在 Web 组件中显示 PDF
      const html: string = `<html><head><style>body{margin:0;padding:0}embed{width:100%;height:100vh}</style></head><body><embed src="data:application/pdf;base64,${base64}" type="application/pdf"></body></html>`;
      // 先显示 Web 组件（需要等组件渲染后才能 loadData）
      this.plotReady = true;
      this.showPlot = true;
      this.output += `[绘图完成，PDF ${stat.size} 字节]\n`;
      // 等待 Web 组件渲染后再加载数据
      setTimeout(() => {
        try {
          this.webController.loadData(html, 'text/html', 'utf-8', '', '');
        } catch (e2) {
          hilog.error(0x0000, TAG, 'loadData 失败: %{public}s', String(e2));
        }
      }, 500);
    } catch (e) {
      hilog.error(0x0000, TAG, 'makePlot 失败: %{public}s', String(e));
      this.output += `\n[绘图失败] ${String(e)}\n`;
    }
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
              { value: '绘图（测试）', action: () => { this.makePlot(); } },
              { value: '运行脚本…', action: () => { this.runScript(); } },
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

      // ---- 绘图显示窗口 ----
      if (this.showPlot) {
        Column() {
          // 标题栏
          Row() {
            Text('R 图形输出').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#e6e6e6')
            Blank()
            Button('关闭').height(32).onClick(() => { this.showPlot = false; })
          }
          .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#161b22')

          // Web 组件显示 PDF
          if (this.plotReady) {
            Web({ src: '', controller: this.webController })
              .width('100%').layoutWeight(1)
              .backgroundColor('#ffffff')
          } else {
            Column() {
              Text('正在生成图形...').fontSize(14).fontColor('#888888')
            }
            .width('100%').layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#101418')
          }
        }
        .width('80%').height('80%')
        .backgroundColor('#101418')
        .borderRadius(8)
      }
    }
    .width('100%').height('100%')
  }
}
