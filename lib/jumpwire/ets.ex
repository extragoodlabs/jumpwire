defmodule JumpWire.ETS do
  defmacro __using__(opts) do
    quote do
      use Hydrax.DeltaCrdt,
        cluster_mod: {JumpWire.ETS, unquote(opts)},
        cluster_name: __MODULE__,
        crdt_opts: [on_diffs: {JumpWire.ETS, :on_diffs, []}]

      @doc """
      Replace all data for a subkey in the table with the passed in values.
      """
      def set(table, subkey, values) when is_map(values) do
        values = Map.to_list(values)
        set(table, subkey, values)
      end

      def set(table, subkey, values) when is_list(values) do
        keys = DeltaCrdt.to_map(@crdt)
        |> Stream.map(fn {key, _} -> key end)
        |> Stream.filter(fn {crdt_table, _} -> crdt_table == table end)
        |> Stream.filter(fn {_, key} -> elem(key, 0) == subkey end)
        DeltaCrdt.drop(@crdt, keys)

        put_all(table, values)
      end

      def put(table, value = %{id: id, organization_id: org_id}) do
        put(table, {org_id, id}, value)
      end

      def put(table, key, value) do
        DeltaCrdt.put(@crdt, {table, key}, value)
      end

      @doc """
      Add every element of the enumerable to the ETS table. Objects with duplicate
      keys will be overwritten.
      """
      def put_all(table, subkey, values) do
        values = Stream.map(values, fn value = %{id: id} -> {{subkey, id}, value} end)
        put_all(table, values)
      end

      def put_all(table, values) do
        Enum.each(values, fn {key, value} ->
          DeltaCrdt.put(@crdt, {table, key}, value)
        end)
      end

      def get(table) do
        all(table, :_)
      end

      def get(table, key, default \\ nil) do
        case :ets.lookup(table, key) do
          [{_, val}] -> val
          _ -> default
        end
      end

      def all(table, key_pattern) do
        :ets.select(table, [{{key_pattern, :"$1"}, [], [:"$1"]}])
      end

      def match_all(table, key_pattern \\ :_, pattern) do
        :ets.match_object(table, {key_pattern, pattern})
      end

      @doc """
      Delete items with a partial or exact key match.
      """
      def delete(table, key) when is_tuple(key) do
        keys = DeltaCrdt.to_map(@crdt)
        |> Stream.filter(fn
          {{^table, _}, _} -> true
          _ -> false
        end)
        |> Stream.map(fn {key, _} -> key end)
        |> Stream.filter(fn {_table, crdt_key} ->
          matches_key?(crdt_key, key)
        end)
        |> Enum.into([])
        DeltaCrdt.drop(@crdt, keys)
      end

      def delete(table, id) do
        DeltaCrdt.delete(@crdt, {table, id})
      end

      defp matches_key?({crdt_key1, crdt_key2}, key) do
        case key do
          {^crdt_key1, ^crdt_key2} -> true
          {^crdt_key1, :_} -> true
          {:_, ^crdt_key2} -> true
          {:_, :_} -> true
          _ -> false
        end
      end

      defp matches_key?({crdt_key1, crdt_key2, crdt_key3}, key) do
        case key do
          {^crdt_key1, ^crdt_key2, ^crdt_key3} -> true
          {^crdt_key1, :_, ^crdt_key3} -> true
          {:_, ^crdt_key2, ^crdt_key3} -> true
          {:_, :_, ^crdt_key3} -> true
          {^crdt_key1, ^crdt_key2, :_} -> true
          {^crdt_key1, :_, :_} -> true
          {:_, ^crdt_key2, :_} -> true
          {:_, :_, :_} -> true
          _ -> false
        end
      end

      def fetch(table, id) do
        case get(table, id) do
          nil -> {:error, :not_found}
          val -> {:ok, val}
        end
      end
    end
  end

  use GenServer

  def start_link(args) do
    args = Enum.into(args, %{})
    GenServer.start_link(__MODULE__, args, name: args[:name])
  end

  def init(args) do
    {tables, args} = Map.pop(args, :tables, [])
    tables
    |> Stream.map(fn
      {table, type} -> {table, type}
      table -> {table, :set}
    end)
    |> Enum.each(fn {table, type} ->
      :ets.new(table, [type, :named_table, :public, read_concurrency: true])
    end)
    Hydrax.DeltaCrdt.init(args)
  end

  def handle_call({:set_members, members}, from, state) do
    Hydrax.DeltaCrdt.handle_call({:set_members, members}, from, state)
  end

  def handle_call(:members, from, state) do
    Hydrax.DeltaCrdt.handle_call(:members, from, state)
  end

  def on_diffs([]), do: :ok
  def on_diffs([{:add, {table, key}, value} | diffs]) do
    :ets.insert(table, {key, value})
    on_diffs(diffs)
  end
  def on_diffs([{:remove, {table, key}} | diffs]) do
    :ets.delete(table, key)
    on_diffs(diffs)
  end
end
