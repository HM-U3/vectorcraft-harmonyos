import { AppConstants } from '../common/Constants';

/**
 * 使用说明
 *
 * 原生帮助页，讲清外壳上的每一项操作、引擎能做什么/不能做什么，
 * 以及真机上常见问题的排查步骤。内容与本工程实际实现严格对应，不含推测性描述。
 */
@Entry
@Component
struct Help {
  @StorageProp('deviceType') deviceType: string = 'phone';
  @StorageProp('engineState') engineState: string = AppConstants.STATE_IDLE;

  private platformLabel(): string {
    if (this.deviceType === '2in1') {
      return '鸿蒙电脑 / 二合一';
    }
    if (this.deviceType === 'tablet') {
      return '鸿蒙平板';
    }
    return '鸿蒙手机';
  }

  build() {
    Column() {
      this.TitleBar()

      Scroll() {
        Column() {
          this.Section('这是什么', [
            '本应用是开源矢量插画编辑器 VectorCraft 的鸿蒙原生客户端，并已做界面汉化：' +
              '编辑引擎以原生库（libvectorcraft_native.so）编译进安装包，直接画在系统图形表面上，' +
              '不含 WebView，也不加载 WebAssembly；鸿蒙侧另外提供一层原生外壳。',
            '界面文案全部为简体中文 —— 外壳（侧栏 / 顶栏 / 底栏、状态提示、本说明）由本工程编写；' +
              '编辑器内部的菜单、工具与面板名称来自上游官方简体中文语言包（zh-hans），' +
              '并内嵌了中文字体子集（Noto Sans SC），因此无需系统安装中文字体也能正常显示。',
            '产品名与技术名（VectorCraft、SVG、PDF、CMYK、Lab 等）按上游约定保留原文。'
          ])

          this.Section('第一次启动', [
            '首次启动需要把约 62 MB 的引擎读入内存并编译，通常需要十几秒到几十秒，' +
              '期间会显示进度条，属正常现象，之后再次启动会快很多。',
            '引擎就绪后，状态指示灯变蓝并显示「引擎就绪」。',
            '如果卡在加载页超过 2 分钟，见下方「启动失败怎么办」。'
          ])

          this.Section('保存与导出', [
            '「保存 / 另存为 / 导出」都会弹出系统「保存到」选择器：选好目录后点保存，' +
              '文件就写到那里，完成后会提示完整的保存路径。',
            '支持导出的格式以上游为准：SVG、PDF、PNG、JPEG、WebP，以及工程格式 .vectorcraft。',
            '如果选择器不可用（少数设备或分屏状态），会自动改存到应用自己的目录，' +
              '提示里会给出完整路径；该目录属于应用沙箱，普通文件管理器看不到，' +
              '所以尽量使用选择器保存到「下载」或「文档」。',
            '导出复杂图形时会先编码再传送，大文件通常需要几秒，期间不要退出应用。'
          ])

          this.Section('最近文件', [
            '每次保存成功后，文件会自动出现在「最近文件」里（侧栏 / 顶栏 / 底栏第二个入口）。' +
              '列表保存在应用内，杀进程、重启平板后仍然在，最多保留 12 条，同名文件只留最新一次。',
            '点一下条目即可重新打开，编辑器会把它载入成一个标签页；点右侧的 ✕ 移除单条，' +
              '右上角「清空」会删除全部记录。',
            '为了能重新打开，应用会把文件另存一份副本在自身的沙箱里（所以会多占一点空间，' +
              '删除记录时副本一并删除）。卸载应用会同时清掉这些副本。',
            '注意：编辑器菜单里自带的「最近文件 / 打开最近使用的文件」是按文件路径记录的，' +
              '鸿蒙沙箱里没有这类真实路径，因此不可用 —— 请使用外壳上的「最近文件」面板。'
          ])

          this.Section('外壳上的操作', [
            '返回首页：重启原生引擎并回到引擎首页。引擎里的外链会交给系统浏览器打开，' +
              '不会把编辑器顶掉；万一编辑状态乱了，点这里就能回到干净的首页，不需要退出应用。',
            '渲染后端：切换引擎绘制图形的方式，切换后引擎会重新加载。',
            '重新加载引擎：不退出应用，直接重启编辑引擎。',
            '全屏显示：隐藏状态栏与导航栏，获得更大的画布（电脑上同时隐藏窗口标题栏）。',
            '关于：查看版本、引擎版本、许可协议与运行形态。',
            '使用说明：即本页。'
          ])

          this.Section('三种形态的界面', [
            '鸿蒙电脑 / 二合一：左侧竖向侧边栏，可展开为 216vp 或收起为 64vp 图标条。',
            '鸿蒙平板：顶部工具栏，左侧显示名称与引擎状态，右侧是操作按钮。',
            '鸿蒙手机 / 小窗：底部悬浮胶囊按钮组。',
            '拖拽窗口改变宽度时，界面会在三种形态之间实时切换；当前识别为：' + this.platformLabel() + '。'
          ])

          this.Section('渲染方式', [
            '引擎由 Rust 原生库直接绘制（wgpu · OpenGL ES），没有 WebView、没有 WebAssembly 加载环节。',
            '启动速度只取决于系统能否创建 GL 上下文，通常半秒内出首帧。',
            '当前引擎状态：' + this.stateLabel()
          ])

          this.Section('启动失败怎么办', [
            '错误面板里有「重新加载」和「重新启动引擎」两个按钮，先点后者。',
            '「重新启动引擎」会先停掉渲染线程再原地拉起，能解决大部分一次性初始化失败。',
            '侧栏 / 顶栏的「重新加载引擎」可以在不退出应用的情况下重启引擎，值得多试一次。',
            '仍然无法启动时，请记录设备型号、系统版本与出错前的操作，到项目仓库提交 Issue：' +
              'github.com/HM-U3/vectorcraft-harmonyos/issues'
          ])

          this.Section('已知限制', [
            '上游 VectorCraft 仍在活跃开发中（alpha 阶段），功能完整度与稳定性以上游为准；' +
              '崩溃请先确认在上游 Web 版是否同样出现。',
            '内嵌的中文字体是子集（覆盖全部界面用字），若在文字图层里输入生僻字，' +
              '可能显示为空白；系统安装了中文字体时会自动回退到系统字体。',
            '界面语言可在编辑器的「首选项 › 界面 › 语言」中改回 English 或其它语言。' +
              '英文正常（用的是内嵌 Inter 字体）；日文假名、韩文等不在内嵌子集内，需要系统字体支持。',
            '引擎完全在本地运行，不联网、无服务端，所有处理都在设备内存与 GPU 中完成。',
            '浏览器打印（File → Print）在鸿蒙 Web 组件内可能不可用，' +
              '需要打印时请先导出 PDF，再用系统 PDF 查看器打印。'
          ])

          this.Section('隐私说明', [
            '本应用不收集、不上传任何个人信息：没有账号体系，也不含统计、广告、推送等第三方 SDK。',
            '引擎、字体、图标全部内嵌在安装包内，应用运行时不发起任何网络请求；' +
              '点「在 GitHub 上查看」等外链时由系统浏览器打开，不向应用回传数据。',
            '未申请任何权限：相机、麦克风、位置、通讯录、存储、网络等权限均未声明，安装后即可使用全部功能。',
            '作品与「最近文件」只存在本机：文件副本位于应用沙箱（files/recents），' +
              '列表记录位于应用本地存储；卸载应用即一并删除，开发者与其他应用都无法读取。',
            '导出的文件写入你通过系统「保存到」选择器指定的位置，应用不会扫描或读取其他目录。',
            '内嵌的第三方组件为开源引擎 VectorCraft（MIT / Apache-2.0）与 Noto Sans SC 字体子集（OFL 1.1），' +
              '两者均不含数据采集代码。',
            '如对隐私有疑问，可在项目仓库提交 Issue：github.com/HM-U3/vectorcraft-harmonyos/issues'
          ])

          this.Section('版本与许可', [
            '客户端版本：2.0.0',
            '编辑引擎：VectorCraft 0.16.0（上游 v0.16.0 源码交叉编译为鸿蒙原生库，MIT / Apache-2.0 双许可）',
            '引擎改动：默认加载简体中文语言包；内嵌 Noto Sans SC 子集字体（OFL 1.1，已改名）；' +
              '新增了一个不依赖 eframe 的鸿蒙原生宿主（surface 输入转发、系统文件选择器对接）',
            '上游项目：storytold/vectorcraft',
            '本客户端仅做本地适配，引擎相对上游只做了最小改动（默认语言、字体注册与字族回退链、' +
              '原生宿主对接，以及按应用市场要求移除首屏与应用栏的社区外链）；' +
              '应用图标与本页内容由本工程原创。'
          ])

          Blank().height(24)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 4, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.shell_bg'))
  }

  private stateLabel(): string {
    if (this.engineState === AppConstants.STATE_READY) {
      return '就绪';
    }
    if (this.engineState === AppConstants.STATE_ERROR) {
      return '报错';
    }
    if (this.engineState === AppConstants.STATE_LOADING) {
      return '加载中';
    }
    return '未启动';
  }

  @Builder
  TitleBar() {
    Row() {
      Image($r('app.media.ic_help'))
        .width(22)
        .height(22)
        .draggable(false)
      Text('使用说明')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ left: 10 })
      Blank()
      Text('返回')
        .fontSize(13)
        .fontColor($r('app.color.accent'))
        .padding({ left: 12, right: 4, top: 8, bottom: 8 })
        .onClick(() => {
          try {
            this.getUIContext().getRouter().back();
          } catch (err) {
            console.error('[VectorCraft] 返回失败: ' + JSON.stringify(err));
          }
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 14 })
    .backgroundColor($r('app.color.panel_bg'))
    .border({ width: { bottom: 1 }, color: $r('app.color.divider') })
  }

  @Builder
  Section(title: string, lines: string[]) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 10 })
      ForEach(lines, (line: string) => {
        Row() {
          Circle()
            .width(4)
            .height(4)
            .fill($r('app.color.accent'))
            .margin({ top: 8 })
          Text(line)
            .fontSize(13)
            .lineHeight(21)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 10 })
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ bottom: 8 })
      }, (line: string) => line)
    }
    .width('100%')
    .padding(16)
    .margin({ bottom: 14 })
    .backgroundColor($r('app.color.panel_bg'))
    .borderRadius(14)
    .alignItems(HorizontalAlign.Start)
  }
}
