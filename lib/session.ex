defmodule Dialup.Session do
  @moduledoc """
  Issues scoped capability grants and headless sessions for HTTP MCP.

  - `grant/2` — bearer token for an existing browser session process
  - `start/2` — agent-first headless session (`POST /_dialup/agent-session`)
  - `browser_url/1` — one-time join URL for browser handoff (`issue_browser_url`)

  Browser handoff completes at `POST /_dialup/finalize-join` (cookie + token consumption).
  See `guides/agent-handoff.md`.
  """

  def grant(session_pid, opts) when is_pid(session_pid) do
    Dialup.UserSessionProcess.issue_agent_grant(session_pid, Map.new(opts))
  end

  def revoke(session_pid, token) when is_pid(session_pid) do
    Dialup.UserSessionProcess.revoke_agent(session_pid, token)
  end

  @doc """
  Starts a headless session for an agent without an open browser tab.

  Returns `{:ok, descriptor}` with `token`, `endpoint`, `grant`, `path`, and `sessionId`.
  """
  def start(app_module, path, opts \\ %{}) do
    Dialup.UserSessionProcess.start_headless(app_module, path, Map.new(opts))
  end

  @doc """
  Issues a one-time browser join URL for an existing session process.

  Returns `browserUrl`, `browserToken`, and `expiresInMs`. The human client completes join via
  WebSocket attach and `POST /_dialup/finalize-join` (see `guides/agent-handoff.md`).
  """
  def browser_url(session_pid) when is_pid(session_pid) do
    Dialup.UserSessionProcess.issue_browser_token(session_pid)
  end
end
