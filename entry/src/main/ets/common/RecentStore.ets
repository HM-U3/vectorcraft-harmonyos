import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/**
 * 最近文件条目
 *
 * 说明：引擎自带的「最近文件」存的是**文件路径**，Web/ArkWeb 里没有真实路径，
 * 所以那份列表在本应用里必然失效。这里由原生侧自己维护一份：
 * - 每次保存成功，把字节**另存一份副本**到应用沙箱（docs 目录的 URI 之后不一定还能读）；
 * - 列表本身用 Preferences 持久化，杀掉应用也不会丢；
 * - 点开时把副本字节喂回引擎（见 Index.injectRecent）。
 */
export interface RecentEntry {
  /** 唯一 id（保存时刻的毫秒时间戳） */
  id: string;
  /** 原始文件名，用于显示与回填 */
  name: string;
  /** 用户保存到的位置（仅展示，可能已不可读） */
  path: string;
  /** 沙箱副本的绝对路径（重新打开时读它） */
  copy: string;
  /** 字节数 */
  size: number;
  /** 保存时间（毫秒时间戳） */
  savedAt: number;
}

const PREF_NAME: string = 'vc_recent_files';
const PREF_KEY: string = 'list';
const MAX_ENTRIES: number = 12;
const DIR_NAME: string = 'recents';

