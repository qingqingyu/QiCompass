/* QiCompass promo-site 表单交互
 *
 * 对齐 iOS BirthFormView.swift:
 * 1. 12 时辰快捷选(点选时辰 → 填中点时间到 birth_time)
 * 2. 全量城市选择器(2026-08-15):/geo/search 搜 23.5 万聚落(中文/拼音/英文),
 *    选中自动填 longitude + city_tz;tz_offset 按【出生时刻】走 /geo/tz_offset
 *    精确计算(IANA 历史规则,含 1986-1991 中国夏令时——旧的 52 城写死 +8 在
 *    夏令时年份会差 1 小时,时辰可能排错)
 * 3. "手动输入经度" toggle(手动模式 tz 用浏览器本地,语义不变)
 *
 * 字段对齐 iOS:
 * - 出生时间:DatePicker + 时辰快捷选(可选)
 * - 性别:Segmented Picker(男 / 女)
 * - 出生地:全量城市 autocomplete + 手动经度 toggle
 * - 时区:用户不直接填(iOS 也不传),从城市 + 出生时刻自动算
 */

// 12 时辰(对齐 iOS BirthFormView.swift:138 shichenGrid)
const SHICHEN_DATA = [
    { name: "子", hour: 0,  label: "23:00-01:00" },
    { name: "丑", hour: 2,  label: "01:00-03:00" },
    { name: "寅", hour: 4,  label: "03:00-05:00" },
    { name: "卯", hour: 6,  label: "05:00-07:00" },
    { name: "辰", hour: 8,  label: "07:00-09:00" },
    { name: "巳", hour: 10, label: "09:00-11:00" },
    { name: "午", hour: 12, label: "11:00-13:00" },
    { name: "未", hour: 14, label: "13:00-15:00" },
    { name: "申", hour: 16, label: "15:00-17:00" },
    { name: "酉", hour: 18, label: "17:00-19:00" },
    { name: "戌", hour: 20, label: "19:00-21:00" },
    { name: "亥", hour: 22, label: "21:00-23:00" },
];

/**
 * 初始化一个出生表单组(bazi/daily 用空 prefix,compat 用 'a'/'b')。
 * @param {string} prefix - 字段后缀(空串 / 'a' / 'b')
 */
