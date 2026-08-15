/* QiCompass promo-site AI 配置管理
 *
 * 用户决策(2026-08-13;同日晚改为显式保存):
 * 1. 网页填 provider + api_key(必填)+ base_url/model(可选)
 * 2. localStorage 存储,但页面加载时不自动恢复(留空)
 * 3. 显式「💾 保存配置」按钮存 localStorage(输入过程不自动存)
 * 4. 「🔄 自动填上次配置」按钮 → 一键恢复
 * 5. 「🔌 测试连接」按钮 → POST /ai/test(max_tokens=1 ping)
 * 6. 保留环境变量 fallback(不填 → 后端用 env key)
 */

const STORAGE_KEY = 'promo_ai_config';

function loadConfig() {
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        return raw ? JSON.parse(raw) : null;
    } catch (e) {
        console.warn('[promo] loadConfig failed:', e);
        return null;
    }
}

function saveConfig(config) {
    try {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
    } catch (e) {
        console.warn('[promo] saveConfig failed:', e);
    }
}

function getCurrentConfigFromForm() {
    const provider = document.querySelector('[data-ai-provider] input:checked')?.value || 'anthropic';
    const apiKey = document.querySelector('[data-ai-key]')?.value || '';
    const baseUrl = document.querySelector('[data-ai-base-url]')?.value || '';
    const model = document.querySelector('[data-ai-model]')?.value || '';
    return { provider, apiKey, baseUrl, model };
}

function applyConfigToForm(config) {
    if (!config) return false;
    if (config.provider) {
        const radio = document.querySelector(`[data-ai-provider] input[value="${config.provider}"]`);
        if (radio) radio.checked = true;
    }
    if (config.apiKey !== undefined) {
        const keyInput = document.querySelector('[data-ai-key]');
        if (keyInput) keyInput.value = config.apiKey;
    }
    if (config.baseUrl !== undefined) {
        const urlInput = document.querySelector('[data-ai-base-url]');
        if (urlInput) urlInput.value = config.baseUrl;
    }
    if (config.model !== undefined) {
        const modelInput = document.querySelector('[data-ai-model]');
        if (modelInput) modelInput.value = config.model;
    }
    return true;
}

document.addEventListener('DOMContentLoaded', () => {
    // ---------- 折叠 AI 配置区 ----------
    const toggleBtn = document.querySelector('[data-action="toggle-ai-config"]');
    const body = document.querySelector('[data-ai-config-body]');
    if (toggleBtn && body) {
        toggleBtn.addEventListener('click', () => {
            const isOpen = body.style.display !== 'none';
            body.style.display = isOpen ? 'none' : '';
            toggleBtn.setAttribute('aria-expanded', String(!isOpen));
            toggleBtn.textContent = isOpen
                ? '⚙ AI 配置(可选 — 不填走环境变量)'
                : '▼ AI 配置(已展开)';
        });
    }

    // ---------- 自动填上次配置 ----------
    const restoreBtn = document.querySelector('[data-action="restore-last-config"]');
    if (restoreBtn) {
        const hasSaved = !!loadConfig();
        if (!hasSaved) {
            restoreBtn.disabled = true;
            restoreBtn.title = '暂无保存的配置(填一次后此按钮可用)';
        }
        restoreBtn.addEventListener('click', () => {
            const config = loadConfig();
            if (!config) {
                alert('暂无保存的配置');
                return;
            }
            // 自动展开配置区(如果折叠了)
            if (body && body.style.display === 'none' && toggleBtn) {
                toggleBtn.click();
            }
            applyConfigToForm(config);
            // 高亮提示
            restoreBtn.textContent = '✓ 已恢复';
            setTimeout(() => {
                restoreBtn.textContent = '🔄 自动填上次配置';
            }, 1500);
        });
    }

    // ---------- key 显示/隐藏 ----------
    const keyToggle = document.querySelector('[data-action="toggle-key-visibility"]');
    const keyInput = document.querySelector('[data-ai-key]');
    if (keyToggle && keyInput) {
        keyToggle.addEventListener('click', () => {
            keyInput.type = keyInput.type === 'password' ? 'text' : 'password';
            keyToggle.textContent = keyInput.type === 'password' ? '👁' : '🙈';
        });
    }

    // ---------- 状态区(保存/测试结果反馈) ----------
    const statusEl = document.querySelector('[data-ai-status]');
    const TEST_TIMEOUT_MS = 60000;  // 对齐后端 /ai/test 探针超时(15s 连接 + 生成余量)

    function showStatus(kind, text) {
        if (!statusEl) return;
        statusEl.hidden = false;
        statusEl.classList.remove('ai-config__status--ok', 'ai-config__status--error');
        statusEl.classList.add(`ai-config__status--${kind}`);
        statusEl.textContent = text;
    }

    function clearStatus() {
        if (!statusEl) return;
        statusEl.hidden = true;
        statusEl.textContent = '';
    }

    // ---------- 保存配置(显式保存,输入过程不自动存) ----------
    const saveBtn = document.querySelector('[data-action="save-ai-config"]');
    if (saveBtn) {
        saveBtn.addEventListener('click', () => {
            const config = getCurrentConfigFromForm();
            // 只有真的填了东西才存(避免空配置覆盖已有保存)
            if (!(config.apiKey || config.baseUrl || config.model || config.provider !== 'anthropic')) {
                showStatus('error', '✗ 没有可保存的内容(至少填一项)');
                return;
            }
            saveConfig(config);
            if (restoreBtn) restoreBtn.disabled = false;
            saveBtn.textContent = '✓ 已保存';
            showStatus('ok', '✓ 已保存到本机(localStorage),下次点「自动填上次配置」恢复');
            setTimeout(() => { saveBtn.textContent = '💾 保存配置'; }, 1500);
        });
    }

    // ---------- 测试连接(POST /ai/test,max_tokens=1 ping) ----------
    const testBtn = document.querySelector('[data-action="test-ai-config"]');
    if (testBtn) {
        testBtn.addEventListener('click', async () => {
            const config = getCurrentConfigFromForm();
            const body = new URLSearchParams({
                ai_provider: config.provider,
                ai_api_key: config.apiKey,
                ai_base_url: config.baseUrl,
                ai_model: config.model,
            });
            testBtn.disabled = true;
            const originalText = testBtn.textContent;
            testBtn.textContent = '⏳ 测试中…';
            showStatus('ok', '⏳ 正在向 LLM endpoint 发送 max_tokens=1 探针请求(最多等 60 秒)…');
            try {
                const resp = await fetch('/ai/test', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: body.toString(),
                });
                const result = await resp.json().catch(() => ({}));
                if (result.ok) {
                    const keyFrom = result.key_source === 'env' ? '环境变量' : '表单';
                    showStatus('ok',
                        `✓ 连接成功 · ${result.provider} / ${result.model}` +
                        ` · 耗时 ${result.latency_ms}ms · key 来源:${keyFrom}`);
                } else {
                    showStatus('error', `✗ 测试失败 · ${result.error || `HTTP ${resp.status}`}`);
                }
            } catch (e) {
                showStatus('error', `✗ 测试请求发不出去(promo-site 没在运行?): ${e}`);
            } finally {
                testBtn.disabled = false;
                testBtn.textContent = originalText;
            }
        });
    }

    // 字段变化时清掉过期状态(上次保存/测试的结果不再可信)
    const fields = document.querySelectorAll('[data-ai-key], [data-ai-base-url], [data-ai-model], [data-ai-provider] input');
    fields.forEach(field => {
        field.addEventListener('input', clearStatus);
        field.addEventListener('change', clearStatus);
    });
});
