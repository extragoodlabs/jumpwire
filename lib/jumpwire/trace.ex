defmodule JumpWire.Tracer do
  @moduledoc """
  Utility module for working with distributed traces, stacktraces, and breadcrumbs/context for error reporting.
  """

  @doc """
  Store additional context in the process metadata.

  This function will merge the given map or keyword list into the existing metadata, with the
  exception of setting a key to `nil`, which will remove that key from the metadata.

  Context is stored as Logger metadata and will additionally be used by Honeybadger.
  """
  @spec context(map | keyword) :: :ok
  def context(metadata) when is_map(metadata), do: metadata |> Keyword.new() |> context()
  def context(metadata) when is_list(metadata) do
    Logger.metadata(metadata)
  end

  @spec context() :: keyword
  def context(), do: Logger.metadata()

  @spec clear_context() :: :ok
  def clear_context, do: Logger.reset_metadata()
end
