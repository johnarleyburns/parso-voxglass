/* Glass / Solid renderer toggle.
   Mirrors AdaptiveGlass's branch on accessibilityReduceTransparency:
   every screen must be legible in both. The choice persists across pages
   so a reviewer can walk the whole set in fallback mode. */
(function () {
  var KEY = "voxglass-mockup-render";
  var stored = null;
  try { stored = localStorage.getItem(KEY); } catch (e) { /* file:// */ }
  var mode = stored === "solid" ? "solid" : "glass";
  document.documentElement.setAttribute("data-render", mode);

  function build() {
    var bar = document.createElement("div");
    bar.className = "render-toggle";
    bar.setAttribute("role", "group");
    bar.setAttribute("aria-label", "Panel rendering");
    ["glass", "solid"].forEach(function (value) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = value === "glass" ? "GLASS" : "SOLID";
      b.title = value === "glass"
        ? "AdaptiveGlass — material blur"
        : "AdaptiveGlass — Reduce Transparency fallback";
      b.setAttribute("aria-pressed", String(mode === value));
      b.addEventListener("click", function () {
        mode = value;
        document.documentElement.setAttribute("data-render", mode);
        try { localStorage.setItem(KEY, mode); } catch (e) { /* ignore */ }
        Array.prototype.forEach.call(bar.children, function (child) {
          child.setAttribute("aria-pressed", String(child.textContent.toLowerCase() === mode));
        });
      });
      bar.appendChild(b);
    });
    document.body.appendChild(bar);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", build);
  } else {
    build();
  }
})();
