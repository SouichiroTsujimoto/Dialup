# ファイルアップロード

Dialupはファイルアップロードをフレームワーク機能として持たない。既存の `push_event` / `handle_event` / HTTP エンドポイントを組み合わせることで、ストレージの選択に依存しない形で実装できる。

## パターンA: HTTP POST経由（ローカル・任意のストレージ）

ファイルをElixirサーバー経由で受け取るパターン。ローカルファイルシステム・S3・R2など任意のストレージに対応できる。

```
<input type="file"> → fetch POST /upload（Cookie付き）
                    → HTTPエンドポイントがsession_idでRegistryを検索 → PID取得
                    → GenServer.cast(pid, {:event, "upload_done", params})
                    → handle_event が通常通り処理 → WebSocket経由で再描画
```

### アプリ側の実装

```elixir
# lib/my_app.ex
defmodule MyApp do
  use Application
  use Dialup, app_dir: __DIR__ <> "/app"

  @impl Application
  def start(_type, _args) do
    children = [
      {Dialup, app: __MODULE__, port: 4000},
      {Plug.Cowboy, scheme: :http, plug: MyApp.UploadEndpoint, port: 4001}
      # または Bandit を追加:
      # {Bandit, plug: MyApp.UploadEndpoint, port: 4001}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
```

```elixir
# lib/upload_endpoint.ex
defmodule MyApp.UploadEndpoint do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:multipart],
    multipart_limit: 10_000_000  # 10MB

  plug :match
  plug :dispatch

  post "/upload" do
    session_id = conn.req_cookies["dialup_session"]

    case Registry.lookup(Dialup.SessionRegistry, session_id) do
      [{pid, _}] ->
        params = conn.body_params
        Dialup.UserSessionProcess.event(pid, "upload_done", params)
        send_resp(conn, 200, "ok")

      [] ->
        send_resp(conn, 401, "unauthorized")
    end
  end
end
```

```elixir
# lib/app/page.ex
defmodule MyApp.App.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, %{avatar_url: nil, uploading: false}}
  end

  def handle_event("upload_done", %{"file" => %Plug.Upload{} = upload}, assigns) do
    dest = "priv/static/uploads/#{upload.filename}"
    File.cp!(upload.path, dest)
    {:update, assigns |> overwrite(%{avatar_url: "/uploads/#{upload.filename}", uploading: false})}
  end

  def render(assigns) do
    ~H"""
    <input type="file" id="avatar-input" />
    <button ws-event="start_upload">アップロード</button>
    <%= if @avatar_url do %>
      <img src={@avatar_url} />
    <% end %>
    """
  end
end
```

```html
<script>
Dialup.connect({
  hooks: {
    trigger_upload: () => {
      const input = document.getElementById("avatar-input");
      const file = input.files[0];
      if (!file) return;

      const form = new FormData();
      form.append("file", file);

      fetch("/upload", { method: "POST", body: form });
      // 完了後は handle_event("upload_done", ...) がサーバー側で発火する
    }
  }
});
</script>
```

セッションCookieがそのまま認証に使えるため、別途アップロードトークンの管理は不要。

---

## パターンB: 署名付きURL経由（S3 / R2 / MinIO）

ファイルをElixirサーバーを経由せず、クライアントが直接S3互換サービスにアップロードするパターン。大容量ファイルや高トラフィック時にサーバー負荷を避けたい場合に適する。

```
ws-event="request_upload" → handle_event → 署名付きURL生成
                          → push_event("upload_ready", %{url: ..., key: ...})
                          → JSフックで fetch PUT → S3/R2に直接アップロード
                          → 完了後 ws-event="upload_done" + key
                          → handle_event でDB保存等
```

### アプリ側の実装

```elixir
# lib/app/page.ex
defmodule MyApp.App.Page do
  use Dialup.Page

  def mount(_params, assigns) do
    {:ok, %{file_url: nil}}
  end

  def handle_event("request_upload", filename, assigns) do
    key = "uploads/#{Ecto.UUID.generate()}/#{filename}"
    # ex_aws 等で署名付きURLを生成（有効期限: 15分）
    presigned_url = MyApp.Storage.presigned_put_url(key, expires_in: 900)

    {:push_event, "upload_ready", %{url: presigned_url, key: key}, assigns}
  end

  def handle_event("upload_done", key, assigns) do
    public_url = MyApp.Storage.public_url(key)
    {:update, assigns |> overwrite(%{file_url: public_url})}
  end

  def render(assigns) do
    ~H"""
    <input type="file" id="file-input" />
    <button ws-event="request_upload" ws-value="">アップロード</button>
    <%= if @file_url do %>
      <img src={@file_url} />
    <% end %>
    """
  end
end
```

```html
<script>
Dialup.connect({
  hooks: {
    upload_ready: async ({ url, key }) => {
      const input = document.getElementById("file-input");
      const file = input.files[0];
      if (!file) return;

      await fetch(url, {
        method: "PUT",
        body: file,
        headers: { "Content-Type": file.type }
      });

      // アップロード完了をサーバーに通知
      // ws-event を手動でトリガーする代わりに、カスタムイベントを送る
      Dialup.send("upload_done", key);
    }
  }
});
</script>
```

`Dialup.send` をクライアントから呼べるように `dialup.js` の公開APIに追加する必要がある（現在は `connect` のみ公開）。S3側でCORSの設定も必要。

---

## パターンの選択指針

| 条件 | 推奨パターン |
|------|------------|
| ローカルファイルシステムに保存したい | A |
| S3/R2/MinIO 使用 + ファイルが小〜中程度 | A（シンプル） |
| S3/R2/MinIO 使用 + 大容量ファイル・高トラフィック | B |
| サーバーのメモリ・帯域を節約したい | B |
