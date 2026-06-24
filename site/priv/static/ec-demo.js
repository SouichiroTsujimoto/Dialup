(() => {
  if (window.__ecDemoInstalled) return;
  window.__ecDemoInstalled = true;

  let drag = null;

  const root = () => document.getElementById("ec-catalog");
  const cart = () => root()?.querySelector("[data-cart-dock]");
  const send = (event, value) => window.DialupApp?.send(event, value);
  const productFrom = (node) => node.closest("[data-product-id]")?.dataset.productId;

  function syncPageEnhancements() {
    const page = root();
    const toast = page?.querySelector(".toast.is-visible");
    if (toast && !toast._hideTimer) {
      toast._hideTimer = window.setTimeout(() => toast.classList.remove("is-visible"), 1800);
    }
  }

  function moveDrag(event) {
    if (!drag || event.pointerId !== drag.pointerId) return;
    event.preventDefault();
    drag.x = event.clientX;
    drag.y = event.clientY;

    const size = drag.proxy.getBoundingClientRect().width;
    drag.proxy.style.left = `${event.clientX - size / 2}px`;
    drag.proxy.style.top = `${event.clientY - size / 2}px`;

    const dock = cart();
    const rect = dock?.getBoundingClientRect();
    const over = rect &&
      event.clientX >= rect.left - 24 && event.clientX <= rect.right + 24 &&
      event.clientY >= rect.top - 24 && event.clientY <= rect.bottom + 24;
    dock?.classList.toggle("is-over", Boolean(over));
  }

  function endDrag(event) {
    if (!drag || (event.pointerId != null && event.pointerId !== drag.pointerId)) return;

    const dock = cart();
    const rect = dock?.getBoundingClientRect();
    const x = event.clientX ?? drag.x;
    const y = event.clientY ?? drag.y;
    const over = rect &&
      x >= rect.left - 24 && x <= rect.right + 24 &&
      y >= rect.top - 24 && y <= rect.bottom + 24;

    drag.proxy.remove();
    root()?.classList.remove("is-dragging");
    dock?.classList.remove("is-ready", "is-over");

    if (over) send("add_to_cart", { id: drag.productId });
    drag = null;
  }

  document.addEventListener("pointerdown", (event) => {
    const page = root();
    const media = event.target.closest("[data-draggable-product]");
    if (!page || !media || page.dataset.mode !== "drag" || event.button !== 0) return;

    event.preventDefault();
    const shot = media.querySelector(".product-shot");
    const rect = shot.getBoundingClientRect();
    const proxy = shot.cloneNode(true);
    proxy.classList.add("drag-proxy");
    proxy.style.width = `${rect.width}px`;
    proxy.style.height = `${rect.height}px`;
    document.body.append(proxy);

    drag = {
      pointerId: event.pointerId,
      productId: productFrom(media),
      proxy,
      x: event.clientX,
      y: event.clientY
    };

    media.setPointerCapture?.(event.pointerId);
    page.classList.add("is-dragging");
    cart()?.classList.add("is-ready");
    moveDrag(event);
  });

  document.addEventListener("click", (event) => {
    const page = root();
    const media = event.target.closest("[data-draggable-product]");
    if (!page || !media || page.dataset.mode !== "hold") return;
    send("hold_product", { id: productFrom(media) });
  });

  document.addEventListener("keydown", (event) => {
    const page = root();
    if (!page) return;

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      page.querySelector("[data-product-search]")?.focus();
    }

    const media = event.target.closest("[data-draggable-product]");
    if (media && (event.key === "Enter" || event.key === " ")) {
      event.preventDefault();
      send(page.dataset.mode === "hold" ? "hold_product" : "add_to_cart", {
        id: productFrom(media)
      });
    }

    if (event.key === "Escape") endDrag(event);
  });

  window.addEventListener("pointermove", moveDrag, { passive: false });
  window.addEventListener("pointerup", endDrag);
  window.addEventListener("pointercancel", endDrag);

  new MutationObserver(syncPageEnhancements).observe(document.documentElement, {
    childList: true,
    subtree: true
  });
  window.addEventListener("DOMContentLoaded", syncPageEnhancements);
  syncPageEnhancements();
})();
