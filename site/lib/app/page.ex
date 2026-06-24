defmodule Dialup.App.Page do
  use Dialup.Page

  def page_title(_assigns), do: "Dialup — WebSocket-first Elixir Framework with HTTP MCP"

  defp counter_example, do: ~S|
defmodule Dialup.App.Counter do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, Map.put(assigns, :count, 0)}
  end

  def handle_event("inc", _, assigns) do
    {:update, Map.update!(assigns, :count, &(&1 + 1))}
  end

  def render(assigns) do
    ~H"""
    <p>Count: {@count}</p>
    <button ws-event="inc">+1</button>
    """
  end
end
|

  defp mcp_step1, do: ~S|declare_action name: :add_item, ...
render the action button with dialup_action in HEEx|

  defp mcp_step2, do: ~S|POST /agent/:token
{"method":"tools/list"}
→ add_item, read_scene, …|

  defp mcp_step3, do: ~S|{"method":"tools/call",
 "name":"add_item",
 "arguments":{"_version":3}}|

  def render(assigns) do
    ~H"""
    <section class="hero">
      <.dialup_action navigate="/docs" name={:navigate_docs_badge} class="hero-badge">
        <span class="badge-default">$ mix dialup.new my_app</span>
        <span class="badge-hover">→ Get Started!</span>
      </.dialup_action>
      <h1>
        <span class="hl">WebSocket</span>-first<br/>
        Elixir Web Framework
      </h1>
      <p class="hero-sub">
        Dialup はサーバー上の GenServer がブラウザの状態を持ち続ける WebSocket ファーストの
        Elixir フレームワークです。<br/>
        <strong>UI を書くだけで MCP API が自動生成</strong>されるのが最大の特徴です。
      </p>
      <div class="hero-actions">
        <.dialup_action navigate="/agent_demo" class="btn btn-primary">MCP Live Demo &rarr;</.dialup_action>
        <.dialup_action navigate="/docs" class="btn btn-ghost">Get Started</.dialup_action>
        <.dialup_action navigate="/demo" class="btn btn-ghost">UI Demo</.dialup_action>
      </div>

      <div class="hero-code">
        <div class="code-titlebar">
          <span class="code-dot dot-r"></span>
          <span class="code-dot dot-y"></span>
          <span class="code-dot dot-g"></span>
          <span class="code-filename">app/counter/page.ex</span>
        </div>
        <pre><code>{counter_example()}</code></pre>
      </div>
    </section>

    <section class="section mcp-spotlight">
      <div class="container">
        <div class="section-title">
          <h2>UI から MCP API が生える</h2>
          <p>
            <code>&lt;.dialup_action&gt;</code> と <code>declare_action</code> を書くだけ。
            別途 REST を設計する必要はありません。
          </p>
        </div>
        <div class="mcp-spotlight-grid">
          <div class="mcp-spotlight-card">
            <span class="mcp-spotlight-step">1</span>
            <h3>人間向け UI を書く</h3>
            <pre class="mcp-spotlight-code"><code>{mcp_step1()}</code></pre>
          </div>
          <div class="mcp-spotlight-card mcp-spotlight-card-accent">
            <span class="mcp-spotlight-step">2</span>
            <h3>ツールが自動生成される</h3>
            <pre class="mcp-spotlight-code"><code>{mcp_step2()}</code></pre>
          </div>
          <div class="mcp-spotlight-card">
            <span class="mcp-spotlight-step">3</span>
            <h3>同じ handle_event/3</h3>
            <pre class="mcp-spotlight-code"><code>{mcp_step3()}</code></pre>
          </div>
        </div>
        <div class="section-content mcp-spotlight-cta">
          <.dialup_action navigate="/agent_demo" name={:navigate_agent_demo_spotlight} class="btn btn-primary">
            左右分割のライブデモを見る &rarr;
          </.dialup_action>
        </div>
      </div>
    </section>

    <section class="section section-alt">
      <div class="section-title">
        <h2>なぜ Dialup なのか</h2>
        <p>1 tab = 1 process で、全てのページにまたがってセッションが継続。<br/>状態はサーバー上に存在し、WebSocket で同期される。</p>
      </div>
      <div class="features container">
        <div class="feature-card mcp-feature-card">
          <span class="feature-icon">🤖</span>
          <h3>UI → HTTP MCP</h3>
          <p>action / region 宣言から <code>tools/list</code> と <code>tools/call</code> を自動生成。人間は WebSocket、AI は JSON-RPC。</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">📁</span>
          <h3>ファイルベースルーティング</h3>
          <p><code>app/users/[id]/page.ex</code> を置くだけで <code>/users/:id</code> になる。<code>router.ex</code> への手書き登録は不要。</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">⚡</span>
          <h3>1 tab = 1 process</h3>
          <p>各セッションが独立した GenServer を持つ。状態はサーバー上に存在し、WebSocket で同期される。</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">🔄</span>
          <h3>session / assigns の分離</h3>
          <p><code>session</code> はナビゲーションをまたいで持続。<code>assigns</code> はページ遷移でリセット。ログイン状態が自然に保たれる。</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">🧩</span>
          <h3>クライアント側 DOM モーフィング</h3>
          <p>サーバーは HTML を送るだけ。差分適用は idiomorph が担う。プロトコルが単純でデバッグしやすい。</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">🪶</span>
          <h3>軽量な依存関係</h3>
          <p>Phoenix 本体は不使用。Bandit + HEEx + idiomorph のみ。クライアント JS は自作 ~100 行 + idiomorph 5KB。</p>
        </div>
        <div class="feature-card">
          <span class="feature-icon">🔁</span>
          <h3>自動再接続</h3>
          <p>切断を検知したら指数バックオフで再接続。プロセスが生きていれば状態はそのまま復元される。</p>
        </div>
      </div>
    </section>

    <section class="section section-alt">
      <div class="container">
        <div class="section-title">
          <h2>フレームワーク比較</h2>
          <p>Dialup は Phoenix LiveView と Next.js に大きく影響を受けています</p>
        </div>
        <div class="compare-wrap">
          <table class="compare-table">
            <thead>
              <tr>
                <th>機能</th>
                <th class="highlight-col">Dialup</th>
                <th>Next.js</th>
                <th>Phoenix LiveView</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>言語</td>
                <td class="highlight-col">Elixir</td>
                <td>TypeScript / JS</td>
                <td>Elixir</td>
              </tr>
              <tr>
                <td>ルーティング</td>
                <td class="highlight-col">ファイルベース</td>
                <td>ファイルベース</td>
                <td><code>router.ex</code> に定義</td>
              </tr>
              <tr>
                <td>状態の管理</td>
                <td class="highlight-col">サーバー</td>
                <td>クライアント (React)</td>
                <td>サーバー</td>
              </tr>
              <tr>
                <td>AI Agent API</td>
                <td class="highlight-col">UI 宣言から HTTP MCP 自動生成</td>
                <td>別途実装</td>
                <td>別途実装</td>
              </tr>
              <tr>
                <td>リアルタイム通信</td>
                <td class="highlight-col">WebSocket 組み込み</td>
                <td>別途実装が必要</td>
                <td>WebSocket 組み込み</td>
              </tr>
              <tr>
                <td>DOM 更新</td>
                <td class="highlight-col">idiomorph</td>
                <td>Virtual DOM (React)</td>
                <td>サーバサイドで差分計算 + morphdom等</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>

    <section class="section section-alt">
      <div class="container">
        <div class="section-title">
          <h2>実際に動かしてみる</h2>
          <p>MCP のライブデモと、カウンター・フォームの UI デモを用意しています。</p>
        </div>
        <div class="section-content hero-actions" style="justify-content: center;">
          <.dialup_action navigate="/agent_demo" name={:navigate_agent_demo_footer} class="btn btn-primary">MCP Live Demo &rarr;</.dialup_action>
          <.dialup_action navigate="/demo" name={:navigate_demo_footer} class="btn btn-ghost">UI Demo</.dialup_action>
        </div>
      </div>
    </section>
    """
  end
end
