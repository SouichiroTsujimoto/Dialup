defmodule DialupSite.Telemetry do
  require Logger

  def attach do
    :telemetry.attach_many(
      "dialup-site-logger",
      [
        [:dialup, :event, :exception],
        [:dialup, :navigate, :exception]
      ],
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle([:dialup, :event, :exception], %{duration: d}, meta, _config) do
    ms = System.convert_time_unit(d, :native, :millisecond)

    Logger.error(
      "[Dialup] Event #{meta.event} on #{meta.path} failed (#{ms}ms): #{Exception.message(meta.reason)}"
    )
  end

  def handle([:dialup, :navigate, :exception], %{duration: d}, meta, _config) do
    ms = System.convert_time_unit(d, :native, :millisecond)

    Logger.error(
      "[Dialup] Navigate to #{meta.path} failed (#{ms}ms): #{Exception.message(meta.reason)}"
    )
  end

  def handle(_event, _measurements, _meta, _config), do: :ok
end
