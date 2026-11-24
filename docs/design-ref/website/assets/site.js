/* QiCompass Web — shared progressive enhancements (mockup).
   Rule: every page must be fully readable & crawlable with this file disabled.
   Everything here is enhancement: popovers, scrollspy, reveal, sticky CTA, mini tools. */
(function () {
  "use strict";
  var doc = document.documentElement;
  doc.classList.add("js");

  var safeStore = {
    get: function (k) { try { return window.sessionStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { window.sessionStorage.setItem(k, v); } catch (e) { /* storage blocked: feature degrades to per-load */ } }
  };

  /* ---- header hairline on scroll + mobile menu ---- */
  var header = document.querySelector(".site-header");
  function onScroll() { if (header) header.classList.toggle("scrolled", window.scrollY > 8); }
  window.addEventListener("scroll", onScroll, { passive: true }); onScroll();
  var menuBtn = document.querySelector(".menu-btn"), nav = document.querySelector(".nav");
  if (menuBtn && nav) menuBtn.addEventListener("click", function () {
    var open = nav.classList.toggle("open"); menuBtn.setAttribute("aria-expanded", String(open));
  });

  /* ---- annotation toggle (design board only) ---- */
  var annoBtn = document.querySelector("[data-toggle-anno]");
  if (annoBtn) annoBtn.addEventListener("click", function () { document.body.classList.toggle("hide-anno"); });

  /* ---- scroll reveal: ink-in once ---- */
  var reveals = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { rootMargin: "0px 0px -8% 0px" });
    reveals.forEach(function (el) { io.observe(el); });
  } else { reveals.forEach(function (el) { el.classList.add("in"); }); }

  /* ---- seals stamp when they enter view ---- */
  var seals = document.querySelectorAll(".seal[data-stamp]");
  if ("IntersectionObserver" in window) {
    var so = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("is-stamping"); so.unobserve(e.target); } });
    }, { threshold: .6 });
    seals.forEach(function (s) { so.observe(s); });
  }

  /* ---- glossary popovers: <a class="term" href="/en/..." data-zh="甲" data-title="Jia Wood" data-def="..."> ---- */
  var pop = document.createElement("div"); pop.className = "pop"; pop.setAttribute("role", "tooltip"); pop.id = "term-pop";
  document.body.appendChild(pop);
  var hideT;
  function showPop(a) {
    clearTimeout(hideT);
    pop.innerHTML = '<h5>' + (a.dataset.zh ? '<span class="zh ' + (a.dataset.el ? "el-" + a.dataset.el : "") + '">' + a.dataset.zh + '</span>' : "") +
      a.dataset.title + '</h5><p>' + a.dataset.def + '</p><a class="link-arrow" href="' + a.getAttribute("href") + '">Read the full entry</a>';
    var r = a.getBoundingClientRect();
    var left = Math.min(window.scrollX + r.left, window.scrollX + document.documentElement.clientWidth - 296);
    pop.style.left = Math.max(8, left) + "px";
    pop.style.top = (window.scrollY + r.bottom + 10) + "px";
    pop.classList.add("show"); a.setAttribute("aria-describedby", "term-pop");
  }
  function hidePop() { hideT = setTimeout(function () { pop.classList.remove("show"); }, 180); }
  var canHover = window.matchMedia("(hover: hover)").matches;
  document.querySelectorAll(".term[data-def]").forEach(function (a) {
    if (!canHover) return;                      // touch: the link just navigates (internal link > tooltip)
    a.addEventListener("mouseenter", function () { showPop(a); });
    a.addEventListener("focus", function () { showPop(a); });
    a.addEventListener("mouseleave", hidePop); a.addEventListener("blur", hidePop);
  });
  pop.addEventListener("mouseenter", function () { clearTimeout(hideT); });
  pop.addEventListener("mouseleave", hidePop);

  /* ---- TOC scrollspy + reading progress ---- */
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc a[href^='#']"));
  var progress = document.querySelector("[data-progress]");
  var article = document.querySelector("[data-article]");
  if (tocLinks.length) {
    var targets = tocLinks.map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); });
    var spy = function () {
      var y = window.scrollY + 140, idx = 0;
      targets.forEach(function (t, i) { if (t && t.offsetTop <= y) idx = i; });
      tocLinks.forEach(function (a, i) { if (i === idx) a.setAttribute("aria-current", "true"); else a.removeAttribute("aria-current"); });
      if (progress && article) {
        var top = article.offsetTop, h = article.offsetHeight - window.innerHeight;
        var p = Math.max(0, Math.min(1, (window.scrollY - top) / Math.max(1, h)));
        progress.style.transform = "scaleY(" + p.toFixed(3) + ")";
      }
    };
    window.addEventListener("scroll", spy, { passive: true }); spy();
  }

  /* ---- mobile sticky CTA: show after trigger scrolls away, hide near footer; dismiss per session ---- */
  var sticky = document.querySelector(".sticky-cta"), trigger = document.querySelector("[data-sticky-trigger]"), footer = document.querySelector(".site-footer");
  if (sticky && trigger && safeStore.get("qc-sticky-off") !== "1") {
    var check = function () {
      var pastTrigger = trigger.getBoundingClientRect().bottom < 0;
      var nearFooter = footer && footer.getBoundingClientRect().top < window.innerHeight;
      sticky.classList.toggle("show", pastTrigger && !nearFooter);
    };
    window.addEventListener("scroll", check, { passive: true }); check();
    var x = sticky.querySelector(".x");
    if (x) x.addEventListener("click", function () { sticky.remove(); safeStore.set("qc-sticky-off", "1"); });
  }

  /* ---- Day Master finder (MOCK). Production: GET /api/public/chart (backend lunar_python, setSect(1)).
     Client NEVER does calendar math in production (CLAUDE.md). This JDN arithmetic exists only so the mockup feels alive.
     Anchor: 1992-04-18 = 甲子 day. ---- */
  var STEMS = [
    ["甲", "Jia", "Yang Wood", "wood", "jia-wood"], ["乙", "Yi", "Yin Wood", "wood", "yi-wood"],
    ["丙", "Bing", "Yang Fire", "fire", "bing-fire"], ["丁", "Ding", "Yin Fire", "fire", "ding-fire"],
    ["戊", "Wu", "Yang Earth", "earth", "wu-earth"], ["己", "Ji", "Yin Earth", "earth", "ji-earth"],
    ["庚", "Geng", "Yang Metal", "metal", "geng-metal"], ["辛", "Xin", "Yin Metal", "metal", "xin-metal"],
    ["壬", "Ren", "Yang Water", "water", "ren-water"], ["癸", "Gui", "Yin Water", "water", "gui-water"]
  ];
  var BRANCHES = "子丑寅卯辰巳午未申酉戌亥";
  function dayPillar(dateStr) {
    var p = dateStr.split("-").map(Number);
    var d = Date.UTC(p[0], p[1] - 1, p[2]), a = Date.UTC(1992, 3, 18);
    var n = Math.round((d - a) / 864e5); var i = ((n % 60) + 60) % 60;
    return { stem: STEMS[i % 10], branch: BRANCHES[i % 12] };
  }
  window.QC = { dayPillar: dayPillar, STEMS: STEMS };
  document.querySelectorAll("[data-dm-finder]").forEach(function (f) {
    var out = f.querySelector("[data-dm-out]");
    f.addEventListener("submit", function (e) {
      e.preventDefault();
      var v = f.querySelector("input[type=date]").value; if (!v) return;
      var r = dayPillar(v), s = r.stem;
      out.innerHTML =
        '<div class="dm-result ink-in"><span class="zh el-' + s[3] + '" style="font-size:56px;line-height:1">' + s[0] + '</span>' +
        '<div><div class="kicker">Your Day Master</div><div style="font:400 22px/1.2 var(--f-serif)">' + s[1] + ' ' + s[2].split(" ")[1] + '</div>' +
        '<div class="caption">Day pillar <span class="zh">' + s[0] + r.branch + '</span> · ' + s[2] + '</div>' +
        '<a class="link-arrow" href="/en/day-master/' + s[4] + '">What it means</a></div></div>';
    });
  });

  /* ---- Shichen dial: highlight the current double-hour (cinnabar dot is DESIGN-approved: 当前时辰点) ---- */
  document.querySelectorAll("[data-shichen-dial]").forEach(function (dial) {
    var h = new Date().getHours(); var idx = Math.floor(((h + 1) % 24) / 2); // 子 = 23:00–00:59
    var node = dial.querySelector('[data-b="' + idx + '"]'); if (node) node.classList.add("now");
    var label = dial.parentNode.querySelector("[data-shichen-label]");
    if (label && node) label.textContent = node.getAttribute("data-label");
  });
})();
