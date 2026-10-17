#!/usr/bin/env python3
"""把 trunk 构建出的 VectorCraft Web 产物打包成鸿蒙 rawfile 资源。

输入：trunk build --release 的输出目录（dist/web）
输出：entry/src/main/resources/rawfile/vectorcraft/
  - index.html            改写版（经典脚本注入 / 三层容错 / 保存导出接管 / 外链接管）
  - vectorcraft-web-<hash>.js        上游 ESM 胶水层（原样保留备查）
  - vectorcraft-web-<hash>.classic.js 等价转换后的经典脚本（鸿蒙实际加载）
  - vectorcraft-web-<hash>_bg.wasm   引擎本体

用法：
    python tools/pack_web.py [--dist <trunk dist 目录>] [--out <rawfile 输出目录>]
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent

# ------------------------------------------------------------------
# index.html 模板（改写版）
# ------------------------------------------------------------------

INDEX_TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
  <meta name="theme-color" content="#262626">
  <title>矢量工坊</title>
  <style>
    html, body {
      margin: 0; padding: 0; width: 100%; height: 100%;
      overflow: hidden; background: #262626;
      overscroll-behavior: none;
      -webkit-user-select: none; user-select: none;
      -webkit-touch-callout: none; -webkit-tap-highlight-color: transparent;
      -webkit-text-size-adjust: 100%;
    }
    #vectorcraft_canvas {
      position: absolute; inset: 0; width: 100%; height: 100%;
      display: block; outline: none; touch-action: none;
    }
    #vectorcraft_loading { display: none; }
    #vc_splash {
      position: absolute; inset: 0; z-index: 10;
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      background: #23262b;
      color: #cfd3d8;
      font: 14px "HarmonyOS Sans SC", -apple-system, "Segoe UI", system-ui, sans-serif;
    }
    #vc_splash.vc-hidden { display: none; }
    #vc_splash .vc-logo {
      width: 72px; height: 72px; border-radius: 18px; margin-bottom: 22px;
      background: linear-gradient(135deg, #1c3f8a 0%, #2f7bf5 100%);
      display: flex; align-items: center; justify-content: center;
      box-shadow: 0 10px 30px rgba(47, 123, 245, .28);
    }
    #vc_splash .vc-logo svg { width: 44px; height: 44px; }
    #vc_bar { width: 248px; height: 4px; border-radius: 2px; background: #3a3f47; overflow: hidden; margin-top: 18px; }
    #vc_bar > i { display: block; height: 100%; width: 0%; background: #4c8dff; transition: width .16s ease; }
    #vc_tip { margin-top: 12px; font-size: 12px; color: #7d848d; }
    #vc_err {
      position: absolute; inset: 0; z-index: 20; display: none;
      flex-direction: column; align-items: center; justify-content: center;
      padding: 24px; box-sizing: border-box; background: #1f2226; color: #e6e8eb; text-align: center;
      font: 14px "HarmonyOS Sans SC", -apple-system, "Segoe UI", system-ui, sans-serif;
    }
    #vc_err.vc-show { display: flex; }
    #vc_err h2 { font-size: 17px; font-weight: 600; margin: 0 0 8px; }
    #vc_err p { font-size: 13px; color: #9aa0a6; margin: 0 0 14px; max-width: 520px; line-height: 1.6; }
    #vc_err pre {
      max-width: 90%; max-height: 34%; overflow: auto; margin: 0 0 18px;
      padding: 12px 14px; border-radius: 10px; background: #2a2e34; color: #b9bfc7;
      font-size: 12px; text-align: left; white-space: pre-wrap; word-break: break-all;
    }
    #vc_err button {
      padding: 9px 26px; border-radius: 20px; cursor: pointer;
      border: 1px solid #4c8dff; background: rgba(76, 141, 255, .12); color: #8ab4ff; font-size: 14px;
    }
  </style>
</head>
<body>
  <canvas id="vectorcraft_canvas" tabindex="0"></canvas>
  <div id="vectorcraft_loading">Loading VectorCraft&hellip;</div>

  <div id="vc_splash">
    <div class="vc-logo">
      <svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M4 19.5C4 19.5 7 20 9.5 16.5L16 8.5C17.5 6.5 20 7 20 7" stroke="#fff" stroke-width="1.9" stroke-linecap="round"/>
        <rect x="2.4" y="17.9" width="3.4" height="3.4" rx="0.9" fill="#fff"/>
        <rect x="18.3" y="5.6" width="3.4" height="3.4" rx="0.9" fill="#fff"/>
      </svg>
    </div>
    <div id="vc_splash_text">正在启动矢量工坊…</div>
    <div id="vc_bar"><i id="vc_bar_fill"></i></div>
    <div id="vc_tip">首次启动需编译约 62&nbsp;MB 矢量引擎，请稍候</div>
  </div>

  <div id="vc_err">
    <h2>矢量引擎启动失败</h2>
    <p id="vc_err_msg">编辑引擎未能初始化，请点击下方按钮重试。若问题持续存在，可在外壳中切换渲染后端。</p>
    <pre id="vc_err_detail"></pre>
    <button onclick="location.reload()">重新加载</button>
  </div>

  <script>
  (function () {
    'use strict';

    // 引擎胶水层有两个版本：
    //   * .classic.js —— 由 ESM 等价转换而来的经典脚本版（默认走这条，兼容性最好）
    //   * .js         —— 上游原始 ESM（仅在经典脚本通道失败时回退尝试）
    var JS_CLASSIC_URL = './__JS_CLASSIC__';
    var JS_MODULE_URL = './__JS_MODULE__';
    var WASM_URL = './__WASM__';
    var CHUNK_SIZE = 1 << 20; // 1 MiB

    var splash = document.getElementById('vc_splash');
    var splashText = document.getElementById('vc_splash_text');
    var barFill = document.getElementById('vc_bar_fill');
    var errBox = document.getElementById('vc_err');
    var errMsg = document.getElementById('vc_err_msg');
    var errDetail = document.getElementById('vc_err_detail');

    function bridge() {
      try { return window.vcBridge || null; } catch (e) { return null; }
    }

    function report(state, message) {
      try {
        var b = bridge();
        if (b && typeof b.reportState === 'function') {
          b.reportState(String(state), String(message || ''));
        }
      } catch (e) { /* ignore */ }
    }

    // 页面日志：同时进 DevEco 的 hilog（经原生桥）和 Web 控制台，方便定位卡在哪一步
    function plog(message) {
      try { console.info('[VectorCraft] ' + message); } catch (e) { /* ignore */ }
      try {
        var b = bridge();
        if (b && typeof b.log === 'function') { b.log(String(message)); }
      } catch (e) { /* ignore */ }
    }

    // 引擎（Rust/wgpu）的日志只写到 Web 控制台，真机上不方便看。把其中几条关键的
    // —— 实际渲染后端、panic/设备丢失 —— 一并转给原生侧写进 hilog，
    // 这样在 DevEco 的 Log 面板搜 [VectorCraft] 就能确认跑的是 WebGPU 还是 WebGL2。
    (function () {
      var key = /wgpu backend|panicked|device lost|Uncaught|Failed to|vectorcraft-web/i;
      ['info', 'warn', 'error'].forEach(function (level) {
        var orig = console[level];
        if (typeof orig !== 'function') { return; }
        console[level] = function () {
          try {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              var a = arguments[i];
              parts.push(typeof a === 'string' ? a : (a && a.message) ? String(a.message) : String(a));
            }
            var line = parts.join(' ');
            if (key.test(line) && line.indexOf('[VectorCraft]') !== 0) {
              plog('引擎: ' + line);
            }
          } catch (e) { /* ignore */ }
          return orig.apply(console, arguments);
        };
      });
    })();

    // ------------------------------------------------------------------
    // 保存 / 导出 接管
    //
    // 引擎的「保存」「另存为」「导出」最后都是同一个动作：把字节打成 Blob，
    // 造一个隐藏的 <a download> 然后 click()。桌面浏览器会弹下载，鸿蒙的
    // Web 组件不会 —— 点了没反应、也不知道存到哪去了。这里把那次 click 拦下来，
    // 把字节分块交给原生，由系统文件选择器写到用户自己选的目录。
    // ------------------------------------------------------------------
    var SAVE_CHUNK = 256 * 1024; // 每块 256 KiB，base64 后约 350 KB
    var vcBlobs = {};            // blob: URL -> Blob

    (function hookObjectUrl() {
      try {
        var origCreate = URL.createObjectURL.bind(URL);
        URL.createObjectURL = function (obj) {
          var u = origCreate(obj);
          try {
            if (obj && typeof Blob !== 'undefined' && obj instanceof Blob) { vcBlobs[u] = obj; }
          } catch (e) { /* ignore */ }
          return u;
        };
        var origRevoke = URL.revokeObjectURL.bind(URL);
        URL.revokeObjectURL = function (u) {
          try { delete vcBlobs[u]; } catch (e) { /* ignore */ }
          return origRevoke(u);
        };
      } catch (e) { /* ignore */ }
    })();

    function vcToBase64(bytes) {
      var out = '';
      var step = 8192;
      for (var i = 0; i < bytes.length; i += step) {
        out += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + step, bytes.length)));
      }
      try { return btoa(out); } catch (e) { return ''; }
    }

    function vcSendBytes(handle, bytes) {
      var ok = true;
      try {
        for (var off = 0; off < bytes.length; off += SAVE_CHUNK) {
          var b64 = vcToBase64(bytes.subarray(off, Math.min(off + SAVE_CHUNK, bytes.length)));
          if (!b64 || handle.saveChunk(b64) !== true) { ok = false; break; }
        }
      } catch (e) {
        ok = false;
        plog('保存分块传输异常: ' + e);
      }
      try { handle.finishSave(ok ? bytes.length : -1); } catch (e) { /* ignore */ }
    }

    /** 把一次下载交给宿主。返回 true 表示已接管（不要再走浏览器下载）。 */
    function vcHostSave(name, blob, url) {
      var b = bridge();
      if (!b || typeof b.beginSave !== 'function' || typeof b.saveChunk !== 'function' ||
          typeof b.finishSave !== 'function') {
        return false;
      }
      if (!name) { name = 'vectorcraft-export'; }
      var started = false;
      try {
        started = b.beginSave(String(name), (blob && blob.type) ? String(blob.type) : '',
          (blob && blob.size) ? blob.size : 0) === true;
      } catch (e) {
        plog('beginSave 失败: ' + e);
      }
      if (!started) { return false; }
      plog('导出交给宿主: ' + name);

      if (blob && typeof blob.arrayBuffer === 'function') {
        blob.arrayBuffer().then(function (buf) {
          vcSendBytes(b, new Uint8Array(buf));
        }).catch(function (e) {
          plog('读取导出数据失败: ' + e);
          try { b.finishSave(-1); } catch (e2) { /* ignore */ }
        });
        return true;
      }
      if (url) {
        fetch(url).then(function (res) { return res.arrayBuffer(); }).then(function (buf) {
          vcSendBytes(b, new Uint8Array(buf));
        }).catch(function (e) {
          plog('读取导出数据失败: ' + e);
          try { b.finishSave(-1); } catch (e2) { /* ignore */ }
        });
        return true;
      }
      try { b.finishSave(-1); } catch (e) { /* ignore */ }
      return true;
    }

    (function hookAnchorClick() {
      var orig = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        try {
          var dl = this.getAttribute('download');
          var href = this.href || '';
          if (dl !== null && href.indexOf('blob:') === 0) {
            var blob = vcBlobs[href] || null;
            if (vcHostSave(dl, blob, href)) { return; }
          }
        } catch (e) {
          plog('拦截下载失败: ' + e);
        }
        return orig.apply(this, arguments);
      };
    })();

    // ------------------------------------------------------------------
    // 外部链接
    //
    // 引擎里的「在 GitHub 上查看」这类外链，在 Web 里是 window.open / <a target=_blank>。
    // 在 Web 组件内打开会把编辑器页面整个顶掉，而引擎没有返回键 —— 只能杀掉应用重开。
    // 这里全部拦下来交给系统浏览器，编辑器页面保持不动。
    // ------------------------------------------------------------------

    function vcOpenExternal(url) {
      var u = String(url || '');
      if (!u) { return false; }
      plog('外部链接交给系统浏览器: ' + u);
      try {
        var b = bridge();
        if (b && typeof b.openUrl === 'function' && b.openUrl(u) === true) { return true; }
      } catch (e) {
        plog('openUrl 失败: ' + e);
      }
      // 宿主没接住也绝不让它把编辑器顶掉：宁可什么都不发生。
      return true;
    }

    (function hookWindowOpen() {
      var orig = window.open;
      window.open = function (url, target, features) {
        var u = String((url === null || url === undefined) ? '' : url);
        if (!u) { return null; }
        vcOpenExternal(u);
        return null;
      };
    })();

    document.addEventListener('click', function (e) {
      try {
        var t = e.target;
        while (t && t !== document && (!t.tagName || t.tagName !== 'A')) {
          t = t.parentElement || t.parentNode;
        }
        if (!t || !t.tagName || t.tagName !== 'A') { return; }
        if (t.hasAttribute('download')) { return; }
        var abs = t.href || '';
        // 只拦真正会跳出编辑器的 http(s) 链接，同页面锚点/相对路径/其它协议一律放行
        if (!/^https?:/i.test(abs)) { return; }
        e.preventDefault();
        e.stopPropagation();
        vcOpenExternal(abs);
      } catch (err) { /* ignore */ }
    }, true);

    function setProgress(ratio, text) {
      if (typeof ratio === 'number' && isFinite(ratio)) {
        var p = Math.max(0, Math.min(1, ratio));
        barFill.style.width = (p * 100).toFixed(1) + '%';
      }
      if (text) { splashText.textContent = text; }
    }

    // ------------------------------------------------------------------
    // 宿主配置：渲染后端与界面语言
    //
    // 引擎在 Rust 侧读取 location.search（?webgl / ?lang=），但 resource:// 页面
    // 无法改写自己的查询串，因此由宿主经桥接下发，页面在初始化前写成 window 全局变量，
    // 引擎（已打补丁）启动时会读取它们。
    // ------------------------------------------------------------------
    function applyHostConfig() {
      var b = bridge();
      var mode = 'auto';
      var lang = 'zh-hans';
      try {
        if (b && typeof b.renderMode === 'function') {
          var m = b.renderMode();
          if (m) { mode = String(m); }
        }
        if (b && typeof b.lang === 'function') {
          var l = b.lang();
          if (l && l !== 'auto') { lang = String(l); }
        }
      } catch (e) { /* ignore */ }
      window.__VC_RENDER_MODE = mode;
      if (mode === 'webgl') {
        window.__VC_WEBGL = '1';
        plog('宿主指定 WebGL2 后端');
      }
      if (lang && lang !== 'auto') {
        window.__VC_LANG = lang;
        plog('宿主指定界面语言: ' + lang);
      }
      return mode;
    }

    function fail(message, err) {
      var detail = '';
      if (err) {
        detail = (err && err.stack) ? String(err.stack) : String(err);
      }
      report('error', message + (detail ? ' | ' + detail : ''));
      splash.classList.add('vc-hidden');
      errMsg.textContent = message;
      errDetail.textContent = detail || '（无详细信息）';
      errBox.classList.add('vc-show');
      console.error('[VectorCraft] ' + message, err);
    }

    function fetchBytes(url, onProgress) {
      return fetch(url).then(function (res) {
        if (!res.ok) { throw new Error('HTTP ' + res.status + ' for ' + url); }
        var total = Number(res.headers.get('content-length') || 0);
        if (!res.body || typeof res.body.getReader !== 'function') {
          return res.arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
        }
        var reader = res.body.getReader();
        var parts = [];
        var got = 0;
        return (function pump() {
          return reader.read().then(function (r) {
            if (r.done) {
              var out = new Uint8Array(got);
              var off = 0;
              for (var i = 0; i < parts.length; i++) { out.set(parts[i], off); off += parts[i].length; }
              return out;
            }
            parts.push(r.value);
            got += r.value.length;
            if (onProgress) { onProgress(total ? got / total : 0, got); }
            return pump();
          });
        })();
      });
    }

    function xhrBytes(url) {
      return new Promise(function (resolve, reject) {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', url, true);
        xhr.responseType = 'arraybuffer';
        xhr.onload = function () {
          if (xhr.status === 0 || (xhr.status >= 200 && xhr.status < 300)) {
            if (!xhr.response) { reject(new Error('empty response')); return; }
            resolve(new Uint8Array(xhr.response));
          } else {
            reject(new Error('XHR status ' + xhr.status));
          }
        };
        xhr.onerror = function () { reject(new Error('XHR network error')); };
        xhr.send();
      });
    }

    // 通过鸿蒙原桥分块读取 rawfile（前两条路径都不可用时的兜底）
    function bridgeBytes(url, onProgress) {
      var b = bridge();
      if (!b || typeof b.assetSize !== 'function' || typeof b.assetChunk !== 'function') {
        return Promise.reject(new Error('原生资源通道不可用'));
      }
      var size = Number(b.assetSize(url));
      if (!size || size <= 0) {
        return Promise.reject(new Error('未找到资源: ' + url));
      }
      var out = new Uint8Array(size);
      var offset = 0;
      return new Promise(function (resolve, reject) {
        (function step() {
          try {
            var guard = 0;
            while (offset < size && guard < 64) {
              var len = Math.min(CHUNK_SIZE, size - offset);
              var b64 = b.assetChunk(url, offset, len);
              if (!b64) { throw new Error('分块读取返回空'); }
              var bin = atob(b64);
              for (var i = 0; i < bin.length; i++) { out[offset + i] = bin.charCodeAt(i); }
              offset += bin.length;
              guard++;
            }
            if (onProgress) { onProgress(offset / size, offset); }
            if (offset < size) { setTimeout(step, 0); return; }
            resolve(out);
          } catch (e) {
            reject(e);
          }
        })();
      });
    }

    function loadBytes(url, onProgress) {
      return fetchBytes(url, onProgress).catch(function (e) {
        plog('fetch 失败(' + e + ')，尝试 XHR: ' + url);
        return xhrBytes(url);
      }).catch(function (e) {
        plog('XHR 失败(' + e + ')，尝试原生资源通道: ' + url);
        return bridgeBytes(url, onProgress);
      });
    }

    function textFromBytes(bytes) {
      try {
        return new TextDecoder('utf-8').decode(bytes);
      } catch (e) {
        var s = '';
        for (var i = 0; i < bytes.length; i += 8192) {
          s += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + 8192, bytes.length)));
        }
        return s;
      }
    }

    // 读取文本资源：fetch 直接取文本 → 否则走字节通道再解码
    function loadText(url) {
      return fetch(url).then(function (res) {
        if (!res.ok) { throw new Error('HTTP ' + res.status + ' for ' + url); }
        return res.text();
      }).catch(function (e) {
        plog('fetch 文本失败(' + e + ')，改用字节通道: ' + url);
        return loadBytes(url).then(textFromBytes);
      });
    }

    // 以经典脚本方式注入：不经过 ES Module 加载器，因此不受 resource:// 协议限制
    function injectClassicScript(text) {
      var el = document.createElement('script');
      el.type = 'text/javascript';
      el.textContent = text;
      (document.head || document.documentElement).appendChild(el);
      try { el.parentNode.removeChild(el); } catch (e) { /* ignore */ }
      return window.__VectorCraftModule || null;
    }

    // 加载引擎模块：经典脚本通道优先，失败再回退到上游 ESM
    function loadEngineModule() {
      report('loading', 'js');
      return loadText(JS_CLASSIC_URL).then(function (text) {
        var mod = injectClassicScript(text);
        if (!mod || typeof mod.default !== 'function') {
          throw new Error('经典脚本注入后未导出初始化函数');
        }
        plog('引擎胶水层：经典脚本通道 OK（' + text.length + ' 字符）');
        return mod;
      }).catch(function (e) {
        plog('经典脚本通道失败(' + e + ')，回退上游 ESM');
        return import(JS_MODULE_URL).then(function (mod) {
          plog('引擎胶水层：ESM 通道 OK');
          return mod;
        });
      });
    }

    // ---- 宿主「最近文件」：把字节还原成 File，合成一次 drop 交给引擎 ----
    // 引擎（eframe）的 drop 监听只读 dataTransfer.files，不校验 isTrusted，
    // 所以宿主可以先分块把副本字节推过来，再派发一个合成事件，等价于用户把文件拖进画布。
    var vcOpenParts = [];
    var vcOpenName = 'document';

    function vcB64Bytes(b64) {
      var bin = atob(b64);
      var out = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) {
        out[i] = bin.charCodeAt(i) & 255;
      }
      return out;
    }

    window.__vcOpenFileBegin = function (name, size) {
      vcOpenParts = [];
      vcOpenName = name || 'document';
      plog('宿主打开最近文件：' + vcOpenName + '（' + size + ' 字节）');
      return true;
    };

    window.__vcOpenFileChunk = function (b64) {
      try {
        vcOpenParts.push(vcB64Bytes(b64));
        return true;
      } catch (e) {
        plog('最近文件分块解码失败: ' + e);
        return false;
      }
    };

    window.__vcOpenFileEnd = function () {
      var canvas = document.getElementById('vectorcraft_canvas');
      if (!canvas) {
        plog('找不到画布，无法打开最近文件');
        return false;
      }
      var size = 0;
      for (var i = 0; i < vcOpenParts.length; i++) {
        size += vcOpenParts[i].length;
      }
      if (size === 0) {
        plog('最近文件内容为空');
        return false;
      }
      var file = null;
      try {
        file = new File(vcOpenParts, vcOpenName, { type: 'application/octet-stream' });
      } catch (e) {
        plog('构造 File 失败: ' + e);
        return false;
      }
      vcOpenParts = [];
      var dt = null;
      try {
        dt = new DataTransfer();
        dt.items.add(file);
      } catch (e) {
        plog('DataTransfer 不可用: ' + e);
        return false;
      }
      var rect = canvas.getBoundingClientRect();
      var ev = null;
      try {
        ev = new DragEvent('drop', {
          bubbles: true,
          cancelable: true,
          dataTransfer: dt,
          clientX: rect.left + rect.width / 2,
          clientY: rect.top + rect.height / 2
        });
      } catch (e) {
        ev = new Event('drop', { bubbles: true, cancelable: true });
        try {
          Object.defineProperty(ev, 'dataTransfer', { value: dt });
        } catch (e2) {
          plog('无法构造 drop 事件: ' + e2);
          return false;
        }
      }
      try {
        canvas.dispatchEvent(ev);
      } catch (e) {
        plog('派发 drop 失败: ' + e);
        return false;
      }
      plog('已交给引擎打开：' + vcOpenName + '（' + size + ' 字节）');
      return true;
    };

    function start() {
      setProgress(0.02, '正在加载编辑引擎…');
      var mode = applyHostConfig();
      plog('engine boot, renderMode=' + mode + ', ua=' + navigator.userAgent);
      loadEngineModule().then(function (mod) {
        setProgress(0.16, '正在读取矢量引擎（约 62 MB）…');
        report('loading', 'wasm');
        return loadBytes(WASM_URL, function (p, got) {
          setProgress(0.16 + p * 0.68, '正在读取矢量引擎 ' + (got / 1048576).toFixed(1) + ' MB');
        }).then(function (bytes) {
          plog('wasm 已读取 ' + bytes.length + ' 字节，开始编译');
          setProgress(0.88, '正在编译并初始化…');
          report('loading', 'compile');
          // 直接把字节交给胶水层，避免它自己去 fetch resource:// 下的 wasm
          return mod.default({ module_or_path: bytes }).then(function (wasm) {
            window.wasmBindings = mod;
            try {
              dispatchEvent(new CustomEvent('TrunkApplicationStarted', { detail: { wasm: wasm } }));
            } catch (e) { /* ignore */ }
            setProgress(1, '就绪');
            splash.classList.add('vc-hidden');
            plog('引擎初始化完成');
            report('ready', mode);
            setTimeout(function () {
              var c = document.getElementById('vectorcraft_canvas');
              if (c && typeof c.focus === 'function') { try { c.focus(); } catch (e) { /* ignore */ } }
            }, 240);
          });
        });
      }).catch(function (e) {
        fail('编辑引擎未能初始化：' + ((e && e.message) ? e.message : e), e);
      });
    }

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', start);
    } else {
      start();
    }
  })();
  </script>
</body>
</html>
"""

