// /join and /pair fallback: the invite or ticket lives in the fragment, which never reaches a
// server. Build the app link from it on this device; nothing is sent anywhere.
(function () {
  var section = document.querySelector("[data-kind]");
  if (!section) return;
  var kind = section.getAttribute("data-kind");
  var payload = location.hash.slice(1);
  var ok = /^[A-Za-z0-9._~=-]{8,4096}$/.test(payload);
  if (!ok) {
    document.getElementById("ready").hidden = true;
    document.getElementById("missing").hidden = false;
    return;
  }
  document.getElementById("open").href = "gudo://" + kind + "/" + payload;
})();
