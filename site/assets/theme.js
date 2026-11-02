// Runs in <head> so a saved theme, and the scroll fallback's starting pose, apply before first paint.
(function () {
  var d = document.documentElement;
  d.className += " js";
  if (!(window.CSS && CSS.supports("animation-timeline: view()"))) d.className += " no-sda";
  try {
    var t = localStorage.getItem("theme");
    if (t === "light" || t === "dark") d.setAttribute("data-theme", t);
  } catch (e) {}
})();
