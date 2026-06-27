defmodule Dialup.App.Layout do
  use Dialup.Layout

  def render(assigns) do
    ~H"""
    <nav class="site-nav">
      <div class="nav-inner">
        <.dialup_action navigate="/" class="nav-logo">Dialup</.dialup_action>
        <div class="nav-links">
          <a href="https://github.com/SouichiroTsujimoto/Dialup" class="nav-github" target="_blank" aria-label="GitHub">
            <svg class="github-icon" height="20" viewBox="0 0 16 16" width="20" aria-hidden="true" fill="currentColor">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/>
            </svg>
            <span class="github-label">Repo</span>
          </a>
          <.dialup_action navigate="/docs" class={if @current_path == "/docs", do: "active"}>Get Started</.dialup_action>
          <.dialup_action navigate="/docs/concepts" class={if @current_path == "/docs/concepts", do: "active"}>Concepts</.dialup_action>
          <.dialup_action navigate="/docs/api" class={if @current_path == "/docs/api", do: "active"}>API</.dialup_action>
          <.dialup_action navigate="/agent_demo" class={if @current_path == "/agent_demo", do: "active"}>MCP Demo</.dialup_action>
          <.dialup_action navigate="/demo" class={if @current_path == "/demo", do: "active"}>Demo</.dialup_action>
          <div class="nav-handoff-wrap">
            <button
              type="button"
              class="nav-handoff-btn"
              data-mcp-global="toggle"
              aria-expanded="false"
              aria-controls="nav-handoff-panel"
            >
              AI に渡す
            </button>
            <div
              id="nav-handoff-panel"
              class="nav-handoff-panel"
              data-mcp-global-panel
              hidden
            >
              <div data-mcp-global-cta class="nav-handoff-cta">
                <p class="nav-handoff-title">AI Agent に渡す</p>
                <p class="nav-handoff-note">
                  このライブセッションを操作できる MCP エンドポイントを発行します。
                </p>
                <button type="button" class="btn btn-ghost btn-block" data-mcp-global="issue">
                  エンドポイントを発行 →
                </button>
                <p class="nav-handoff-status" data-mcp-global-status></p>
              </div>
              <div data-mcp-global-live class="nav-handoff-live" hidden>
                <p class="nav-handoff-badge">セッション発行済み</p>
                <label class="nav-handoff-label">MCP エンドポイント（フル URL）</label>
                <div class="nav-handoff-copy-row">
                  <code class="nav-handoff-endpoint" data-mcp-text="endpoint"></code>
                  <button type="button" class="btn btn-primary btn-sm" data-mcp-copy="endpoint">コピー</button>
                </div>
                <details class="nav-handoff-curl">
                  <summary>curl で試す</summary>
                  <pre data-mcp-text="curl"></pre>
                  <button type="button" class="btn btn-primary btn-sm" data-mcp-copy="curl">curl をコピー</button>
                </details>
              </div>
            </div>
          </div>
        </div>
        <span id="ws-status" class="ws-lamp" title="WebSocket status"></span>
      </div>
    </nav>

    <main class="page-content">
      {raw(@inner_content)}
    </main>

    <footer class="site-footer">
      <p>This site was built with Dialup. Repository is <a href="https://github.com/SouichiroTsujimoto/dialup_site">here</a>.</p>
    </footer>
    """
  end
end
