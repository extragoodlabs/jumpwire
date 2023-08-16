defmodule JumpWire.LocalConfig do
  @moduledoc """
  `LocalConfig` is a simple layer on top of ETS.

  Unlike `GlobalConfig`, data stored in `LocalConfig` is NOT replicated to other
  nodes in the cluster. Therefore, it is meant only for local data.
  """

  use GenServer

  @tables [
    {:manifest_connections, :set, [read_concurrency: true]}
  ]

  @doc """
  Add a new entry/value to the table.
  """
  def put(table, key, value) do
    :ets.insert(table, {key, value})
  end

  @doc """
  Add a new entry/value to the table, returning `false` if the `key` is already present.
  """
  def put_new(table, key, value) do
    :ets.insert_new(table, {key, value})
  end

  def get(table, key, default \\ nil) do
    case :ets.lookup(table, key) do
      [{_, v}] -> v
      _ -> default
    end
  end

  def delete(table, key) do
    :ets.delete(table, key)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Enum.each(@tables, fn {name, type, extra_opts} ->
      :ets.new(name, [type, :named_table, :public] ++ extra_opts)
    end)

    {:ok, %{}}
  end
end
