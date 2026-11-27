// 渐进增强(全部可关):内容在静态 HTML 里,这里只做 header 滚动线 / 移动菜单 / 滚动揭示 / 落印。
// `.js` 类由 BaseHead 里的 inline 一行尽早加上,保证 reveal 初始隐藏不会闪烁。
// 无 JS 时:菜单按钮不可用(移动端导航待后续 slice 增强)、内容全部可见。

(function () {
  "use strict";

  /* ---- header hairline on scroll + mobile menu ---- */
  const header = document.querySelector(".site-header");
  function onScroll(): void {
    if (header) header.classList.toggle("scrolled", window.scrollY > 8);
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  const menuBtn = document.querySelector<HTMLButtonElement>(".menu-btn");
  const nav = document.querySelector(".nav");
  if (menuBtn && nav) {
    menuBtn.addEventListener("click", function () {
      const open = nav.classList.toggle("open");
      menuBtn.setAttribute("aria-expanded", String(open));
    });
  }

  /* ---- scroll reveal: ink-in once ---- */
  const reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      function (es) {
        es.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add("in");
            io.unobserve(e.target);
          }
        });
      },
      { rootMargin: "0px 0px -8% 0px" }
    );
    reveals.forEach(function (el) {
      io.observe(el);
    });
  } else {
    reveals.forEach(function (el) {
      el.classList.add("in");
    });
  }

  /* ---- seals stamp when they enter view ---- */
  const seals = document.querySelectorAll<HTMLElement>(".seal[data-stamp]");
  if ("IntersectionObserver" in window) {
    const so = new IntersectionObserver(
      function (es) {
        es.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add("is-stamping");
            so.unobserve(e.target);
          }
        });
      },
      { threshold: 0.6 }
    );
    seals.forEach(function (s) {
      so.observe(s);
    });
  }

  /* ---- article TOC: scrollspy + reading progress line (S03) ---- */
  const toc = document.querySelector(".toc");
  const article = document.querySelector<HTMLElement>("[data-article]");
  if (toc && article) {
    const links = Array.from(toc.querySelectorAll<HTMLAnchorElement>("a[href^='#']"));
    const targets = links
      .map(function (a) {
        return document.getElementById(a.hash.slice(1));
      })
      .filter(function (el): el is HTMLElement {
        return el !== null;
      });
    const fill = toc.querySelector<HTMLElement>("[data-progress]");
    function onTocScroll(): void {
      let current: HTMLElement | null = null;
      targets.forEach(function (t) {
        if (t.offsetTop <= window.scrollY + 140) current = t;
      });
      links.forEach(function (a) {
        if (current !== null && a.hash === "#" + current.id) {
          a.setAttribute("aria-current", "true");
        } else {
          a.removeAttribute("aria-current");
        }
      });
      if (fill) {
        const span = article.offsetHeight - window.innerHeight;
        const p = span > 0 ? (window.scrollY - article.offsetTop) / span : 0;
        fill.style.transform = "scaleY(" + Math.min(1, Math.max(0, p)) + ")";
      }
    }
    window.addEventListener("scroll", onTocScroll, { passive: true });
    onTocScroll();
  }

  /* ---- glossary term popovers, hover devices only (S03) ----
     无 JS 时 .term 仍是真实链接(有 href)或纯下划线词(无 href),正确退化。 */
  if (window.matchMedia("(hover: hover)").matches) {
    const pop = document.createElement("div");
    pop.className = "pop";
    pop.setAttribute("role", "tooltip");
    pop.id = "term-pop";
    const docLang = document.documentElement.lang || "en";
    const readLabel = docLang.toLowerCase().startsWith("zh") ? "閱讀完整條目" : "Read the full entry";
    let hideTimer: number | undefined;
    function hidePop(): void {
      hideTimer = window.setTimeout(function () {
        pop.classList.remove("show");
      }, 180);
    }
    function showPop(term: HTMLElement): void {
      window.clearTimeout(hideTimer);
      const def = term.getAttribute("data-def");
      if (!def) {
        pop.classList.remove("show"); // 防御:无释义时收回上一张已显示的卡
        return;
      }
      pop.innerHTML = "";
      const h = document.createElement("p"); // .pt(非标题:避免文章大纲层级跳跃)
      h.className = "pt";
      const zh = term.getAttribute("data-zh");
      if (zh) {
        const z = document.createElement("span");
        z.className = "zh";
        z.textContent = zh;
        h.appendChild(z);
      }
      const t = document.createElement("span");
      t.textContent = term.getAttribute("data-title") ?? "";
      h.appendChild(t);
      pop.appendChild(h);
      const d = document.createElement("p");
      d.textContent = def;
      pop.appendChild(d);
      const href = term.getAttribute("href");
      if (href) {
        const a = document.createElement("a");
        a.className = "link-arrow"; // 箭头由 ::after 提供(hover 位移),勿手写 →
        a.href = href;
        a.textContent = readLabel;
        pop.appendChild(a);
      }
      const r = term.getBoundingClientRect();
      pop.style.left = Math.max(8, Math.min(r.left, window.innerWidth - 296)) + "px";
      pop.style.top = window.scrollY + r.bottom + 10 + "px";
      // 读屏聚焦/悬停术语时播报释义卡(卡隐藏时 visibility:hidden 不在无障碍树,无噪音)
      term.setAttribute("aria-describedby", "term-pop");
      pop.classList.add("show");
    }
    document.querySelectorAll<HTMLElement>(".term[data-def]").forEach(function (term) {
      term.addEventListener("mouseenter", function () {
        showPop(term);
      });
      term.addEventListener("mouseleave", hidePop);
      // 键盘可达(规格 §10:focus 显示 / blur 隐藏,与设计稿 site.js 一致)
      term.addEventListener("focus", function () {
        showPop(term);
      });
      term.addEventListener("blur", hidePop);
    });
    pop.addEventListener("mouseenter", function () {
      window.clearTimeout(hideTimer);
    });
    pop.addEventListener("mouseleave", hidePop);
    // 键盘对称:focus 进卡内链接同样保卡,focus 离卡才收
    pop.addEventListener("focusin", function () {
      window.clearTimeout(hideTimer);
    });
    pop.addEventListener("focusout", hidePop);
    document.body.appendChild(pop);
  }

  /* ---- mobile sticky CTA (S03 规格四条) ----
     sessionStorage 是全局规则里唯一认可的 try/catch 例外:隐私模式会抛,
     关不掉吸底条不是错误路径,吞掉并按「未关闭」处理。 */
  const sticky = document.querySelector(".sticky-cta");
  const trigger = document.querySelector("[data-sticky-trigger]");
  const footer = document.querySelector(".site-footer");
  if (sticky && trigger) {
    let dismissed = false;
    try {
      dismissed = window.sessionStorage.getItem("qc-sticky-off") === "1";
    } catch {
      dismissed = false;
    }
    const x = sticky.querySelector<HTMLButtonElement>(".x");
    x?.addEventListener("click", function () {
      dismissed = true;
      sticky.classList.remove("show");
      try {
        window.sessionStorage.setItem("qc-sticky-off", "1");
      } catch {
        /* 同上:隐私模式写不进,本次会话内已关闭即可 */
      }
    });
    function onStickyScroll(): void {
      if (dismissed) return;
      const past = trigger.getBoundingClientRect().bottom < 0;
      const footerNear = footer
        ? footer.getBoundingClientRect().top < window.innerHeight
        : false;
      sticky.classList.toggle("show", past && !footerNear);
    }
    window.addEventListener("scroll", onStickyScroll, { passive: true });
    onStickyScroll();
  }
})();
