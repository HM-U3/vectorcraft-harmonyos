/**
 * 全局常量与配置
 *
 * 引擎由 Rust 原生库（libvectorcraft_native.so）通过 wgpu/GLES 直接画进 XComponent，
 * 不再有 WebView / wasm，因此这里只保留宿主外壳需要的常量。
 */

export class AppConstants {
  /** 界面语言（BCP 47，与上游 i18n 目录一致；引擎启动时由宿主传入系统语言） */
  static readonly LANG_ZH_HANS: string = 'zh-hans';

  /** 布局断点（vp） */
  static readonly BREAKPOINT_MEDIUM: number = 600;
  static readonly BREAKPOINT_WIDE: number = 840;

  /** AppStorage 键名 */
  static readonly KEY_ENGINE_STATE: string = 'engineState';
  static readonly KEY_ENGINE_MESSAGE: string = 'engineMessage';
  static readonly KEY_LANG: string = 'uiLang';
  static readonly KEY_WIN_W: string = 'winWidthVp';
  static readonly KEY_WIN_H: string = 'winHeightVp';
  static readonly KEY_DEVICE_TYPE: string = 'deviceType';
  static readonly KEY_MAIN_WINDOW: string = 'mainWindow';

  /** 保存/导出结果提示（由保存流程写入，Index 弹 toast 展示） */
  static readonly KEY_SAVE_STATUS: string = 'saveStatus';

  /** 引擎状态 */
  static readonly STATE_IDLE: string = 'idle';
  static readonly STATE_LOADING: string = 'loading';
  static readonly STATE_READY: string = 'ready';
  static readonly STATE_ERROR: string = 'error';
}

/** XComponent 表面尺寸（像素）与 DPI 缩放系数，原样交给 Rust 的 start/resize。 */
export interface SurfaceMetrics {
  width: number;
  height: number;
  dpi: number;
}
