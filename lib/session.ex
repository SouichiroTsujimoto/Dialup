defmodule Dialup.Session do
  @moduledoc """
  Issues scoped capability grants for an existing Dialup session process.

  The returned endpoint is a bearer capability. Keep capabilities narrow and use a short
  `:expires_in` for delegated agents.
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
  """
  def browser_url(session_pid) when is_pid(session_pid) do
    Dialup.UserSessionProcess.issue_browser_token(session_pid)
  end
end
