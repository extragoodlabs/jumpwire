defmodule JumpWire.Proxy.BigQuery.Router do
  @moduledoc """
  A Plug.Router for proxying queries to BigQuery and applying policies.
  """

  use Plug.Router
  use Honeybadger.Plug
  require Logger

  if Mix.env() == :dev or Mix.env() == :test do
    use Plug.Debugger
  end

  plug :match
  plug :fetch_query_params

  plug Plug.Parsers,
    parsers: [{:json, json_decoder: Jason}],
    pass: ["*/*"]

  plug :dispatch

  alias JumpWire.Proxy.BigQuery.Client
  alias JumpWire.Proxy.SQL.Parser

  match "/*path" do
    # Extract SQL, apply policies on query, stop in case of error/block.
    with sql = extract_sql(conn),
         info = set_info(conn),
         {:ok, policy_sql} <- apply_policies(sql, info),
         request_body <- replace_sql_and_labels(conn, policy_sql),
         {:ok, response} <-
           Client.query(conn.method, bq_url(conn), request_body, bq_headers(conn)) do
      send_resp(conn, response.status, Jason.encode!(response.body))
    else
      {:error, :blocked} ->
        Logger.info("BigQuery request blocked by policy")
        send_resp(conn, 401, "not authorized")

      err ->
        Logger.error("Unexpected BigQuery error: #{inspect(err)}")
        send_resp(conn, 500, "error")
    end
  end

  defp extract_sql(%{body_params: body}) do
    case body do
      %{"configuration" => %{"query" => %{"query" => query}}} when is_binary(query) -> query
      _ -> nil
    end
  end

  defp set_info(%{body_params: body}) do
    params =
      case body do
        %{"configuration" => %{"labels" => labels}} when map_size(labels) > 0 -> labels
        _ -> %{}
      end
      |> Map.filter(fn {k, _} -> String.starts_with?(k, "jw_") end)

    %{
      module: __MODULE__,
      classification: "",
      type: :bigquery,
      # TODO: fetch from conn
      request_id: Uniq.UUID.uuid4(),
      organization_id: "org_generic",
      attributes: MapSet.new(["*"]),
      params: params
    }
  end

  defp replace_sql_and_labels(%{body_params: original}, replacement) do
    original =
      case original do
        %{"configuration" => %{"labels" => labels}} when map_size(labels) > 0 ->
          labels_without_jw = Map.reject(labels, fn {k, _} -> String.starts_with?(k, "jw_") end)
          put_in(original, ["configuration", "labels"], labels_without_jw)

        _ ->
          original
      end

    case original do
      %{"configuration" => %{"query" => %{"query" => query}}} when is_binary(query) ->
        put_in(original, ["configuration", "query", "query"], replacement)

      _ ->
        original
    end
  end

  defp apply_policies(sql, info) do
    case sql do
      nil ->
        {:ok, nil}

      _ ->
        # TODO run request policies
        policies = [
          %JumpWire.Policy{
            version: 2,
            id: Uniq.UUID.uuid4(),
            handling: :filter_request,
            label: "pii",
            organization_id: "org_id",
            apply_on_match: true,
            attributes: [MapSet.new(["*"])],
            configuration: %JumpWire.Policy.FilterRequest{
              table: "bigquery-public-data.usa_names.usa_1910_2013",
              field: "name"
            }
          }
        ]

        with {:ok, statements} <- Parser.parse(sql, :big_query),
             {:ok, [request | _]} <- query_statements_to_requests(statements) do
          result = apply_request_policies(policies, request, info)
          Parser.to_sql(result.source_data)
        else
          _ -> {:ok, sql}
        end
    end
  end

  defp bq_url(%{path_params: %{"path" => path}}) do
    uri = Enum.join(path, "/")
    "https://bigquery.googleapis.com/#{uri}"
  end

  defp bq_headers(%{req_headers: headers}) do
    without_host =
      headers
      |> Stream.reject(fn {k, _} -> Enum.member?(["host", "content-length", "accept"], k) end)
      |> Enum.to_list()

    [{"host", "bigquery.googleapis.com"}, {"accept", "application/json"} | without_host]
  end

  defp query_statements_to_requests(statements) do
    Enum.reduce_while(statements, {:ok, []}, fn {statement, ref}, {_, requests} ->
      case Parser.to_request(statement) do
        {:ok, request} ->
          request = %{request | source: ref}
          {:cont, {:ok, [request | requests]}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp apply_request_policies(policies, request, info) do
    record = request_to_record(request)
    JumpWire.Policy.apply_policies(policies, record, info)
  end

  defp request_to_record(request) do
    tables = %{
      {nil, "bigquery-public-data.usa_names.usa_1910_2013"} => [
        %{
          name: "state",
          namespace: nil,
          id: "bigquery-public-data.usa_names.usa_1910_2013",
          column: "state",
          column_id: "state"
        },
        %{
          name: "gender",
          namespace: nil,
          id: "bigquery-public-data.usa_names.usa_1910_2013",
          column: "gender",
          column_id: "gender"
        },
        %{
          name: "year",
          namespace: nil,
          id: "bigquery-public-data.usa_names.usa_1910_2013",
          column: "year",
          column_id: "year"
        },
        %{
          name: "name",
          namespace: nil,
          id: "bigquery-public-data.usa_names.usa_1910_2013",
          column: "name",
          column_id: "name"
        },
        %{
          name: "number",
          namespace: nil,
          id: "bigquery-public-data.usa_names.usa_1910_2013",
          column: "number",
          column_id: "number"
        }
      ]
    }

    schemas = %{
      "bigquery-public-data.usa_names.usa_1910_2013" => %{
        "name" => {"name", ["pii"]}
      }
    }

    default_namespace = nil

    %JumpWire.Record{
      data: %{},
      labels: %{},
      source: "bigquery",
      source_data: request.source,
      label_format: :key
    }
    |> merge_request_field_labels(request.select, :select, {tables, schemas}, default_namespace)
    |> merge_request_field_labels(request.update, :update, {tables, schemas}, default_namespace)
    |> merge_request_field_labels(request.delete, :delete, {tables, schemas}, default_namespace)
    |> merge_request_field_labels(request.insert, :insert, {tables, schemas}, default_namespace)
  end

  defp merge_request_field_labels(record, fields, type, {tables, schemas}, default_namespace) do
    fields
    |> Stream.flat_map(fn
      %{column: :wildcard, table: table, schema: namespace} ->
        # Find and return all fields for this table
        namespace = namespace || default_namespace
        Map.get(tables, {namespace, table}, [])

      %{column: col, table: table, schema: namespace} ->
        namespace = namespace || default_namespace
        find_field(tables, namespace, table, col)
    end)
    |> Stream.map(fn field ->
      # find any labels for this field
      schemas
      |> Map.get(field[:id], %{})
      |> Map.get(field[:column_id], {field[:column], []})
    end)
    |> Enum.reduce(record, fn {field, labels}, acc ->
      # update the record based on the fields being accessed
      acc
      |> Map.update!(:data, fn data -> Map.put(data, field, :query) end)
      |> Map.update!(:labels, fn l -> Map.put(l, field, labels) end)
      |> Map.update!(:attributes, fn attr ->
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        Enum.reduce(labels, attr, fn label, attr ->
          MapSet.put(attr, "#{type}:#{label}")
        end)
      end)
    end)
  end

  defp find_field(tables, namespace, table, col) do
    case Map.fetch(tables, {namespace, table}) do
      {:ok, fields} ->
        case Enum.find(fields, fn %{column: name} -> name == col end) do
          nil ->
            Logger.debug(
              "Could not find colummn #{col} in bigquery schema for table #{namespace}.#{table}"
            )

            []

          field ->
            [field]
        end

      _ ->
        Logger.debug(
          "No schema stored for bigquery table #{namespace}.#{table}, skipping field mapping"
        )

        []
    end
  end
end
