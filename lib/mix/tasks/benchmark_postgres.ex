defmodule Mix.Tasks.Jumpwire.Benchmark.Postgres do
  @moduledoc """
  Run benchmarks against the proxy path by creating and querying records.

  WARNING: any existing data in the table used for benchmarking will be lost!

  The benchmark script assumes that a PostgreSQL instance is running and reachable at `postgresql://postgres:postgres@localhost/`.

  ## Args:

  - `--count` - the number of rows to generate and query in the database. default: 10000
  - `--table` - the name of the DB table, will be created if it does not exist. default: `users`
  - `--database` - the name of the DB database. default: `benchmarks`
  """

  use Mix.Task
  @preferred_cli_env :prod

  @database "benchmarks"
  @table "users"
  @count 10_000

  @impl true
  def run(args) do
    {parsed, _args, _} = OptionParser.parse(
      args,
      aliases: [c: :count, d: :database, t: :table],
      strict: [count: :integer, database: :string, table: :string]
    )

    # Start JumpWire
    Logger.configure(level: :error)
    Application.put_env(:jumpwire, :config_dir, "/dev/null")
    Application.ensure_all_started(:jumpwire)

    org_id = JumpWire.Metadata.get_org_id()
    num_records = parsed[:count] || @count
    if num_records < 100, do: raise "--count must be at least 100"
    database = parsed[:database] || @database
    table = parsed[:table] || @table

    JumpWire.Phony.cleanup_jumpwire_data()
    params = JumpWire.Phony.generate_db_proxy(:postgresql, org_id, database, table)

    {:ok, conn} = Map.fetch!(params, :proxy)
    |> Postgrex.start_link()

    Postgrex.query!(conn, "select true", [])

    # insert test data
    :timer.sleep(100)
    {:ok, conn} = Postgrex.start_link(params.direct)
    create_table!(conn, table)
    JumpWire.Phony.generate_records(conn, table, num_records: num_records)
    GenServer.stop(conn)

    {:ok, direct_conn} = params[:direct]
    |> Keyword.merge(queue_interval: 2_000)
    |> Postgrex.start_link()

    {:ok, proxy_conn} = params[:proxy]
    |> Keyword.merge(queue_interval: 2_000)
    |> Postgrex.start_link()

    select_fun = fn conn ->
      fn limit ->
        Postgrex.query!(conn, "select * from #{table} limit #{limit}", [])
      end
    end

    Benchee.run(
      %{
        "direct" => select_fun.(direct_conn),
        "proxy.parse_all" => select_fun.(proxy_conn),
        "proxy.parse_requests" => {
          select_fun.(proxy_conn),
          before_scenario: fn input ->
            disable_response_parsing()
            input
          end,
          after_scenario: &reset_parsing/1,
        },
        "proxy.parse_responses" => {
          select_fun.(proxy_conn),
          before_scenario: fn input ->
            disable_request_parsing()
            input
          end,
          after_scenario: &reset_parsing/1,
        },
        "proxy.parse_none" => {
          select_fun.(proxy_conn),
          before_scenario: fn input ->
            disable_request_parsing()
            disable_response_parsing()
            input
          end,
          after_scenario: &reset_parsing/1,
        },
      },
      inputs: %{
        "limit none" => num_records,
        "limit 100" => 100,
      },
      time: 10, warmup: 0
    )
  end

  defp create_table!(conn, table) do
    query = """
    CREATE TABLE IF NOT EXISTS #{table} (
        id SERIAL PRIMARY KEY,
        first_name TEXT,
        last_name TEXT,
        account_id TEXT,
        ssn TEXT,
        username TEXT UNIQUE,
        source TEXT
    );
    """
    Postgrex.query!(conn, query, [])
  end

  defp reset_parsing(_input) do
    config = Application.get_env(:jumpwire, :proxy)
    |> Keyword.put(:parse_responses, true)
    |> Keyword.put(:parse_requests, true)
    Application.put_env(:jumpwire, :proxy, config)
  end

  defp disable_response_parsing() do
    config = Application.get_env(:jumpwire, :proxy)
    |> Keyword.put(:parse_responses, false)
    Application.put_env(:jumpwire, :proxy, config)
  end

  defp disable_request_parsing() do
    config = Application.get_env(:jumpwire, :proxy)
    |> Keyword.put(:parse_requests, false)
    Application.put_env(:jumpwire, :proxy, config)
  end
end
