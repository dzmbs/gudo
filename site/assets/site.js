// Copy buttons, the header rule on scroll, and the theme switch. Nothing else.
(function () {
  var top = document.querySelector(".top");
  if (top) {
    var onScroll = function () { top.classList.toggle("scrolled", window.scrollY > 4); };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
  }

  document.querySelectorAll(".copy").forEach(function (b) {
    b.addEventListener("click", function () {
      var code = b.parentNode.querySelector("code");
      if (!code || !navigator.clipboard) return;
      navigator.clipboard.writeText(code.textContent.trim()).then(function () {
        b.textContent = "Copied";
        setTimeout(function () { b.textContent = "Copy"; }, 1600);
      });
    });
  });

  var root = document.documentElement;
  var buttons = document.querySelectorAll(".theme button");
  function mark() {
    var t = root.getAttribute("data-theme") || "auto";
    buttons.forEach(function (b) { b.setAttribute("aria-pressed", String(b.value === t)); });
  }
  buttons.forEach(function (b) {
    b.addEventListener("click", function () {
      if (b.value === "auto") root.removeAttribute("data-theme");
      else root.setAttribute("data-theme", b.value);
      try {
        if (b.value === "auto") localStorage.removeItem("theme");
        else localStorage.setItem("theme", b.value);
      } catch (e) {}
      mark();
    });
  });
  mark();
})();
