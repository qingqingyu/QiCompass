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
})();