function initBirthForm(prefix = '') {
    const suffix = prefix ? `_${prefix}` : '';
    const $ = (id) => document.getElementById(`${id}${suffix}`);
    const longitudeInput = $('longitude');
    const tzInput = $('tz_offset');
    const tzNameInput = $('city_tz');
    const cityInput = $('city');
    const queryInput = $('city_query');
    const dropdown = $('city-dropdown');
    const manualToggle = $('manual_longitude');
    const manualWrap = $('manual-longitude-wrap');
    const cityWrap = $('city-wrap');
    const shichenGrid = $('shichen-grid');
    const birthTimeInput = $('birth_time');
    const birthDateInput = $('birth_date');

    // ---------- tz_offset 精确计算(IANA 历史规则,含夏令时) ----------
    async function recomputeTzOffset() {
        if (!tzNameInput || !tzInput || !tzNameInput.value) return;
        const d = (birthDateInput && birthDateInput.value) || '1990-01-15';
        const t = (birthTimeInput && birthTimeInput.value) || '12:00';
        const hint = document.querySelector(`#city-wrap${suffix} .form__hint`);
        try {
            const resp = await fetch(
                `/geo/tz_offset?tz=${encodeURIComponent(tzNameInput.value)}` +
                `&dt=${encodeURIComponent(`${d}T${t}`)}`);
            const data = await resp.json();
            if (!resp.ok || data.error) throw new Error(data.error || `HTTP ${resp.status}`);
            tzInput.value = data.offset_hours;
            if (hint) hint.textContent =
                `选中后自动填经度 + 按出生时间算时区偏移(当前:${data.offset_hours >= 0 ? '+' : ''}${data.offset_hours}${data.is_dst ? ' · 夏令时' : ''},含历史夏令时规则)`;
        } catch (e) {
            // 显式暴露,不静默填默认:时区错 = 时辰错
            console.error('[promo] tz_offset 计算失败:', e);
            if (hint) hint.textContent = `⚠ 时区计算失败:${e.message}(tz_offset 未更新,详见控制台)`;
        }
    }

    // ---------- 全量城市 autocomplete ----------
    let searchTimer = null;
    let items = [];
    let activeIdx = -1;

    function renderDropdown(list) {
        if (!dropdown) return;
        items = list;
        activeIdx = -1;
        if (!list.length) {
            dropdown.hidden = true;
            return;
        }
        dropdown.innerHTML = list.map((r, i) => {
            const zh = r.zh || r.name;
            const sub = [
                r.name !== zh ? r.name : '',
                r.country === 'CN' ? '' : r.country,
                `经度 ${r.lng}`,
                r.tz,
            ].filter(Boolean).join(' · ');
            return `<div class="city-dropdown__item" data-idx="${i}">`
                + `<strong>${zh}</strong><small>${sub}</small></div>`;
        }).join('');
        dropdown.hidden = false;
        dropdown.querySelectorAll('.city-dropdown__item').forEach(el => {
            el.addEventListener('mousedown', (e) => {
                e.preventDefault();  // 抢在 input blur 前选中
                selectItem(items[Number(el.dataset.idx)]);
            });
        });
    }

    function selectItem(r) {
        if (queryInput) queryInput.value = r.zh || r.name;
        if (cityInput) cityInput.value = r.zh || r.name;
        if (longitudeInput) longitudeInput.value = r.lng;
        if (tzNameInput) tzNameInput.value = r.tz;
        if (dropdown) dropdown.hidden = true;
        recomputeTzOffset();
    }

    if (queryInput) {
        queryInput.addEventListener('input', () => {
            clearTimeout(searchTimer);
            const q = queryInput.value.trim();
            if (!q) {
                if (dropdown) dropdown.hidden = true;
                return;
            }
            searchTimer = setTimeout(async () => {
                try {
                    const resp = await fetch(`/geo/search?q=${encodeURIComponent(q)}`);
                    const data = await resp.json();
                    if (!resp.ok || data.error) throw new Error(data.error || `HTTP ${resp.status}`);
                    renderDropdown(data.results);
                } catch (e) {
                    console.error('[promo] 城市搜索失败:', e);
                }
            }, 250);
        });
        queryInput.addEventListener('keydown', (e) => {
            if (!dropdown || dropdown.hidden) return;
            const els = dropdown.querySelectorAll('.city-dropdown__item');
            if (!els.length) return;
            if (e.key === 'ArrowDown') activeIdx = Math.min(activeIdx + 1, els.length - 1);
            else if (e.key === 'ArrowUp') activeIdx = Math.max(activeIdx - 1, 0);
            else if (e.key === 'Enter') {
                e.preventDefault();
                if (activeIdx >= 0) selectItem(items[activeIdx]);
                return;
            } else if (e.key === 'Escape') {
                dropdown.hidden = true;
                return;
            } else {
                return;
            }
            els.forEach((el, i) => el.classList.toggle('is-active', i === activeIdx));
            if (els[activeIdx]) els[activeIdx].scrollIntoView({ block: 'nearest' });
        });
        queryInput.addEventListener('blur', () => {
            setTimeout(() => { if (dropdown) dropdown.hidden = true; }, 150);
        });
    }

    // 出生时间变化 → 重算时区偏移(夏令时边界依赖具体日期时刻)
    [birthDateInput, birthTimeInput].forEach(el => {
        if (el) el.addEventListener('change', recomputeTzOffset);
    });

    // ---------- 手动经度 toggle ----------
    const manualValueInput = $('manual_longitude_value');
    if (manualToggle) {
        manualToggle.addEventListener('change', () => {
            const manual = manualToggle.checked;
            if (manual) {
                if (cityWrap) cityWrap.style.display = 'none';
                if (manualWrap) manualWrap.style.display = '';
                // 手动经度模式:tz 用浏览器本地(对齐 iOS"设备时区")
                const localTz = -new Date().getTimezoneOffset() / 60;
                if (tzInput) tzInput.value = localTz;
                // 把当前 longitude hidden value 同步到 visible input
                if (longitudeInput && manualValueInput) {
                    manualValueInput.value = longitudeInput.value || 116.41;
                }
            } else {
                if (cityWrap) cityWrap.style.display = '';
                if (manualWrap) manualWrap.style.display = 'none';
                recomputeTzOffset();
            }
        });
    }
    // 手动经度输入 → 同步到 hidden longitude
    if (manualValueInput) {
        manualValueInput.addEventListener('input', () => {
            if (longitudeInput) longitudeInput.value = manualValueInput.value;
        });
    }

    // ---------- 12 时辰快捷选 ----------
    if (shichenGrid) {
        shichenGrid.innerHTML = SHICHEN_DATA.map(s => `
            <button type="button"
                    class="shichen-btn"
                    data-hour="${s.hour}"
                    title="${s.name}时 ${s.label}(填中点 ${String(s.hour).padStart(2, '0')}:00)">
                <span class="shichen-btn__name">${s.name}</span>
                <span class="shichen-btn__time">${String(s.hour).padStart(2, '0')}:00</span>
            </button>
        `).join('');

        const markSelected = () => {
            // 反推当前 birth_time 是哪个时辰,标记选中态
            if (!birthTimeInput || !birthTimeInput.value) return;
            const hour = parseInt(birthTimeInput.value.split(':')[0], 10);
            // 23 点归子时(对齐 backend setSect(1))
            const shichenHour = (hour === 23) ? 0 : (Math.floor(hour / 2) * 2);
            shichenGrid.querySelectorAll('.shichen-btn').forEach(btn => {
                const isSelected = parseInt(btn.dataset.hour, 10) === shichenHour;
                btn.classList.toggle('is-selected', isSelected);
            });
        };

        shichenGrid.querySelectorAll('.shichen-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const hour = parseInt(btn.dataset.hour, 10);
                const timeStr = `${String(hour).padStart(2, '0')}:00`;
                if (birthTimeInput) birthTimeInput.value = timeStr;
                markSelected();
                recomputeTzOffset();  // 时辰变化 → 重算夏令时偏移
            });
        });
        markSelected();  // 初始化选中态
    }

    // 页面加载:默认城市/默认日期也按真实规则算一遍 tz_offset
    recomputeTzOffset();
}

