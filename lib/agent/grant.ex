defmodule Dialup.Agent.Grant do
  @moduledoc false

  @default_ttl :timer.minutes(15)

  def new(token, opts \\ %{}) do
    opts = Map.new(opts)
    now = System.monotonic_time(:millisecond)
    ttl = Map.get(opts, :expires_in, @default_ttl)

    %{
      token: token,
      capabilities: normalize_capabilities(Map.get(opts, :capabilities, :all)),
      projections: Map.get(opts, :projections, [:state, :regions, :actions]),
      require_version: Map.get(opts, :require_version, true),
      issued_at: now,
      expires_at: if(ttl == :infinity, do: :infinity, else: now + ttl),
      revoked_at: nil
    }
  end

  def active?(%{revoked_at: revoked_at}) when not is_nil(revoked_at), do: false
  def active?(%{expires_at: :infinity}), do: true

  def active?(%{expires_at: expires_at}) do
    System.monotonic_time(:millisecond) < expires_at
  end

  def allows?(grant, capability) do
    grant.capabilities == :all or capability in grant.capabilities
  end

  def projects?(grant, projection), do: projection in grant.projections

  def revoke(grant) do
    %{grant | revoked_at: System.monotonic_time(:millisecond)}
  end

  def public(grant) do
    %{
      "capabilities" =>
        if(grant.capabilities == :all,
          do: "all",
          else: Enum.map(grant.capabilities, &to_string/1)
        ),
      "projections" => Enum.map(grant.projections, &to_string/1),
      "requireVersion" => grant.require_version,
      "expiresInMs" => remaining_ms(grant)
    }
  end

  defp remaining_ms(%{expires_at: :infinity}), do: nil

  defp remaining_ms(%{expires_at: expires_at}) do
    max(expires_at - System.monotonic_time(:millisecond), 0)
  end

  defp normalize_capabilities(:all), do: :all

  defp normalize_capabilities(capabilities),
    do: capabilities |> List.wrap() |> Enum.map(&normalize/1)

  defp normalize(capability) when is_binary(capability), do: capability
  defp normalize(capability), do: to_string(capability)
end
