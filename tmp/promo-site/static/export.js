/* QiCompass promo-site 截图工具
 *
 * 功能:
 * 1. toggleCaptureMode() — 切换"截图模式"(隐藏 nav/footer + 锁宽 1080 + 显示水印/引导)
 * 2. exportPNG(module)   — html2canvas 截图 .capture-target,自动下载 PNG
 *
 * 依赖:html2canvas 1.4.1 本地 vendor(static/vendor/,2026-08-13 去 CDN 化——
 *      jsdelivr 在国内不稳,截图工具不能依赖外网)
 * 字体:截图前预先 document.fonts.ready(Songti SC 进入 canvas)
 */

const HTML2CANVAS_SRC = '/static/vendor/html2canvas.min.js';

// ---------- 动态加载 html2canvas(带缓存) ----------
async function ensureHtml2Canvas() {
    if (window.html2canvas) return window.html2canvas;
    if (window.__html2canvasLoading) {
        // 已有并发加载,等它完成
        await window.__html2canvasLoading;
        return window.html2canvas;
    }
    window.__html2canvasLoading = new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = HTML2CANVAS_SRC;
        script.onload = () => {
            if (!window.html2canvas) {
                reject(new Error('html2canvas 加载成功但全局对象未挂载'));
                return;
            }
            resolve(window.html2canvas);
        };
        script.onerror = () => reject(new Error(`html2canvas 本地文件加载失败(${HTML2CANVAS_SRC},检查 static/vendor/ 是否存在)`));
        document.head.appendChild(script);
    });
    return window.__html2canvasLoading;
}

// ---------- 切换截图模式 ----------
function toggleCaptureMode() {
    document.body.classList.toggle('capture-mode');
    const isOn = document.body.classList.contains('capture-mode');
    const btn = document.querySelector('[data-action="toggle-capture"]');
    if (btn) {
        btn.textContent = isOn ? '退出截图模式' : '切换截图模式';
        btn.classList.toggle('btn--primary', !isOn);
        btn.classList.toggle('btn--secondary', isOn);
    }
    // 截图模式下,把工具栏改 sticky 顶部,方便点导出
    const toolbar = document.querySelector('.export-toolbar');
    if (toolbar) {
        toolbar.classList.toggle('export-toolbar--floating', isOn);
    }
    return isOn;
}

// ---------- 导出 PNG ----------
async function exportPNG(module) {
    const target = document.querySelector('.capture-target');
    if (!target) {
        alert('未找到 .capture-target 元素,无法截图');
        return;
    }
    // 自动切到截图模式(若用户没切)
    if (!document.body.classList.contains('capture-mode')) {
        toggleCaptureMode();
        // 等 DOM 重排稳定
        await new Promise(r => setTimeout(r, 100));
    }

    const btn = document.querySelector('[data-action="export-png"]');
    const originalText = btn ? btn.textContent : '';
    if (btn) {
        btn.textContent = '生成中...';
        btn.disabled = true;
    }

    try {
        const html2canvas = await ensureHtml2Canvas();
        // 等字体加载完(关键:Songti SC 渲染到 canvas)
        if (document.fonts && document.fonts.ready) {
            await document.fonts.ready;
        }

        const canvas = await html2canvas(target, {
            scale: 2,                          // 高分屏,清晰
            backgroundColor: '#FDFCFA',         // DESIGN.md paper
            useCORS: true,
            logging: false,
            windowWidth: 1080,                  // 锁宽 1080(Reddit 友好)
        });

        // 文件命名:qicompass_<module>_<timestamp>.png
        const ts = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);
        const filename = `qicompass_${module}_${ts}.png`;

        // 触发下载
        canvas.toBlob((blob) => {
            if (!blob) {
                alert('canvas.toBlob 失败(浏览器兼容性问题?)');
                return;
            }
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = filename;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            // 不立即 revoke:状态区保留"查看/另存"链接(60s 后回收)
            showExportStatus(filename, blob.size, url);
            setTimeout(() => URL.revokeObjectURL(url), 60000);
        }, 'image/png');

        console.info('[promo] PNG exported:', filename);
    } catch (err) {
        console.error('[promo] exportPNG failed:', err);
        showExportError(err.message);
        alert('截图失败:' + err.message + '\n(详情见工具栏下方状态提示 / 浏览器控制台)');
    } finally {
        if (btn) {
            btn.textContent = originalText;
            btn.disabled = false;
        }
    }
}

// ---------- 导出状态反馈(成功/失败都在工具栏下方显示) ----------

function _setStatus(kind, html) {
    const el = document.querySelector('[data-export-status]');
    if (!el) return;
    el.hidden = false;
    el.classList.remove('export-status--ok', 'export-status--error');
    el.classList.add(`export-status--${kind}`);
    el.innerHTML = html;
}

function showExportStatus(filename, sizeBytes, url) {
    const sizeMb = (sizeBytes / 1024 / 1024).toFixed(2);
    _setStatus('ok',
        `✓ 已导出 <strong>${filename}</strong>(${sizeMb}MB)到浏览器下载目录。` +
        `没看到下载?` +
        `<a href="${url}" download="${filename}" target="_blank" rel="noopener">点这里查看 / 另存</a>`);
}

function showExportError(message) {
    _setStatus('error', `✗ 导出失败:${message}`);
}

// ---------- 绑定事件(页面加载完) ----------
document.addEventListener('DOMContentLoaded', () => {
    const toggleBtn = document.querySelector('[data-action="toggle-capture"]');
    if (toggleBtn) {
        toggleBtn.addEventListener('click', (e) => {
            e.preventDefault();
            toggleCaptureMode();
        });
    }
    // export 按钮 data-module 属性携带模块名(bazi/compat/daily)
    document.querySelectorAll('[data-action="export-png"]').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.preventDefault();
            const module = btn.getAttribute('data-module') || 'unknown';
            exportPNG(module);
        });
    });
    // 复制 markdown 按钮
    document.querySelectorAll('[data-action="copy-markdown"]').forEach(btn => {
        btn.addEventListener('click', (e) => {
            e.preventDefault();
            copyMarkdown(btn);
        });
    });
});

// ---------- 复制 markdown 到剪贴板 ----------
async function copyMarkdown(btn) {
    const text = window.__promoMarkdown;
    if (!text) {
        alert('未找到 markdown 内容(可能页面没有 AI 输出)');
        return;
    }
    const originalText = btn.textContent;
    btn.disabled = true;
    try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
            await navigator.clipboard.writeText(text);
        } else {
            // Fallback:用 textarea + execCommand(老浏览器)
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.opacity = '0';
            document.body.appendChild(ta);
            ta.select();
            document.execCommand('copy');
            document.body.removeChild(ta);
        }
        btn.textContent = `✓ 已复制 ${text.length} 字`;
        console.info('[promo] markdown copied:', text.length, 'chars');
        setTimeout(() => { btn.textContent = originalText; }, 2000);
    } catch (err) {
        console.error('[promo] copyMarkdown failed:', err);
        alert('复制失败:' + err.message + '\n(浏览器可能限制了 clipboard API,试试 HTTPS 或 localhost)');
    } finally {
        btn.disabled = false;
    }
}