document.addEventListener('DOMContentLoaded', () => {
    // bazi / daily 表单(prefix='')
    // compat 表单(prefix='a' + 'b')
    initBirthForm('');
    initBirthForm('a');
    initBirthForm('b');

    // ---------- 表单提交反馈(2026-08-13:用户反馈点了提交"毫无反应") ----------
    // 提交后:按钮禁用 + 变"⏳ 生成中…",静态灰字换成计秒动态状态。
    // 浏览器 required 校验失败不会触发 submit 事件,所以进到这里的一定是真提交。
    document.addEventListener('submit', (e) => {
        const form = e.target;
        if (!(form instanceof HTMLFormElement)) return;
        const btn = form.querySelector('button[type="submit"]');
        if (!btn || btn.disabled) return;  // 双击/重复提交防护

        btn.disabled = true;
        btn.textContent = '⏳ 生成中…';

        const meta = form.querySelector('.form__meta');
        if (!meta) return;
        meta.classList.add('form__meta--active');
        let elapsed = 0;
        const tick = () => {
            elapsed += 1;
            meta.textContent =
                `已提交,正在排盘 + 调用 AI 解读…已等待 ${elapsed} 秒`
                + '(预计时长见按钮原提示;成功后自动跳转,请勿关闭/刷新页面)';
        };
        meta.textContent = '已提交,正在排盘 + 调用 AI 解读…(成功后自动跳转,请勿关闭/刷新页面)';
        setInterval(tick, 1000);
        // 计时器不清理:成功跳转/失败整页返回时,本页 JS 生命周期自然结束
    });
});
