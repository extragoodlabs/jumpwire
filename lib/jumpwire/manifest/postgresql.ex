defmodule JumpWire.Manifest.Postgresql do
  require Logger

  @spec extract(JumpWire.Manifest.t) :: {atom(), map} | {:error, any}
  def extract(manifest) do
    {:ok, params, _} = JumpWire.Proxy.Postgres.params_from_manifest(manifest)
    {:ok, pid} = Postgrex.start_link(params)
    schema = Map.get(manifest.configuration, "schema", "public")
    database = params[:database]

    result =
      with {:ok, names} <- list_tables(schema, pid),
           {:ok, tables} <- describe_tables(names, schema, pid) do
        schemas = schemas_from_tables(tables, "#{database}.#{schema}")
        {:ok, %{schemas: schemas, title: "#{database}.#{schema}", version: "1.0.0"}}
      else
        _ -> {:error, "Configuration failed to describe db"}
      end

      GenServer.stop(pid)
      result
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

  defp describe_tables(table_names, schema, pid) do
    Enum.reduce_while(table_names, {:ok, []}, fn t, {:ok, acc} ->
      case describe_table(schema, t, pid) do
        {:ok, cols} ->
          acc = [{t, cols} | acc]
          {:cont, {:ok, acc}}
        err -> {:halt, err}
      end
    end)
  end

  defp list_tables(schema, pid) do
    query = "SELECT table_name FROM information_schema.tables WHERE table_schema=$1 AND table_type='BASE TABLE'"
    with {:ok, %{rows: rows}} <- Postgrex.query(pid, query, [schema]) do
      {:ok, List.flatten(rows)}
    end
  end

  defp describe_table(schema, table_name, pid) do
    query = """
    SELECT column_name, data_type, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema=$1 AND table_name=$2
    ORDER BY column_name ASC
    """

    with {:ok, %{rows: rows}} <- Postgrex.query(pid, query, [schema, table_name]) do
      tables = Enum.map(rows, fn [name, type, default, nullable] ->
        %{name: name, type: type, default: default, nullable: nullable == "YES"}
      end)
      {:ok, tables}
    end
  end

  defp extract_col(%{type: type, default: default}) do
    extract_type =
      case type do
        "text" -> "string"
        "character varying" -> "string"
        "character" -> "string"
        _ -> type
      end

    if not is_nil(default) do
      %{"type" => extract_type, "example" => default}
    else
      %{"type" => extract_type}
    end
  end
end