# ------------------------------------------------------------------
# ESM -> 经典脚本 等价转换（与上游 tools/build_engine_zh/gen_classic_glue.py 同规则）
# ------------------------------------------------------------------

EXPORT_RE = re.compile(r"^export\s*\{[^}]*__wbg_init\s+as\s+default[^}]*\}\s*;?\s*$", re.M)
WASM_URL_RE = re.compile(r"new URL\((\s*'[^']*_bg\.wasm'\s*),\s*import\.meta\.url\s*\)")

CONVERT_HEADER = """/*
 * 本文件由 VectorCraft 的 wasm-bindgen ESM 胶水层自动转换而来（tools/pack_web.py），
 * 仅做「ESM -> 经典脚本」的等价改写，未改动任何引擎逻辑：
 *   1. export { initSync, __wbg_init as default } -> window.__VectorCraftModule
 *   2. new URL('..._bg.wasm', import.meta.url)      -> new URL('..._bg.wasm', document.baseURI)
 *   3. 外层包裹 IIFE + 'use strict'（等价于 ESM 的模块作用域与严格模式）
 * 原因：鸿蒙 ArkWeb 的 ES Module 加载器不支持 resource:// 协议。
 * 上游原始文件 {src_name} 保持原样未改动。
 */
"""


def convert_glue(src: Path) -> str:
    text = src.read_text(encoding="utf-8")
    if "import.meta.url" not in text:
        raise SystemExit(f"{src}: 没找到 import.meta.url，可能不是 wasm-bindgen 的 ESM 胶水层")

    text, n_url = WASM_URL_RE.subn(
        lambda m: f"new URL({m.group(1)}, (typeof document !== 'undefined' && document.baseURI) "
        "? document.baseURI : 'resource://rawfile/vectorcraft/')",
        text,
    )
    if n_url == 0:
        raise SystemExit(f"{src}: 没找到 new URL('..._bg.wasm', import.meta.url)")

    text, n_export = EXPORT_RE.subn(
        "window.__VectorCraftModule = { initSync: initSync, default: __wbg_init };", text
    )
    if n_export == 0:
        raise SystemExit(f"{src}: 没找到 export {{ ... __wbg_init as default }}")

    leftover = re.findall(r"^\s*(?:import|export)\s", text, re.M)
    if leftover:
        raise SystemExit(f"{src}: 还有 {len(leftover)} 条 import/export 语句未处理")

    head = CONVERT_HEADER.replace("{src_name}", src.name)
    return head + "(function () {\n'use strict';\n\n" + text.rstrip() + "\n\n})();\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", default="D:/vc-build/vectorcraft-src/dist/web", help="trunk 构建输出目录")
    ap.add_argument("--out", default=str(PROJECT / "entry/src/main/resources/rawfile/vectorcraft"), help="rawfile 输出目录")
    args = ap.parse_args()

    dist = Path(args.dist)
    out = Path(args.out)
    if not dist.is_dir():
        raise SystemExit(f"dist 目录不存在: {dist}")

    js_files = sorted(p for p in dist.glob("*.js") if not p.name.endswith(".classic.js"))
    wasm_files = sorted(dist.glob("*_bg.wasm"))
    if not js_files or not wasm_files:
        raise SystemExit(f"dist 里没找到胶水层 / wasm: {[p.name for p in dist.iterdir()]}")

    js_src = js_files[0]
    wasm_src = wasm_files[0]
    classic_name = js_src.stem + ".classic.js"

    out.mkdir(parents=True, exist_ok=True)
    # 清掉旧产物，避免残留上一个 hash 的文件
    for old in out.iterdir():
        if old.is_file():
            old.unlink()

    shutil.copy2(wasm_src, out / wasm_src.name)
    shutil.copy2(js_src, out / js_src.name)
    (out / classic_name).write_text(convert_glue(js_src), encoding="utf-8")

    html = INDEX_TEMPLATE
    html = html.replace("__JS_CLASSIC__", classic_name)
    html = html.replace("__JS_MODULE__", js_src.name)
    html = html.replace("__WASM__", wasm_src.name)
    (out / "index.html").write_text(html, encoding="utf-8")

    print("打包完成 ->", out)
    for p in sorted(out.iterdir()):
        print(f"  {p.stat().st_size / 1048576:10.3f} MB  {p.name}")

    # 语法自检：确认经典脚本是合法 JS（有 node 时）
    node = shutil.which("node")
    if node:
        r = subprocess.run([node, "--check", str(out / classic_name)], capture_output=True, text=True)
        print("node --check classic js:", "OK" if r.returncode == 0 else "FAILED")
        if r.returncode != 0:
            print(r.stderr[:2000])
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
