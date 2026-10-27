import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import display from '@ohos.display';
import native from 'libvectorcraft_native.so';
import { RecentStore, RecentEntry } from '../common/RecentStore';
import { AppConstants, SurfaceMetrics } from '../common/Constants';

/**
 * VectorCraft 主页面
 *
 * 结构：一个全屏 Stack，底层是承载编辑引擎的 XComponent（Rust 原生渲染，
 * wgpu 走 GLES/EGL 画进 surface，没有 WebView），上层是根据窗口宽度自适应的
 * 原生外壳（PC 侧栏 / 平板顶栏 / 手机底栏）。
 *
 * 这一层只做「系统能力代理」：引擎要弹文件选择器、保存到用户可见位置、打开外链时，
 * Rust 侧排成请求，这里定时 take_requests() 取走并弹系统界面；结果再交回 native。
 */
@Entry
@Component
struct Index {
  private xController: XComponentController = new XComponentController();
  private mainWindow: window.Window | undefined = undefined;
  private recent: RecentStore | undefined = undefined;
  private dataDir: string = '';
  private started: boolean = false;
  private pollTimer: number = -1;
  private busy: boolean = false;
  /** 导出文件名 → 用户上次选定的保存位置，第二次保存不再弹框。 */
  private savedTo: Map<string, string> = new Map();

  @StorageProp('engineState') engineState: string = AppConstants.STATE_IDLE;
  @StorageProp('engineMessage') engineMessage: string = '';
  @StorageProp('winWidthVp') winWidthVp: number = 0;
  @StorageProp('deviceType') deviceType: string = 'phone';
  // 原生桥写回的「保存 / 导出」结果，弹 toast 让用户知道文件去了哪
  @StorageProp('saveStatus') @Watch('onSaveStatus') saveStatus: string = '';

  @State pageLoaded: boolean = false;
  @State fatalError: string = '';
  @State sidebarExpanded: boolean = false;
  @State showAbout: boolean = false;
  @State showRecent: boolean = false;
  @State recentList: RecentEntry[] = [];
  @State fullScreen: boolean = false;
  @State statusText: string = '正在准备…';
  // 手动维护的按压态：某些场景（点击后立即弹出覆盖层）拿不到 touch Up，
  // 用 stateStyles 的 pressed 会卡在深色背景上不恢复，所以自己记一个 key
  @State pressedKey: string = '';
  // IME 代理：只在引擎需要文字输入时才让隐藏输入框进树
  @State imeValue: string = '';
  @State showIme: boolean = false;
  private imeActive: boolean = false;
  /** 修饰键按下状态（getModifierKeyState 在部分场景返回 undefined，自己跟踪更可靠）。 */
  private ctrlDown: boolean = false;
  private shiftDown: boolean = false;
  private altDown: boolean = false;
  /** 上一个已处理的轴事件指纹，用于给父子容器的重复派发去重。 */
  private lastAxisKey: string = '';
  /** 当前这次滚动（BEGIN→END）里是否已经报过数值。 */
  private gestureHadValue: boolean = false;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.mainWindow = AppStorage.get<window.Window>('mainWindow');
    this.dataDir = ctx.filesDir;
    native.setDataDir(this.dataDir);

    // 最近文件：原生侧自带一份沙箱副本（引擎自带的「最近」基于文件路径，原生端同样无处可存）
    const store = new RecentStore(ctx);
    this.recent = store;
    this.recentList = store.list();

