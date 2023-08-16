# WARNING: existing data in the table will be lost!

# This script only creates and queries DB records.
# https://www.getsynth.com/ is used for data generation

# CREATE TABLE IF NOT EXISTS users (
#     id SERIAL PRIMARY KEY,
#     first_name TEXT,
#     last_name TEXT,
#     account_id TEXT,
#     ssn TEXT,
#     username TEXT UNIQUE,
#     source TEXT
# );

org_id = JumpWire.Metadata.get_org_id()
database = "benchmarks"
table = "users"
num_records = 10_000

JumpWire.Phony.cleanup_jumpwire_data()
params = JumpWire.Phony.generate_db_proxy(:postgresql, org_id, database, table)

#Application.put_env(:jumpwire, :trace_proxy, true)
#{:ok, conn} = Postgrex.start_link(params.proxy)
# :timer.sleep(100)
# pid = Process.whereis(JumpWire.Proxy.Postgres.Client)
# Application.put_env(:jumpwire, :trace_proxy, false)

# insert test data
:timer.sleep(100)
{:ok, conn} = Postgrex.start_link(params.direct)
JumpWire.Phony.generate_records(conn, table, num_records: num_records)
GenServer.stop(conn)

reset_parsing = fn _input ->
  config = Application.get_env(:jumpwire, :proxy)
  |> Keyword.put(:parse_responses, true)
  |> Keyword.put(:parse_requests, true)
  Application.put_env(:jumpwire, :proxy, config)
end
disable_response_parsing = fn ->
  config = Application.get_env(:jumpwire, :proxy)
  |> Keyword.put(:parse_responses, false)
  Application.put_env(:jumpwire, :proxy, config)
end
disable_request_parsing = fn ->
  config = Application.get_env(:jumpwire, :proxy)
  |> Keyword.put(:parse_requests, false)
  Application.put_env(:jumpwire, :proxy, config)
end

pgb_params = Map.fetch!(params, :direct)
|> Keyword.merge(port: 6432)
params = Map.put(params, :pgbouncer, pgb_params)

select_fun = fn type, limit ->
  conn_params = Map.fetch!(params, type)
  |> Keyword.merge(queue_interval: 2_000)
  fn fields ->
    {:ok, conn} = Postgrex.start_link(conn_params)
    Postgrex.query!(conn, "select #{fields} from users limit #{limit}", [])
    GenServer.stop(conn)
  end
end

Benchee.run(
  %{
    "direct" => select_fun.(:direct, 100),
    "direct.no_limit" => select_fun.(:direct, num_records),
    "pgbouncer" => {
      select_fun.(:pgbouncer, 100),
      after_scenario: fn _ -> :timer.sleep(5000) end,
    },
    "pgbouncer.no_limit" => {
      select_fun.(:pgbouncer, num_records),
      after_scenario: fn _ -> :timer.sleep(5000) end,
    },
    "proxy" => select_fun.(:proxy, 100),
    "proxy.no_limit" => select_fun.(:proxy, num_records),
    "proxy.requests" => {
      select_fun.(:proxy, 100),
      before_scenario: fn input ->
        disable_response_parsing.()
        input
      end,
      after_scenario: reset_parsing,
    },
    "proxy.responses" => {
      select_fun.(:proxy, 100),
      before_scenario: fn input ->
        disable_request_parsing.()
        input
      end,
      after_scenario: reset_parsing,
    },
    "proxy.no_parsing" => {
      select_fun.(:proxy, 100),
      before_scenario: fn input ->
        disable_request_parsing.()
        disable_response_parsing.()
        input
      end,
      after_scenario: reset_parsing,
    },
    "proxy.requests.no_limit" => {
      select_fun.(:proxy, num_records),
      before_scenario: fn input ->
        disable_response_parsing.()
        input
      end,
      after_scenario: reset_parsing,
    },
    "proxy.responses.no_limit" => {
      select_fun.(:proxy, num_records),
      before_scenario: fn input ->
        disable_request_parsing.()
        input
      end,
      after_scenario: reset_parsing,
    },
    "proxy.no_parsing.no_limit" => {
      select_fun.(:proxy, num_records),
      before_scenario: fn input ->
        disable_request_parsing.()
        disable_response_parsing.()
        input
      end,
      after_scenario: reset_parsing,
    },
  },
  inputs: %{
    #"single_field" => "ssn",
    "all_fields" => "*",
  },
  time: 10, warmup: 0
)

# :fprof.apply(
#   &Postgrex.query!/3,
#   [unclassified_conn, "select ssn from users", []],
#   [procs: [pid]]
# )
# :fprof.profile()
# :fprof.analyse([dest: 'select_ssn.fprof'])
