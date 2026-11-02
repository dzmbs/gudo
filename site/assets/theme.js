// Runs in <head> so a saved theme applies before first paint.
(function () {
  var d = document.documentElement;
  d.className += " js";
  try {
    var t = localStorage.getItem("theme");
    if (t === "light" || t === "dark") d.setAttribute("data-theme", t);
  } catch (e) {}
})();