    console.info('[VectorCraft] Index aboutToAppear, 最近文件=' + this.recentList.length);
  }

  /** 页面显示后把焦点交给渲染区，否则键盘事件收不到。 */
  onPageShow(): void {
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('vc_root');
      } catch (err) {
        console.error('[VectorCraft] requestFocus 失败: ' + JSON.stringify(err));
      }
    }, 200);
  }

  aboutToDisappear(): void {
    this.stopEngine();
  }

  // ------------------------------------------------------------------
  // 布局尺寸
  // ------------------------------------------------------------------

  private effectiveWidth(): number {
    if (this.winWidthVp > 0) {
      return this.winWidthVp;
    }
    // 首帧兜底：按设备形态估算
    if (this.deviceType === '2in1') {
      return 1280;
    }
    if (this.deviceType === 'tablet') {
      return 900;
    }
    return 400;
  }

  private isWide(): boolean {
    return this.effectiveWidth() >= AppConstants.BREAKPOINT_WIDE;
  }

  private isMedium(): boolean {
    return this.effectiveWidth() >= AppConstants.BREAKPOINT_MEDIUM && !this.isWide();
  }

  private sidebarWidth(): number {
    if (!this.isWide()) {
      return 0;
    }
    return this.sidebarExpanded ? 216 : 64;
  }

  private topBarHeight(): number {
    return this.isMedium() ? 48 : 0;
  }

  private bottomBarHeight(): number {
    return (!this.isWide() && !this.isMedium()) ? 62 : 0;
  }

  // ------------------------------------------------------------------
  // 交互
  // ------------------------------------------------------------------

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (err) {
      console.error('[VectorCraft] toast 失败: ' + JSON.stringify(err));
    }
  }

  onSaveStatus(): void {
    if (this.saveStatus.length > 0) {
      const saved: boolean = this.saveStatus.indexOf('已保存') === 0;
      this.toast(saved ? this.saveStatus + '（已加入最近文件）' : this.saveStatus);
    }
  }

  // ------------------------------------------------------------------
  // 引擎生命周期（原生渲染：wgpu/GLES 直接画进 XComponent surface）
  // ------------------------------------------------------------------

  private setEngineState(state: string, message: string): void {
    AppStorage.setOrCreate(AppConstants.KEY_ENGINE_STATE, state);
    AppStorage.setOrCreate(AppConstants.KEY_ENGINE_MESSAGE, message);
  }

  /** 系统语言（BCP 47）：引擎据此挑界面词条，中文设备即简体中文。 */
  private systemLocale(): string {
    try {
      const tag: string = i18n.System.getSystemLanguage();
      if (tag.length > 0) {
        return tag;
      }
    } catch (err) {
      console.info('[VectorCraft] 读取系统语言失败: ' + JSON.stringify(err));
    }
    return 'zh-Hans';
  }

  private surfaceMetrics(): SurfaceMetrics {
    const rect = this.xController.getXComponentSurfaceRect();
    let width: number = rect.surfaceWidth;
    let height: number = rect.surfaceHeight;
    let dpi: number = 1.0;
    try {
      const d = display.getDefaultDisplaySync();
      if (width <= 0 || height <= 0) {
        width = d.width;
        height = d.height;
      }
      dpi = d.densityDPI / 160;
    } catch (err) {
      dpi = 1.0;
    }
    return { width: width, height: height, dpi: dpi };
  }

  /** XComponent 表面就绪后调用：把 surface 交给 Rust，起渲染线程。 */
  private startEngine(): void {
    if (this.started) {
      return;
    }
    this.fatalError = '';
    try {
      const surfaceId: string = this.xController.getXComponentSurfaceId();
      const m: SurfaceMetrics = this.surfaceMetrics();
      this.setEngineState(AppConstants.STATE_LOADING, '正在启动原生渲染');
      const ok: boolean = native.start(Number(surfaceId), m.width, m.height, m.dpi, this.systemLocale());
      console.info('[VectorCraft] native.start surface=' + surfaceId + ' size=' + m.width + 'x' + m.height
        + ' dpi=' + m.dpi + ' -> ' + ok);
      if (!ok) {
        this.fatalError = '原生渲染启动失败（surface ' + surfaceId + '）。请查看 hilog（vectorcraft-ohos）中的详细日志。';
        this.setEngineState(AppConstants.STATE_ERROR, this.fatalError);
        return;
      }
      this.started = true;
      this.startPolling();
      // 引擎先画首帧再撤遮罩，避免闪一下空白的 surface
      setTimeout(() => {
        if (this.started && this.fatalError.length === 0) {
          this.pageLoaded = true;
          this.setEngineState(AppConstants.STATE_READY, '');
        }
      }, 260);
    } catch (err) {
      const e = err as BusinessError;
      console.error('[VectorCraft] native.start 异常: ' + JSON.stringify(e));
      this.fatalError = '原生渲染启动异常：' + e.message;
      this.setEngineState(AppConstants.STATE_ERROR, this.fatalError);
    }
  }

  private stopEngine(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    try {
      native.stop();
    } catch (err) {
      console.error('[VectorCraft] native.stop 异常: ' + JSON.stringify(err));
    }
    this.started = false;
  }

  /** 「重新加载引擎」：停掉渲染线程再原地重启，等价于重开应用、回到首页。 */
  private reloadEngine(): void {
    this.pageLoaded = false;
    this.fatalError = '';
    this.statusText = '正在重新加载引擎…';
    this.stopEngine();
    setTimeout(() => {
      this.startEngine();
    }, 120);
  }

  /** 回到编辑器首页：原生引擎没有 URL 可导航，重启即回到首页。 */
  private backToEditor(): void {
    this.reloadEngine();
  }

  /** 轮询 Rust 侧排队的系统能力请求（打开 / 放置 / 保存 / 外链）。 */
  private startPolling(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = setInterval(() => {
      let reqs: string[] = [];
      try {
        reqs = native.takeRequests();
      } catch (err) {
        return;
      }
      for (const req of reqs) {
        if (req === 'pickOpen') {
          this.pickOpen(false);
        } else if (req === 'pickPlace') {
          this.pickOpen(true);
        } else if (req.startsWith('saveAs:')) {
          this.saveAs(req.substring('saveAs:'.length));
        } else if (req.startsWith('openUrl:')) {
          this.openUrl(req.substring('openUrl:'.length));
        }
      }
      this.syncImeFocus();
    }, 80);
  }

  /** 引擎要弹系统选择器：读出字节交给 Rust。`place` 为真时是「置入」而非「打开」。 */
  private async pickOpen(place: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const viewPicker = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.Context);
      const uris: string[] = await viewPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.svg', '.vc', '.json']
      });
      if (uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      const name: string = uri.split('/').pop() ?? 'drawing.svg';
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      const ok: boolean = place ? native.placeFile(name, buffer) : native.openFile(name, buffer);
      console.info('[VectorCraft] ' + (place ? 'placeFile ' : 'openFile ') + name + ' ' + size + 'B -> ' + ok);
    } catch (err) {
      const e = err as BusinessError;
      console.error('[VectorCraft] 打开文件失败: ' + JSON.stringify(e));
    } finally {
      this.busy = false;
    }
  }

  /**
   * 引擎导出完成：沙箱里已经有 exports/<name>，这里复制到用户选定的位置。
   * 同一个文件名只问一次，之后的保存直接覆盖上次的位置。
   */
  private async saveAs(name: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const src: string = this.dataDir + '/exports/' + name;
      const file = fs.openSync(src, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      fs.readSync(file.fd, buffer);
      fs.closeSync(file);
      const bytes: Uint8Array = new Uint8Array(buffer.slice(0));

      let uri: string = this.savedTo.get(name) ?? '';
      if (uri.length === 0) {
        const viewPicker = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.Context);
        const uris: string[] = await viewPicker.save({ newFileNames: [name] });
        if (uris.length === 0) {
          return;
        }
        uri = uris[0];
        this.savedTo.set(name, uri);
      }
      const out = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, buffer);
      fs.closeSync(out);

      // 登记「最近文件」：原生侧留一份沙箱副本，杀进程后仍可重新打开
      if (this.recent) {
        this.recentList = this.recent.add(name, uri, bytes);
      }
      AppStorage.setOrCreate(AppConstants.KEY_SAVE_STATUS, '已保存 ' + name);
      console.info('[VectorCraft] saved ' + name + ' -> ' + uri + ' (' + buffer.byteLength + 'B)');
    } catch (err) {
      const e = err as BusinessError;
      console.error('[VectorCraft] 保存失败: ' + JSON.stringify(e));
      AppStorage.setOrCreate(AppConstants.KEY_SAVE_STATUS, '保存失败：' + e.message);
    } finally {
      this.busy = false;
    }
  }

  /** 引擎里的外链用系统浏览器打开。 */
  private openUrl(url: string): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      ctx.openLink(url).catch((err: BusinessError) => {
        console.error('[VectorCraft] 打开链接失败: ' + JSON.stringify(err));
      });
    } catch (err) {
      console.error('[VectorCraft] openLink 异常: ' + JSON.stringify(err));
    }
  }

  /** 鼠标滚轮 / 触控板轴事件 → egui 滚轮（Ctrl+滚轮 = 缩放）。 */
  private onWheel(event: AxisEvent): void {
    if (!this.started) {
      return;
    }
    if (event.action === AxisAction.CANCEL) {
      return;
    }
    let dx: number = 0;
    let dy: number = 0;
    try {
      dy = event.getVerticalAxisValue();
      dx = event.getHorizontalAxisValue();
    } catch (err) {
      return;
    }
    if (event.action === AxisAction.BEGIN) {
      this.gestureHadValue = false;
    }
    const hasValue: boolean = dx !== 0 || dy !== 0;
    if (hasValue && event.action === AxisAction.UPDATE) {
      this.gestureHadValue = true;
    }
    if (hasValue && event.action === AxisAction.END && this.gestureHadValue) {
      return;
    }
    if (!hasValue) {
      return;
    }
    // 同一个轴事件可能被 XComponent 和外层容器各派发一次：时间戳 + 动作 + 数值全同才去重
    const key: string = event.timestamp + '|' + event.action + '|' + dx + '|' + dy;
    if (this.lastAxisKey === key) {
      return;
    }
    this.lastAxisKey = key;
    try {
      native.wheel(dx * 2.6, dy * 2.6, this.ctrlDown, this.shiftDown, this.altDown);
    } catch (err) {
      console.error('[VectorCraft] native.wheel 异常: ' + JSON.stringify(err));
    }
  }

  /** IME 上屏文本：和上一版做差，增量交给引擎（否则会重复插入）。 */
  private onImeChange(value: string): void {
    if (value === this.imeValue) {
      return;
    }
    const prev: string = this.imeValue;
    try {
      let p: number = 0;
      const n: number = Math.min(prev.length, value.length);
      while (p < n && prev.charCodeAt(p) === value.charCodeAt(p)) {
        p++;
      }
      const removed: number = prev.length - p;
      if (removed > 0) {
        native.imeBackspace(removed);
      }
      if (value.length > p) {
        native.imeText(value.substring(p));
      }
    } catch (err) {
      console.error('[VectorCraft] IME 转发失败: ' + JSON.stringify(err));
    }
    this.imeValue = value;
  }

  /** 引擎需要文字输入时才把焦点给隐藏输入框，否则系统会莫名弹输入法。 */
  private syncImeFocus(): void {
    let wants: boolean = false;
    try {
      wants = native.wantsTextInput();
    } catch (err) {
      return;
    }
    if (wants === this.imeActive) {
      return;
    }
    this.imeActive = wants;
    this.showIme = wants;
    if (!wants) {
      this.imeValue = '';
    }
    try {
      if (wants) {
        setTimeout(() => {
          try {
            this.getUIContext().getFocusController().requestFocus('vc_ime');
          } catch (e) {
            console.error('[VectorCraft] IME 焦点失败: ' + JSON.stringify(e));
          }
        }, 50);
      } else {
        this.getUIContext().getFocusController().requestFocus('vc_root');
      }
    } catch (err) {
      console.error('[VectorCraft] 切换 IME 焦点失败: ' + JSON.stringify(err));
    }
  }

  /** 修饰键自己跟踪：getModifierKeyState 在某些场景返回 undefined。 */
  private trackModifiers(event: KeyEvent): void {
    const down: boolean = event.type === KeyType.Down;
    if (event.keyCode === 2072 || event.keyCode === 2073) {
      this.ctrlDown = down;
    } else if (event.keyCode === 2047 || event.keyCode === 2048) {
      this.shiftDown = down;
    } else if (event.keyCode === 2045 || event.keyCode === 2046) {
      this.altDown = down;
    }
  }

  private onKey(event: KeyEvent): void {
    if (!this.started) {
      return;
    }
    this.trackModifiers(event);
    let ctrl: boolean = this.ctrlDown;
    let shift: boolean = this.shiftDown;
    let alt: boolean = this.altDown;
    const modState = event.getModifierKeyState;
    if (modState) {
      try {
        const c: boolean | undefined = modState(['ctrl']);
        const s: boolean | undefined = modState(['shift']);
        const a: boolean | undefined = modState(['alt']);
        if (c !== undefined) {
          ctrl = c === true;
        }
        if (s !== undefined) {
          shift = s === true;
        }
        if (a !== undefined) {
          alt = a === true;
        }
      } catch (err) {
        ctrl = this.ctrlDown;
        shift = this.shiftDown;
        alt = this.altDown;
      }
    }
    this.ctrlDown = ctrl;
    this.shiftDown = shift;
    this.altDown = alt;
    const phase: number = event.type === KeyType.Down ? 0 : 1;
    let text: string = '';
    if (phase === 0 && event.keyText !== undefined) {
      const kt: string = event.keyText;
      if (kt.length === 1 && kt.charCodeAt(0) >= 32) {
        text = kt;
      }
    }
    try {
      native.key(phase, event.keyCode, ctrl, shift, alt, text);
    } catch (err) {
      console.error('[VectorCraft] native.key 异常: ' + JSON.stringify(err));
    }
  }

  private openHelp(): void {
    try {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/Help' });
    } catch (err) {
      console.error('[VectorCraft] 打开使用说明失败: ' + JSON.stringify(err));
      this.toast('无法打开使用说明');
    }
  }

  // ------------------------------------------------------------------
  // 最近文件
  // ------------------------------------------------------------------

  /**
   * 打开一条最近文件。
   *
   * 原生引擎收文件的通道只有一条：把字节交给 Rust，它在下一帧当作「打开」处理。
   * 保存时原生侧已经留了一份沙箱副本，这里直接读出字节还原成 ArrayBuffer 交过去。
   */
  private openRecent(entry: RecentEntry): void {
    if (!this.started || this.engineState !== AppConstants.STATE_READY) {
      this.toast('引擎尚未就绪，请稍候再试');
      return;
    }
    const store = this.recent;
    if (!store) {
      this.toast('最近文件不可用');
      return;
    }
    const data = store.read(entry.id);
    if (!data || data.length === 0) {
      this.toast('文件副本已丢失，请重新保存一次');
      this.recentList = store.remove(entry.id);
      return;
    }
    this.showRecent = false;
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(data.length);
      new Uint8Array(buffer).set(data);
      const ok: boolean = native.openFile(entry.name, buffer);
      console.info('[VectorCraft] 打开最近文件 ' + entry.name + ' ' + data.length + 'B -> ' + ok);
      this.toast(ok ? '正在打开 ' + entry.name : '打开失败，请重试');
    } catch (err) {
      console.error('[VectorCraft] 打开最近文件失败: ' + JSON.stringify(err));
      this.toast('打开失败，请重试');
    }
  }

  private removeRecent(entry: RecentEntry): void {
    if (!this.recent) {
      return;
    }
    this.recentList = this.recent.remove(entry.id);
    this.toast('已移除 ' + entry.name);
  }

  private clearRecent(): void {
    if (!this.recent) {
      return;
    }
    this.recentList = this.recent.clear();
    this.toast('已清空最近文件');
  }

  private toggleFullScreen(): void {
    const win = this.mainWindow;
    if (!win) {
      this.toast('当前环境不支持全屏切换');
      return;
    }
    this.fullScreen = !this.fullScreen;
    win.setWindowLayoutFullScreen(this.fullScreen).catch((err: BusinessError) => {
      console.error('[VectorCraft] 全屏切换失败: ' + JSON.stringify(err));
    });
    // 2in1（PC）上同时切换窗口装饰栏
    try {
      if (this.deviceType === '2in1') {
        win.setWindowDecorVisible(!this.fullScreen);
      }
    } catch (err) {
      console.info('[VectorCraft] setWindowDecorVisible 不可用: ' + JSON.stringify(err));
    }
    // 系统栏显隐
    try {
      win.setSpecificSystemBarEnabled('status', !this.fullScreen);
      win.setSpecificSystemBarEnabled('navigationIndicator', !this.fullScreen);
    } catch (err) {
      console.info('[VectorCraft] 系统栏控制不可用: ' + JSON.stringify(err));
    }
  }

  private stateColor(): Resource {
    if (this.fatalError.length > 0 || this.engineState === AppConstants.STATE_ERROR) {
      return $r('app.color.danger');
    }
    if (this.engineState === AppConstants.STATE_READY) {
      return $r('app.color.accent');
    }
    return $r('app.color.text_secondary');
  }

  private engineStateLabel(): string {
    if (this.fatalError.length > 0) {
      return '启动失败';
    }
    if (this.engineState === AppConstants.STATE_READY) {
      return '引擎就绪 · 原生渲染';
    }
    if (this.engineState === AppConstants.STATE_ERROR) {
      return '引擎报错';
    }
    if (this.engineState === AppConstants.STATE_LOADING) {
      return '正在加载引擎';
    }
    return '正在准备…';
  }

  // ------------------------------------------------------------------
  // 视图
  // ------------------------------------------------------------------

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1. 编辑引擎承载区（原生渲染）
      Column() {
        this.EngineHost()
      }
      .width('100%')
      .height('100%')
      .padding({
        left: this.sidebarWidth(),
        top: this.topBarHeight(),
        bottom: this.bottomBarHeight()
      })
      .backgroundColor($r('app.color.shell_bg'))

      // 2. 自适应原生外壳
      if (this.isWide()) {
        this.SideBar()
      } else if (this.isMedium()) {
        this.TopBar()
      } else {
        this.BottomBar()
      }

      // 3. 引擎首帧之前的原生过渡遮罩
      if (!this.pageLoaded && this.fatalError.length === 0 && this.engineState !== AppConstants.STATE_ERROR) {
        this.SplashOverlay()
      }

      // 4. 关于面板
      if (this.showAbout) {
        this.AboutOverlay()
      }

      // 5. 最近文件面板
      if (this.showRecent) {
        this.RecentOverlay()
      }

      // 6. 致命错误面板
      if (this.fatalError.length > 0 || this.engineState === AppConstants.STATE_ERROR) {
        this.ErrorOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .id('vc_root')
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      this.onKey(event);
    })
    .onAxisEvent((event: AxisEvent) => {
      this.onWheel(event);
    })
    .backgroundColor($r('app.color.shell_bg'))
  }

  @Builder
  EngineHost() {
    Stack({ alignContent: Alignment.TopStart }) {
      XComponent({ id: 'vc_native', type: XComponentType.SURFACE, controller: this.xController })
        .width('100%')
        .height('100%')
        .onLoad(() => {
          this.startEngine();
        })
        .onTouch((event: TouchEvent) => {
          if (!this.started) {
            return;
          }
          const t: TouchObject | undefined =
            event.touches.length > 0 ? event.touches[0] : event.changedTouches[0];
          if (!t) {
            return;
          }
          let phase: number = 1;
          if (event.type === TouchType.Down) {
            phase = 0;
          } else if (event.type === TouchType.Up) {
            phase = 2;
          } else if (event.type === TouchType.Cancel) {
            phase = 3;
          }
          try {
            native.touch(phase, t.x, t.y);
          } catch (err) {
            console.error('[VectorCraft] native.touch 异常: ' + JSON.stringify(err));
          }
        })
        .onMouse((event: MouseEvent) => {
          if (!this.started) {
            return;
          }
          let phase: number = 1;
          if (event.action === MouseAction.Press) {
            phase = 0;
          } else if (event.action === MouseAction.Release) {
            phase = 2;
          } else if (event.action !== MouseAction.Move) {
            return;
          }
          let button: number = 0;
          if (event.button === MouseButton.Right) {
            button = 1;
          } else if (event.button === MouseButton.Middle) {
            button = 2;
          }
          try {
            native.mouse(phase, button, event.x, event.y);
          } catch (err) {
            console.error('[VectorCraft] native.mouse 异常: ' + JSON.stringify(err));
          }
        })
        // 滚轮/触控板轴事件必须挂在 XComponent 上：指针整屏都在它上面，不冒泡到外层
        .onAxisEvent((event: AxisEvent) => {
          this.onWheel(event);
        })
        .onAreaChange(() => {
          if (!this.started) {
            return;
          }
          const m: SurfaceMetrics = this.surfaceMetrics();
          try {
            native.resize(m.width, m.height, m.dpi);
          } catch (err) {
            console.error('[VectorCraft] native.resize 异常: ' + JSON.stringify(err));
          }
        })
        .onDestroy(() => {
          this.stopEngine();
        })

      // IME 代理：引擎聚焦到文本输入时才会进组件树（否则会自己抢焦点弹输入法）
      if (this.showIme) {
        TextInput({ text: this.imeValue })
          .id('vc_ime')
          .width(2)
          .height(2)
          .opacity(0.01)
          .backgroundColor(Color.Transparent)
          .caretColor(Color.Transparent)
          .enablePreviewText(false)
          .onChange((value: string) => {
            this.onImeChange(value);
          })
      }
    }
    .width('100%')
    .height('100%')
  }

  // ---------------- 宽屏：左侧栏 ----------------

  @Builder
  SideBar() {
    Column() {
      // 品牌区：只在展开态显示。收起态下孤零零一个图标既无信息量又容易被误认，
      // 干脆整块不渲染，把空间留给下面的状态灯
      if (this.sidebarExpanded) {
        Row() {
          Image($r('app.media.app_icon'))
            .width(38)
            .height(38)
            .borderRadius(10)
          Column() {
            Text('矢量工坊')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('VectorCraft 引擎 · 鸿蒙版')
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 10 })
        }
        .width('100%')
        .padding({ left: 13, right: 13, top: 16, bottom: 16 })

        Divider().color($r('app.color.divider')).strokeWidth(1)
      } else {
        Blank().height(10)
      }

      // 引擎状态灯 + 状态文字（收起态不显示：一个孤立的圆点没有含义，看着像多余的控件）
      Column() {
        Row() {
          if (this.sidebarExpanded) {
            Circle()
              .width(7)
              .height(7)
              .fill(this.stateColor())
            Text(this.engineStateLabel())
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 8 })
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(this.sidebarExpanded ? FlexAlign.Start : FlexAlign.Center)
        // 展开态留左边距与文字对齐；收起态左右都留 0，居中才是真的居中
        .padding({ left: this.sidebarExpanded ? 16 : 0, right: this.sidebarExpanded ? 8 : 0 })
        .onClick(() => {
          if (!this.sidebarExpanded) {
            this.toast(this.engineStateLabel());
          }
        })
      }
      .width('100%')
      .height(34)
      .justifyContent(FlexAlign.Center)
      .alignItems(this.sidebarExpanded ? HorizontalAlign.Start : HorizontalAlign.Center)

      // 功能列表
      Column() {
        this.NavItem($r('app.media.ic_home'), '返回首页', '重启引擎回到首页', false, 'nav-home', () => {
          this.backToEditor();
        })
        this.NavItem($r('app.media.ic_recent'), '最近文件',
          this.recentList.length > 0 ? this.recentList.length + ' 个' : '暂无', false, 'nav-recent', () => {
            this.showRecent = true;
          })
        this.NavItem($r('app.media.ic_reload'), '重新加载引擎', '', false, 'nav-reload', () => {
          this.reloadEngine();
        })
        this.NavItem($r('app.media.ic_fullscreen'), this.fullScreen ? '退出全屏' : '全屏显示', '', false, 'nav-fullscreen',
          () => {
            this.toggleFullScreen();
          })
      }
      .width('100%')
      .margin({ top: 6 })

      Blank()

      // 底部
      Column() {
        this.NavItem($r('app.media.ic_help'), '使用说明', '', false, 'nav-help', () => {
          this.openHelp();
        })
        this.NavItem($r('app.media.ic_info'), '关于本应用', '', false, 'nav-about', () => {
          this.showAbout = true;
        })
        this.NavItem(this.sidebarExpanded ? $r('app.media.ic_collapse') : $r('app.media.ic_expand'),
          this.sidebarExpanded ? '收起侧边栏' : '展开', '', false, 'nav-collapse', () => {
            this.sidebarExpanded = !this.sidebarExpanded;
          })
        if (this.sidebarExpanded) {
          Text('v2.0.0 · 引擎 0.16.0')
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 16, top: 4, bottom: 12 })
        } else {
          Blank().height(12)
        }
      }
      .width('100%')
    }
    .width(this.sidebarWidth())
    .height('100%')
    .backgroundColor($r('app.color.panel_bg'))
    .border({ width: { right: 1 }, color: $r('app.color.divider') })
    .alignItems(HorizontalAlign.Start)
  }

  // ---------------- 中屏：顶部栏 ----------------

  @Builder
  TopBar() {
    Row() {
      Text('矢量工坊')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))

      Row() {
        Circle().width(6).height(6).fill(this.stateColor())
        Text(this.engineStateLabel())
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .margin({ left: 12 })
      .layoutWeight(1)

      this.IconButton($r('app.media.ic_home'), 'tb-home', () => {
        this.backToEditor();
      })
      this.IconButton($r('app.media.ic_recent'), 'tb-recent', () => {
        this.showRecent = true;
      })
      this.IconButton($r('app.media.ic_reload'), 'tb-reload', () => {
        this.reloadEngine();
      })
      this.IconButton($r('app.media.ic_help'), 'tb-help', () => {
        this.openHelp();
      })
      this.IconButton($r('app.media.ic_info'), 'tb-about', () => {
        this.showAbout = true;
      })
    }
    .width('100%')
    .height(this.topBarHeight())
    .padding({ left: 14, right: 10 })
    .backgroundColor($r('app.color.panel_bg'))
    .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
  }

  // ---------------- 窄屏：底部栏 ----------------

  @Builder
  BottomBar() {
    Column() {
      Row() {
        this.PillButton($r('app.media.ic_home'), '首页', () => {
          this.backToEditor();
        })
        this.PillButton($r('app.media.ic_recent'), '最近', () => {
          this.showRecent = true;
        })
        this.PillButton($r('app.media.ic_help'), '说明', () => {
          this.openHelp();
        })
        this.PillButton($r('app.media.ic_info'), '关于', () => {
          this.showAbout = true;
        })
      }
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.panel_bg'))
      .borderRadius(24)
      .border({ width: 1, color: $r('app.color.divider') })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(this.bottomBarHeight())
    .justifyContent(FlexAlign.Center)
    .align(Alignment.Bottom)
    .backgroundColor($r('app.color.shell_bg'))
  }

  // ---------------- 复用小部件 ----------------

  @Builder
  NavItem(icon: Resource, label: string, value: string, highlight: boolean, key: string, action: () => void) {
    Row() {
      Image(icon)
        .width(20)
        .height(20)
        .draggable(false)
      if (this.sidebarExpanded) {
        Column() {
          Text(label)
            .fontSize(13)
            .fontColor(highlight ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (value.length > 0) {
            Text(value)
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 1 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height(44)
    .padding({ left: this.sidebarExpanded ? 16 : 14, right: 10 })
    .justifyContent(this.sidebarExpanded ? FlexAlign.Start : FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor(this.pressedKey === key ? $r('app.color.panel_bg_hover') : Color.Transparent)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedKey = key;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (this.pressedKey === key) {
          this.pressedKey = '';
        }
      }
    })
    .onClick(() => {
      // 弹层可能吃掉 Up 事件，这里兜底复位，避免按钮停在深灰背景上
      if (this.pressedKey === key) {
        this.pressedKey = '';
      }
      action();
    })
  }

  @Builder
  IconButton(icon: Resource, key: string, action: () => void) {
    Image(icon)
      .width(34)
      .height(34)
      .padding(7)
      .borderRadius(9)
      .backgroundColor(this.pressedKey === key ? $r('app.color.panel_bg_hover') : Color.Transparent)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedKey = key;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          if (this.pressedKey === key) {
            this.pressedKey = '';
          }
        }
      })
      .onClick(() => {
        if (this.pressedKey === key) {
          this.pressedKey = '';
        }
        action();
      })
  }

  @Builder
  PillButton(icon: Resource, label: string, action: () => void) {
    Row() {
      Image(icon)
        .width(16)
        .height(16)
        .draggable(false)
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 6 })
        .maxLines(1)
    }
    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
    .margin({ left: 4, right: 4 })
    .borderRadius(18)
    .backgroundColor($r('app.color.panel_bg_hover'))
    .onClick(() => {
      action();
    })
  }

  // ---------------- 覆盖层 ----------------

  @Builder
  SplashOverlay() {
    Column() {
      Image($r('app.media.app_icon'))
        .width(72)
        .height(72)
        .borderRadius(18)
      Text('正在启动矢量工坊')
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 20 })
      Text(this.engineStateLabel())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 8 })
      LoadingProgress()
        .width(44)
        .height(44)
        .color($r('app.color.accent'))
        .margin({ top: 18 })
      Text('正在初始化原生渲染（wgpu · GLES）')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 14 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.shell_bg'))
  }

  @Builder
  RecentOverlay() {
    Column() {
      Column() {
        Row() {
          Text('最近文件')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (this.recentList.length > 0) {
            Text('清空')
              .fontSize(12)
              .fontColor($r('app.color.danger'))
              .padding({ left: 10, right: 4, top: 4, bottom: 4 })
              .onClick(() => {
                this.clearRecent();
              })
          }
        }
        .width('100%')

        Text('保存过的文件会在应用内留一份副本，点一下即可重新打开；杀进程或重启后依然在。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 8 })
          .width('100%')
          .textAlign(TextAlign.Start)

        if (this.recentList.length === 0) {
          Column() {
            Text('还没有保存过文件')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
            Text('在编辑器里保存后，这里就会出现')
              .fontSize(11)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 4 })
          }
          .width('100%')
          .height(120)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 6 }) {
            ForEach(this.recentList, (item: RecentEntry) => {
              ListItem() {
                this.RecentRow(item)
              }
            }, (item: RecentEntry) => item.id)
          }
          .width('100%')
          .height(306)
          .margin({ top: 12 })
          .scrollBar(BarState.Auto)
        }

        Button('关闭')
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.panel_bg_hover'))
          .width('100%')
          .height(40)
          .borderRadius(20)
          .margin({ top: 12 })
          .onClick(() => {
            this.showRecent = false;
          })
      }
      .width(this.isWide() ? 460 : '90%')
      .padding(22)
      .backgroundColor($r('app.color.panel_bg'))
      .borderRadius(18)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.55)')
    .onClick(() => {
      this.showRecent = false;
    })
  }

  @Builder
  RecentRow(item: RecentEntry) {
    Row() {
      Image($r('app.media.ic_save'))
        .width(20)
        .height(20)
        .draggable(false)
      Column() {
        Text(item.name)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(RecentStore.formatTime(item.savedAt) + ' · ' + RecentStore.formatSize(item.size))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 2 })
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })

      Text('打开')
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      Text('✕')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
        .onClick(() => {
          this.removeRecent(item);
        })
    }
    .width('100%')
    .height(54)
    .padding({ left: 12, right: 6 })
    .borderRadius(10)
    .backgroundColor($r('app.color.panel_bg_hover'))
    .onClick(() => {
      this.openRecent(item);
    })
  }

  @Builder
  AboutOverlay() {
    Column() {
      Column() {
        Image($r('app.media.app_icon'))
          .width(64)
          .height(64)
          .borderRadius(16)
        Text('矢量工坊 · 鸿蒙版')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 14 })
        Text('v2.0.0 · VectorCraft 0.16.0 引擎')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })

        Divider().color($r('app.color.divider')).strokeWidth(1).margin({ top: 16, bottom: 16 })

        this.AboutLine('编辑引擎', 'VectorCraft 0.16.0（原生）')
        this.AboutLine('上游项目', 'storytold/vectorcraft')
        this.AboutLine('界面语言', '简体中文（可在引擎内切换）')
        this.AboutLine('许可协议', 'MIT / Apache-2.0')
        this.AboutLine('渲染方式', 'wgpu · OpenGL ES 原生绘制')
        this.AboutLine('运行形态', this.platformLabel())

        Row() {
          Button('使用说明')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.panel_bg_hover'))
            .layoutWeight(1)
            .height(40)
            .borderRadius(20)
            .onClick(() => {
              this.showAbout = false;
              this.openHelp();
            })
          Button('关闭')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.accent'))
            .layoutWeight(1)
            .height(40)
            .borderRadius(20)
            .margin({ left: 10 })
            .onClick(() => {
              this.showAbout = false;
            })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width(this.isWide() ? 400 : '88%')
      .padding(24)
      .backgroundColor($r('app.color.panel_bg'))
      .borderRadius(18)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.55)')
    .onClick(() => {
      this.showAbout = false;
    })
  }

  @Builder
  AboutLine(key: string, value: string) {
    Row() {
      Text(key)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      Blank()
      Text(value)
        .fontSize(12)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  private platformLabel(): string {
    if (this.deviceType === '2in1') {
      return '鸿蒙电脑 / 二合一';
    }
    if (this.deviceType === 'tablet') {
      return '鸿蒙平板';
    }
    return '鸿蒙手机';
  }

  @Builder
  ErrorOverlay() {
    Column() {
      Column() {
        Image($r('app.media.ic_warning'))
          .width(44)
          .height(44)
        Text('矢量引擎启动失败')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ top: 12 })
        Text(this.fatalError.length > 0 ? this.fatalError : this.engineMessage)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 10 })
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row() {
          Button('重新加载')
            .fontSize(13)
            .backgroundColor($r('app.color.accent'))
            .fontColor(Color.White)
            .layoutWeight(1)
            .height(38)
            .borderRadius(19)
            .onClick(() => {
              this.reloadEngine();
            })
          Button('重新启动引擎')
            .fontSize(13)
            .backgroundColor($r('app.color.panel_bg_hover'))
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .height(38)
            .borderRadius(19)
            .margin({ left: 10 })
            .onClick(() => {
              this.reloadEngine();
            })
        }
        .width('100%')
        .margin({ top: 20 })
      }
      .width(this.isWide() ? 420 : '88%')
      .padding(24)
      .backgroundColor($r('app.color.panel_bg'))
      .borderRadius(18)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.shell_bg'))
  }
}
