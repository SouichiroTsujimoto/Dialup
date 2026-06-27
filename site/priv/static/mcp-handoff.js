(() => {
  if (window.__mcpHandoffInstalled) return;
  window.__mcpHandoffInstalled = true;

  const MCPHandoff = {
    endpoint: null,

    absoluteEndpoint() {
      return this.endpoint ? location.origin + this.endpoint : "";
    },

    curlText(url) {
      return (
        `curl -X POST ${url} \\\n` +
        `  -H 'Content-Type: application/json' \\\n` +
        `  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call",` +
        `"params":{"name":"read_scene","arguments":{}}}'`
      );
    },

    async issueHandoff() {
      const dialup = window.DialupApp;
      if (!dialup?.tabId) {
        throw new Error("セッションの準備中です。少し待って再度お試しください。");
      }

      const res = await fetch(
        `/_dialup/agent-handoff?tab_id=${encodeURIComponent(dialup.tabId)}`,
        { method: "POST", credentials: "same-origin" }
      );

      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || `発行に失敗しました (${res.status})`);
      }

      const handoff = await res.json();
      this.endpoint = handoff.endpoint;

      return {
        ...handoff,
        url: this.absoluteEndpoint(),
      };
    },

    async copyText(text) {
      await navigator.clipboard.writeText(text);
    },

    async copyFrom(btn) {
      const root = btn.closest("[data-mcp-card], [data-mcp-global-panel]");
      const sel = btn.getAttribute("data-mcp-copy");
      const el = root?.querySelector(`[data-mcp-text="${sel}"]`);
      const text = el ? el.textContent.trim() : "";

      try {
        await this.copyText(text);
        const prev = btn.textContent;
        btn.textContent = "コピーしました";
        setTimeout(() => {
          btn.textContent = prev;
        }, 1200);
      } catch (_error) {
        // クリップボード非対応環境は無視
      }
    },

    syncEndpoint() {
      const card = document.querySelector("[data-mcp-card]");
      const path = card?.getAttribute("data-mcp-endpoint");
      if (path && !this.endpoint) this.endpoint = path;
    },

    renderGlobalLive(panel, handoff) {
      const cta = panel.querySelector("[data-mcp-global-cta]");
      const live = panel.querySelector("[data-mcp-global-live]");
      if (!cta || !live) return;

      cta.hidden = true;
      live.hidden = false;

      const endpointEl = live.querySelector('[data-mcp-text="endpoint"]');
      const curlEl = live.querySelector('[data-mcp-text="curl"]');
      if (endpointEl) endpointEl.textContent = handoff.url;
      if (curlEl) curlEl.textContent = this.curlText(handoff.url);
    },

    resetGlobalPanel(panel) {
      const cta = panel.querySelector("[data-mcp-global-cta]");
      const live = panel.querySelector("[data-mcp-global-live]");
      const status = panel.querySelector("[data-mcp-global-status]");
      const issueBtn = panel.querySelector('[data-mcp-global="issue"]');

      if (cta) cta.hidden = false;
      if (live) live.hidden = true;
      if (status) status.textContent = "";
      if (issueBtn) issueBtn.disabled = false;
    },

    closeGlobalPanel(panel, toggle) {
      panel.hidden = true;
      if (toggle) toggle.setAttribute("aria-expanded", "false");
    },

    openGlobalPanel(panel, toggle) {
      panel.hidden = false;
      if (toggle) toggle.setAttribute("aria-expanded", "true");
    },

    toggleGlobalPanel(panel, toggle) {
      if (panel.hidden) {
        this.openGlobalPanel(panel, toggle);
      } else {
        this.closeGlobalPanel(panel, toggle);
      }
    },

    async issueFromGlobal(panel) {
      const status = panel.querySelector("[data-mcp-global-status]");
      const issueBtn = panel.querySelector('[data-mcp-global="issue"]');

      if (issueBtn) issueBtn.disabled = true;
      if (status) status.textContent = "エンドポイントを発行中…";

      try {
        const handoff = await this.issueHandoff();
        this.renderGlobalLive(panel, handoff);
        if (status) status.textContent = "";
      } catch (error) {
        if (status) status.textContent = error.message;
        if (issueBtn) issueBtn.disabled = false;
      }
    },

    initGlobal() {
      const toggle = document.querySelector('[data-mcp-global="toggle"]');
      const panel = document.querySelector("[data-mcp-global-panel]");
      if (!toggle || !panel) return;

      toggle.addEventListener("click", (event) => {
        event.stopPropagation();
        this.toggleGlobalPanel(panel, toggle);
      });

      panel.addEventListener("click", (event) => {
        event.stopPropagation();
      });

      document.addEventListener("click", () => {
        this.closeGlobalPanel(panel, toggle);
      });

      document.addEventListener("keydown", (event) => {
        if (event.key === "Escape") this.closeGlobalPanel(panel, toggle);
      });

      const issueBtn = panel.querySelector('[data-mcp-global="issue"]');
      issueBtn?.addEventListener("click", () => this.issueFromGlobal(panel));

      const copyBtns = panel.querySelectorAll("[data-mcp-copy]");
      copyBtns.forEach((btn) => {
        btn.addEventListener("click", () => this.copyFrom(btn));
      });
    },

    init() {
      this.initGlobal();
      this.syncEndpoint();

      new MutationObserver(() => this.syncEndpoint()).observe(document.documentElement, {
        childList: true,
        subtree: true,
      });
    },
  };

  window.MCPHandoff = MCPHandoff;

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => MCPHandoff.init());
  } else {
    MCPHandoff.init();
  }
})();
