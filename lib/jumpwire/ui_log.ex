defmodule JumpWire.UiLog do
  @moduledoc """
  Simple interface for sending logs to a web controller.
  """

  require Logger
  alias JumpWire.Websocket

  @type allowed_types :: :info | :warn | :error | :fatal
  @allowed_types [:info, :warn, :error, :fatal]

  @spec create(String.t, allowed_types, String.t) :: term
  def create(org_id, type, entry) when type in @allowed_types do
    message = %{
      organization_id: org_id,
      type: type,
      entry: entry,
      timestamp: DateTime.utc_now()
    }

    Websocket.push("ui_logs:entry", message, silent_push: true)
  end

  def create(_, type, _) do
    Logger.error("Invalid UiLog type #{inspect type}")
  end
end
