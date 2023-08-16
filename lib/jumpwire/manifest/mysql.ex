defmodule JumpWire.Manifest.MySQL do
  require Logger
  alias JumpWire.Proxy.MySQL

  @spec extract(JumpWire.Manifest.t) :: {atom(), map} | {:error, any}
  def extract(manifest) do
    {:ok, params, _} = MySQL.params_from_manifest(manifest)
    {:ok, pid} = MyXQL.start_link(params)

    database = Keyword.fetch!(params, :database)

    with {:ok, names} <- list_tables(database, pid),
         {:ok, tables} <- describe_tables(names, database, pid) do
      schemas = schemas_from_tables(tables, database)
      GenServer.stop(pid)
      {:ok, %{schemas: schemas, title: database, version: "1.0.0"}}
    else
      {:error, error} ->
        GenServer.stop(pid)
        Logger.error("Failed to extract schemas: #{inspect error}")
        {:error, "Configuration failed to describe db"}
    end
  end

  defp schemas_from_tables(tables, base_title) do
    tables
    |> Stream.map(fn {table, cols} ->
      required = cols
      |> Stream.reject(fn %{nullable: nullable} -> nullable end)
      |> Enum.map(fn %{name: name} -> name end)

      props = cols
      |> Stream.reject(fn col -> String.ends_with?(col[:name], "_jw_handle") end)
      |> Stream.reject(fn col -> String.ends_with?(col[:name], "_jw_enc") end)
      |> Stream.map(fn col -> {col[:name], extract_col(col)} end)
      |> Map.new()

      schema = %{
        "type" => "object",
        "title" => "#{base_title}: #{table}",
        "required" => required,
        "properties" => props,
      }
      {table, schema}
    end)
    |> Map.new()
  end

  defp describe_tables(table_names, database, pid) do
    Enum.reduce_while(table_names, {:ok, []}, fn name, {:ok, acc} ->
      case describe_table(name, database, pid) do
        {:ok, cols} ->
          acc = [{name, cols} | acc]
          {:cont, {:ok, acc}}

        err -> {:halt, err}
      end
    end)
  end

  defp list_tables(database, pid) do
    query = """
    SELECT table_name FROM information_schema.tables
    WHERE table_schema=? AND table_type='BASE TABLE'
    """
    case MyXQL.query(pid, query, [database]) do
      {:ok, %{rows: rows}} -> {:ok, List.flatten(rows)}
      err -> err
    end
  end

  defp describe_table(table_name, database, pid) do
    query = """
    SELECT column_name, data_type, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema=? AND table_name=?
    ORDER BY column_name ASC
    """

    with {:ok, %{rows: rows}} <- MyXQL.query(pid, query, [database, table_name]) do
      tables = Enum.map(rows, fn [name, type, default, nullable] ->
        %{name: name, type: type, default: default, nullable: nullable == "YES"}
      end)
      {:ok, tables}
    end
  end

  defp extract_col(%{type: type, default: default}) do
    extract_type = cond do
      String.ends_with?(type, "text") -> "string"
      String.ends_with?(type, "blob") -> "string"
      String.ends_with?(type, "char") -> "string"
      true -> type
    end

    if not is_nil(default) do
      %{"type" => extract_type, "example" => default}
    else
      %{"type" => extract_type}
    end
  end
end