export class RecentStore {
  private context: common.UIAbilityContext;
  private store: preferences.Preferences | undefined = undefined;
  private entries: RecentEntry[] = [];

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.entries = this.load();
  }

  // ---------------- 读取 ----------------

  list(): RecentEntry[] {
    return this.entries;
  }

  /** 按 id 读取副本字节；副本丢失时返回 undefined */
  read(id: string): Uint8Array | undefined {
    for (let i = 0; i < this.entries.length; i++) {
      const e = this.entries[i];
      if (e.id === id) {
        return this.readFile(e.copy);
      }
    }
    return undefined;
  }

  // ---------------- 写入 ----------------

  /** 保存成功后调用：落一份副本、插到列表头、返回新列表 */
  add(name: string, displayPath: string, data: Uint8Array): RecentEntry[] {
    const now: number = Date.now();
    const safeName: string = RecentStore.safeName(name);
    let copyPath: string = '';
    try {
      const dir: string = this.context.filesDir + '/' + DIR_NAME;
      try {
        fs.mkdirSync(dir, true);
      } catch (err) {
        // 目录已存在
      }
      copyPath = dir + '/' + now + '-' + safeName;
      const file = fs.openSync(copyPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, RecentStore.toBuffer(data));
      fs.closeSync(file);
    } catch (err) {
      console.error('[VectorCraft] 最近文件副本写入失败: ' + JSON.stringify(err));
      copyPath = '';
    }

    const entry: RecentEntry = {
      id: String(now),
      name: name,
      path: displayPath,
      copy: copyPath,
      size: data.length,
      savedAt: now
    };

    // 同名文件视为同一条记录：先移除旧的（连同它的副本）
    const kept: RecentEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].name !== name) {
        kept.push(this.entries[i]);
      } else {
        this.deleteFile(this.entries[i].copy);
      }
    }
    kept.unshift(entry);

    // 超出上限的旧记录连副本一起清掉
    const out: RecentEntry[] = [];
    for (let i = 0; i < kept.length; i++) {
      if (i < MAX_ENTRIES) {
        out.push(kept[i]);
      } else {
        this.deleteFile(kept[i].copy);
      }
    }
    this.entries = out;
    this.save();
    console.info('[VectorCraft] 最近文件 +1: ' + name + ' 共 ' + out.length + ' 条');
    return this.entries;
  }

  remove(id: string): RecentEntry[] {
    const out: RecentEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      const e = this.entries[i];
      if (e.id === id) {
        this.deleteFile(e.copy);
      } else {
        out.push(e);
      }
    }
    this.entries = out;
    this.save();
    return this.entries;
  }

  clear(): RecentEntry[] {
    for (let i = 0; i < this.entries.length; i++) {
      this.deleteFile(this.entries[i].copy);
    }
    this.entries = [];
    this.save();
    return this.entries;
  }

  // ---------------- 展示辅助 ----------------

  /** 「刚刚 / 今天 19:42 / 10-17 19:42 / 2026-10-17」 */
  static formatTime(ts: number): string {
    if (!ts) {
      return '';
    }
    const d = new Date(ts);
    const now = new Date();
    const pad = (n: number): string => n < 10 ? '0' + n : String(n);
    const hm: string = pad(d.getHours()) + ':' + pad(d.getMinutes());
    const sameDay: boolean = d.getFullYear() === now.getFullYear() &&
      d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
    if (sameDay) {
      return '今天 ' + hm;
    }
    const mmdd: string = pad(d.getMonth() + 1) + '-' + pad(d.getDate());
    if (d.getFullYear() === now.getFullYear()) {
      return mmdd + ' ' + hm;
    }
    return String(d.getFullYear()) + '-' + mmdd;
  }

  /** 1.2 KB / 340 KB / 2.4 MB */
  static formatSize(bytes: number): string {
    if (bytes < 1024) {
      return String(bytes) + ' B';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(0) + ' KB';
    }
    return (bytes / 1048576).toFixed(1) + ' MB';
  }

  /** 只保留文件名里安全的字符，避免拼路径时出问题 */
  static safeName(name: string): string {
    let out: string = '';
    for (let i = 0; i < name.length; i++) {
      const c: string = name.charAt(i);
      if ('\\/:*?"<>|'.indexOf(c) >= 0 || c === ' ') {
        out += '_';
      } else {
        out += c;
      }
    }
    if (out.length === 0) {
      out = 'document';
    }
    if (out.length > 80) {
      out = out.substring(out.length - 80);
    }
    return out;
  }

  // ---------------- 内部 ----------------

  private pref(): preferences.Preferences | undefined {
    if (this.store) {
      return this.store;
    }
    try {
      this.store = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      return this.store;
    } catch (err) {
      console.error('[VectorCraft] 打开 Preferences 失败: ' + JSON.stringify(err));
      return undefined;
    }
  }

  private load(): RecentEntry[] {
    const p = this.pref();
    if (!p) {
      return [];
    }
    try {
      const text: string = p.getSync(PREF_KEY, '[]') as string;
      const parsed: RecentEntry[] = JSON.parse(text) as RecentEntry[];
      // 过滤掉副本已不存在的记录（用户可能清理过数据）
      const out: RecentEntry[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const e = parsed[i];
        if (e && e.id && e.name && e.copy && this.exists(e.copy)) {
          out.push(e);
        }
      }
      return out;
    } catch (err) {
      console.error('[VectorCraft] 读取最近文件失败: ' + JSON.stringify(err));
      return [];
    }
  }

  private save(): void {
    const p = this.pref();
    if (!p) {
      return;
    }
    try {
      p.putSync(PREF_KEY, JSON.stringify(this.entries));
      p.flush();
    } catch (err) {
      console.error('[VectorCraft] 写入最近文件失败: ' + JSON.stringify(err));
    }
  }

  private exists(path: string): boolean {
    if (!path) {
      return false;
    }
    try {
      fs.accessSync(path);
      return true;
    } catch (err) {
      return false;
    }
  }

  private readFile(path: string): Uint8Array | undefined {
    if (!this.exists(path)) {
      return undefined;
    }
    try {
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return new Uint8Array(buf);
    } catch (err) {
      console.error('[VectorCraft] 读取最近文件副本失败: ' + JSON.stringify(err));
      return undefined;
    }
  }

  private deleteFile(path: string): void {
    if (!path) {
      return;
    }
    try {
      if (this.exists(path)) {
        fs.unlinkSync(path);
      }
    } catch (err) {
      console.info('[VectorCraft] 删除副本失败（忽略）: ' + JSON.stringify(err));
    }
  }

  private static toBuffer(data: Uint8Array): ArrayBuffer {
    return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
  }
}
