defmodule JumpWire.Events do
  @moduledoc """
  Module to handle observability events during normal operation.
  """

  def database_client_connected(meta) do
    labels = %{node: node(), database: meta.db_id, client: meta.client_id, organization: meta.organization_id}
    :telemetry.execute([:database, :connection], %{total: 1}, labels)

    session_id = Uniq.UUID.uuid4()
    message = %{
      organization_id: meta.organization_id,
      client_id: meta.client_id,
      identity_id: meta.identity_id,
      session_id: session_id,
      manifest_id: meta.db_id,
      start_time: DateTime.utc_now(),
    }
    JumpWire.Websocket.push("client:connected", message)
    session_id
  end

  def database_client_disconnected(meta) do
    labels = %{node: node(), database: meta.db_id, client: meta.client_id, organization: meta.organization_id}
    :telemetry.execute([:database, :connection], %{total: -1}, labels)

    send_session_event("client:disconnected", %{end_time: DateTime.utc_now()}, meta)
  end

  def database_accessed(attributes, meta) do
    labels = attributes
    |> Stream.map(fn attr -> String.split(attr, ":", parts: 2) end)
    |> Stream.filter(fn attr -> length(attr) == 2 end)
    |> Enum.group_by(&List.first/1, &List.last/1)

    send_session_event("client:access", labels, meta)
  end

  def database_request_blocked(meta) do
    send_session_event("client:blocked", %{}, meta)
  end

  @spec database_field_accessed(JumpWire.Record.t(), map()) :: :ok
  def database_field_accessed(record, metadata) do
    key = %{
      client: metadata.client_id,
      database: metadata.db_id,
      organization: metadata.organization_id,
      session: metadata.session_id,
      node: node(),
    }
    labels = record.labels |> Map.values() |> List.flatten()

    Enum.each(labels, fn label ->
      labels = Map.put(key, :label, label)
      :telemetry.execute(
        [:database, :access],
        %{count: 1},
        labels
      )
    end)
  end

  defp send_session_event(event, message, meta) do
    case meta do
      %{session_id: nil} -> :ok

      %{session_id: session_id} ->
        message = message
        |> Map.put(:organization_id, meta.organization_id)
        |> Map.put(:session_id, session_id)
        JumpWire.Websocket.push(event, message)

      _ -> :ok
    end
  end
end
