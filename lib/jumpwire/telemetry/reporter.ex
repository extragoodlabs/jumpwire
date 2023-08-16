defmodule JumpWire.Telemetry.Reporter do
  @moduledoc """
  Reporter for sending Telemetry metrics to a web controller. Aggregation is
  handled by TelemetryMetricsPrometheus, this reporter just forwards
  those metrics.
  """

  alias TelemetryMetricsPrometheus.Core.{Aggregator, Registry}
  require Logger

  @proxy_metrics JumpWire.Telemetry.proxy_metrics()
  |> Enum.map(fn metric -> metric.name end)

  @doc """
  Collect all proxy metrics and export them to the controller.
  """
  def export_proxy_metrics() do
    scrape()
    |> Map.take(@proxy_metrics)
    |> Map.values()
    |> List.flatten()
    |> Enum.each(fn {{event, labels}, value} ->
      msg = labels
      |> labels_to_message()
      |> Map.put(:event, event)
      |> Map.put(:value, value)
      JumpWire.Websocket.push("stats:proxy", msg)
    end)
  end

  @doc """
  Aggregate and return the metrics from TelemetryMetricsPrometheus. While
  TelemetryMetricsPrometheus.Core.scrape/1 will format the metrics as a
  string for displaying on a web page, this function will keep the metrics
  structure.
  """
  def scrape(name \\ :prometheus_metrics) do
    # check if the prometheus process is alive before making calls to it
    case GenServer.whereis(name) do
      nil -> %{}
      _ ->
        config = Registry.config(name)
        metrics = Registry.metrics(name)

        :ok = Aggregator.aggregate(metrics, config.aggregates_table_id, config.dist_table_id)

        Aggregator.get_time_series(config.aggregates_table_id)
    end
  end

  defp labels_to_message(
    %{organization: org_id, session: session_id, label: label, client: client_id, database: database_id}
  ) do
    %{organization_id: org_id, session_id: session_id, label: label, client_id: client_id, database_id: database_id}
  end
  defp labels_to_message(labels), do: labels
end
