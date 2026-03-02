defmodule Dialup.Server do
  use Plug.Router

  plug(Plug.Static, at: "/", from: {:dialup, "priv/static"})
  plug(:match)
  plug(:dispatch)

  # WebSocket upgrade endpoint
  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(Dialup.WebSocket, [], timeout: :infinity)
    |> halt()
  end

  get _ do
    path = conn.request_path

    initial_html =
      case Dialup.Router.dispatch(path, %{}) do
        {:ok, html} -> html
        {:error, :not_found} -> "<h1>404 Not Found</h1>"
      end

    shell = shell_html(path, initial_html)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, shell)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp shell_html(path, initial_html) do
    """
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="UTF-8">
      <title>Dialup</title>
      <script src="https://unpkg.com/idiomorph@0.7.4"></script>
      <style>
        body { font-family: sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
        #ws-status { font-size: 0.8rem; color: gray; }
        [ws-href] {
          color: #0066cc;
          text-decoration: underline;
          cursor: pointer;
        }
        [ws-href]:hover {
          color: #b600daff;
        }
      </style>
    </head>
    <body>
      <p id="ws-status">接続中...</p>
      <div id="dialup-root">#{initial_html}</div>

      <script src="/dialup.js"></script>
      <script>
        Dialup.connect("#{path}");
      </script>
    </body>
    </html>
    """
  end
end
