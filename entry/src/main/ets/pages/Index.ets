import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ResourceBridge } from '../common/ResourceBridge';
import { RecentStore, RecentEntry } from '../common/RecentStore';
import { AppConstants, RenderModes, RenderOption } from '../common/Constants';

/**
 * VectorCraft 主页面
 *
 * 结构：一个全屏 Stack，底层是承载 WebAssembly 编辑引擎的 Web 组件，
 * 上层是根据窗口宽度自适应的原生外壳（PC 侧栏 / 平板顶栏 / 手机底栏）。
 */
@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  private bridge: ResourceBridge | undefined = undefined;
  private mainWindow: window.Window | undefined = undefined;
  private recent: RecentStore | undefined = undefined;
  private b64: util.Base64Helper = new util.Base64Helper();

  @StorageProp('engineState') engineState: string = AppConstants.STATE_IDLE;
  @StorageProp('engineMessage') engineMessage: string = '';
  @StorageProp('winWidthVp') winWidthVp: number = 0;
  @StorageProp('deviceType') deviceType: string = 'phone';
  @StorageLink('renderMode') renderMode: string = AppConstants.MODE_AUTO;
  // 原生桥写回的「保存 / 导出」结果，弹 toast 让用户知道文件去了哪
  @StorageProp('saveStatus') @Watch('onSaveStatus') saveStatus: string = '';

  @State pageLoaded: boolean = false;
  @State fatalError: string = '';
  @State sidebarExpanded: boolean = false;
  @State showAbout: boolean = false;
  @State showModePanel: boolean = false;
  @State showRecent: boolean = false;
  @State recentList: RecentEntry[] = [];
  @State fullScreen: boolean = false;
  @State statusText: string = '正在准备…';
  // 手动维护的按压态：某些场景（点击后立即弹出覆盖层）拿不到 touch Up，
  // 用 stateStyles 的 pressed 会卡在深色背景上不恢复，所以自己记一个 key
  @State pressedKey: string = '';

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.bridge = new ResourceBridge(ctx);
    this.mainWindow = AppStorage.get<window.Window>('mainWindow');

    // 最近文件：原生侧自带一份（引擎自带的那份基于文件路径，Web 端必然失效）
    const store = new RecentStore(ctx);
    this.recent = store;
    this.recentList = store.list();
    this.bridge.onFileSaved = (name: string, path: string, data: Uint8Array): void => {
      this.recentList = store.add(name, path, data);
    };

    console.info('[VectorCraft] Index aboutToAppear, renderMode=' + this.renderMode
      + ', 最近文件=' + this.recentList.length);
    // 兜底：即使页面事件未回调，也避免原生遮罩长期挡住网页自身的启动进度
    setTimeout(() => {
      if (!this.pageLoaded) {
        this.pageLoaded = true;
      }
    }, 5000);
  }

  aboutToDisappear(): void {
    if (this.bridge) {
      this.bridge.releaseCache();
    }
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

  private reloadEngine(): void {
    this.fatalError = '';
    this.pageLoaded = false;
    this.statusText = '正在重新加载…';
    try {
      this.controller.refresh();
    } catch (err) {
      console.error('[VectorCraft] 刷新失败: ' + JSON.stringify(err));
      this.toast('刷新失败，请重试');
    }
  }

  /**
   * 回到编辑器首页。
   *
   * 引擎内的「在 GitHub 上查看」这类外链如果真把页面顶掉了（宿主没接住、或用了
   * 其它跳转方式），引擎自己没有返回键，就只能杀掉应用重开。这里提供一个常驻出口：
   * 重新加载内置首页即可，正常情况下等价于一次刷新。
   */
  private backToEditor(): void {
    console.info('[VectorCraft] backToEditor');
    this.fatalError = '';
    this.pageLoaded = false;
    this.statusText = '正在返回编辑器…';
    try {
      this.controller.loadUrl(AppConstants.WEB_ENTRY);
    } catch (err) {
      console.error('[VectorCraft] 返回编辑器失败: ' + JSON.stringify(err));
      this.reloadEngine();
    }
  }

  private switchRenderMode(mode: string): void {
    this.showModePanel = false;
    if (mode === this.renderMode) {
      return;
    }
    this.renderMode = mode;
    this.fatalError = '';
    this.pageLoaded = false;
    this.statusText = '正在切换到 ' + RenderModes.label(mode) + '…';
    this.toast('渲染后端已切换为「' + RenderModes.label(mode) + '」，正在重启引擎');
    // 刷新页面，index.html 会重新向宿主查询渲染后端
    setTimeout(() => {
      try {
        this.controller.refresh();
      } catch (err) {
        console.error('[VectorCraft] 切换后端失败: ' + JSON.stringify(err));
      }
    }, 120);
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
   * 思路：原生侧在保存时留了一份沙箱副本，这里把副本字节分块推进页面，
   * 页面把它们还原成 File 并合成一次 drop 事件 —— 引擎的拖放监听只读
   * dataTransfer.files，等价于用户把文件拖进画布，于是正常打开。
   */
  private openRecent(entry: RecentEntry): void {
    if (this.fatalError.length > 0 || this.engineState !== AppConstants.STATE_READY) {
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
    this.toast('正在打开 ' + entry.name);
    this.injectRecent(entry.name, data).catch((err: Error) => {
      console.error('[VectorCraft] 打开最近文件失败: ' + JSON.stringify(err));
      this.toast('打开失败，请重试');
    });
  }

  private async injectRecent(name: string, data: Uint8Array): Promise<void> {
    const CHUNK: number = 256 * 1024;
    try {
      this.controller.runJavaScript('window.__vcOpenFileBegin(' + JSON.stringify(name) + ',' + data.length + ')');
      for (let off = 0; off < data.length; off += CHUNK) {
        const end: number = Math.min(data.length, off + CHUNK);
        const chunk: string = this.b64.encodeToStringSync(data.subarray(off, end));
        this.controller.runJavaScript('window.__vcOpenFileChunk("' + chunk + '")');
        // 让出一次事件循环，避免大文件把 UI 线程占满
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 0);
        });
      }
      this.controller.runJavaScript('window.__vcOpenFileEnd()');
      console.info('[VectorCraft] 已把最近文件注入页面: ' + name + ' ' + data.length + ' 字节');
    } catch (err) {
      console.error('[VectorCraft] 注入最近文件失败: ' + JSON.stringify(err));
      throw new Error('注入失败');
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
      return '引擎就绪 · ' + RenderModes.label(this.renderMode);
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
      // 1. 编辑引擎承载区
      Column() {
        this.WebHost()
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

      // 3. 页面首帧之前的原生过渡遮罩
      if (!this.pageLoaded && this.fatalError.length === 0 && this.engineState !== AppConstants.STATE_ERROR) {
        this.SplashOverlay()
      }

      // 4. 渲染后端选择面板
      if (this.showModePanel) {
        this.ModeOverlay()
      }

      // 5. 关于面板
      if (this.showAbout) {
        this.AboutOverlay()
      }

      // 6. 最近文件面板
      if (this.showRecent) {
        this.RecentOverlay()
      }

      // 7. 致命错误面板
      if (this.fatalError.length > 0 || this.engineState === AppConstants.STATE_ERROR) {
        this.ErrorOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.shell_bg'))
  }

  @Builder
  WebHost() {
    Web({ src: $rawfile('vectorcraft/index.html'), controller: this.controller })
      .width('100%')
      .height('100%')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(true)
      .imageAccess(true)
      .onlineImageAccess(true)
      .mixedMode(MixedMode.All)
      .cacheMode(CacheMode.Default)
      .zoomAccess(false)
      .horizontalScrollBarAccess(false)
      .verticalScrollBarAccess(false)
      .javaScriptProxy({
        object: this.bridge!,
        name: 'vcBridge',
        methodList: ['renderMode', 'lang', 'deviceType', 'viewportWidth', 'reportState', 'assetSize', 'assetChunk', 'log',
          'beginSave', 'saveChunk', 'finishSave', 'openUrl'],
        controller: this.controller
      })
      .onPageBegin(() => {
        console.info('[VectorCraft] onPageBegin');
      })
      .onPageEnd(() => {
        console.info('[VectorCraft] onPageEnd');
        this.pageLoaded = true;
      })
      .onConsole((event) => {
        if (event) {
          console.info('[VectorCraft][web] ' + event.message.getMessage());
        }
        return false;
      })
      .onErrorReceive((event) => {
        if (!event) {
          return;
        }
        try {
          const isMain: boolean = event.request.isMainFrame();
          const info: string = event.error.getErrorInfo();
          const code: number = event.error.getErrorCode();
          console.error('[VectorCraft] 资源加载失败 main=' + isMain + ' code=' + code + ' info=' + info);
          if (isMain) {
            this.fatalError = '无法加载内置页面（code ' + code + '）：' + info;
          }
        } catch (err) {
          console.error('[VectorCraft] 处理加载错误失败: ' + JSON.stringify(err));
        }
      })
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

      // 引擎状态灯 + 状态文字
      Column() {
        Row() {
          Circle()
            .width(7)
            .height(7)
            .fill(this.stateColor())
          if (this.sidebarExpanded) {
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
        this.NavItem($r('app.media.ic_home'), '返回编辑器', '回到首页并重新加载', false, 'nav-home', () => {
          this.backToEditor();
        })
        this.NavItem($r('app.media.ic_recent'), '最近文件',
          this.recentList.length > 0 ? this.recentList.length + ' 个' : '暂无', false, 'nav-recent', () => {
            this.showRecent = true;
          })
        this.NavItem($r('app.media.ic_render'), '渲染后端', RenderModes.label(this.renderMode), true, 'nav-render', () => {
          this.showModePanel = true;
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
          Text('v1.0.0 · 引擎 0.12.0')
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
      this.IconButton($r('app.media.ic_render'), 'tb-render', () => {
        this.showModePanel = true;
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
        this.PillButton($r('app.media.ic_home'), '返回编辑器', () => {
          this.backToEditor();
        })
        this.PillButton($r('app.media.ic_recent'), '最近', () => {
          this.showRecent = true;
        })
        this.PillButton($r('app.media.ic_render'), RenderModes.label(this.renderMode), () => {
          this.showModePanel = true;
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
      Text('首次启动需要编译约 62 MB 矢量引擎，请稍候')
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
  ModeOverlay() {
    Column() {
      Column() {
        Text('渲染后端')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text('切换后编辑引擎会重新加载。若画面异常或无法启动，请选择 WebGL2。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 8 })
          .textAlign(TextAlign.Start)
        this.ModeRow(AppConstants.MODE_AUTO)
        this.ModeRow(AppConstants.MODE_WEBGL)
        Button('取消')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .margin({ top: 8 })
          .onClick(() => {
            this.showModePanel = false;
          })
      }
      .width(this.isWide() ? 380 : '86%')
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
      this.showModePanel = false;
    })
  }

  @Builder
  ModeRow(value: string) {
    Row() {
      Column() {
        Text(RenderModes.label(value))
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
        Text(this.modeDesc(value))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.renderMode === value) {
        Text('已启用')
          .fontSize(11)
          .fontColor($r('app.color.accent'))
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .margin({ top: 10 })
    .borderRadius(12)
    .backgroundColor(this.renderMode === value ? $r('app.color.accent_soft') : $r('app.color.panel_bg_hover'))
    .onClick(() => {
      this.switchRenderMode(value);
    })
  }

  private modeDesc(value: string): string {
    const list: RenderOption[] = RenderModes.all();
    for (let i = 0; i < list.length; i++) {
      if (list[i].value === value) {
        return list[i].desc;
      }
    }
    return '';
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
        Text('v1.0.0 · VectorCraft 0.12.0 引擎')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 4 })

        Divider().color($r('app.color.divider')).strokeWidth(1).margin({ top: 16, bottom: 16 })

        this.AboutLine('编辑引擎', 'VectorCraft 0.12.0（WebAssembly）')
        this.AboutLine('上游项目', 'storytold/vectorcraft')
        this.AboutLine('界面语言', '简体中文（可在引擎内切换）')
        this.AboutLine('许可协议', 'MIT / Apache-2.0')
        this.AboutLine('渲染后端', RenderModes.label(this.renderMode))
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
          Button('改用 WebGL2')
            .fontSize(13)
            .backgroundColor($r('app.color.panel_bg_hover'))
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .height(38)
            .borderRadius(19)
            .margin({ left: 10 })
            .onClick(() => {
              this.switchRenderMode(AppConstants.MODE_WEBGL);
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
