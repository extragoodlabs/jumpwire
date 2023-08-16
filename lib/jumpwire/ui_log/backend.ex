defmodule JumpWire.UiLog.Backend do
  @moduledoc """
  Custom Logger backend meant to automatically push all :warn and :error messages to a web controller.
  """

  @behaviour :gen_event

  def init(__MODULE__) do
    config = Application.get_env(:logger, __MODULE__, [])
    {:ok, config}
  end

  def handle_call({:configure, options}, _state) do
    config =
      Application.get_env(:logger, __MODULE__, [])
      |> Keyword.merge(options)

    Application.put_env(:logger, __MODULE__, config)
    {:ok, :ok, config}
  end

  def handle_event({level, _gl, {Logger, msg, _ts, metadata}}, state) when level in [:warn, :error] do
    if Keyword.has_key?(metadata, :org_id) do
      org_id = Keyword.get(metadata, :org_id)
      # Interpolating `msg` so that, if it's an improper list, it gets converted into an actual string
      uilog_msg = "#{msg}"
      JumpWire.UiLog.create(org_id, level, uilog_msg)
    end

    {:ok, state}
  end

  def handle_event({_, _, _}, state), do: {:ok, state}
  def handle_event(:flush, state), do: {:ok, state}
end
