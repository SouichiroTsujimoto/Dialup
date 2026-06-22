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
end
