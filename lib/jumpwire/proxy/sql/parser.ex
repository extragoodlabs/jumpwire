defmodule JumpWire.Proxy.SQL.Parser do
  @moduledoc """
  Parse a string containing a SQL query into an AST.
  """

  use Rustler, otp_app: :jumpwire, crate: :jumpwire_proxy_sql_parser
  alias JumpWire.Proxy.SQL.{Statement, Value, Field}
  alias JumpWire.Proxy.SQL.Statement.Ident
  alias JumpWire.Proxy.Request
  require Logger

  defmodule Traveler do
    @moduledoc """
    Structure for accumulating information about a SQL query as it is traversed.
    """

    use TypedStruct
    alias JumpWire.Proxy.Request

    typedstruct do
      field :request, Request.t(), default: %Request{}
      field :op, :select | :update | :delete | :insert, enforce: true
      field :tables, [String.t()], default: []
      field :table_aliases, map(), default: %{}
    end

    def get_table_alias(acc, field = %{schema: nil}) do
      Map.get(acc.table_aliases, field.table)
    end
    def get_table_alias(_acc, _field), do: nil

    def put_field(acc, field = %Field{table: nil}) do
      # map unqualified fields to every table.
      # this is necessary for getting all fields in a join
      Enum.reduce(acc.tables, acc, fn {schema, table}, acc ->
        schema = schema || JumpWire.Proxy.SQL.Parser.system_schema(table)
        field = %{field | schema: schema, table: table}
        put_field(acc, field)
      end)
    end

    def put_field(acc, field) do
      field =
        case get_table_alias(acc, field) do
          nil ->
            schema = resolve_schema(acc, field)
            %{field | schema: schema}

          {schema, table} ->
            %{field | schema: schema, table: table}
        end

      Map.update!(acc, :request, fn req ->
        Request.put_field(req, acc.op, field)
      end)
    end

    defp resolve_schema(acc, %Field{schema: nil, table: table}) do
      case Enum.find(acc.tables, fn {_, t} -> t == table end) do
        nil -> JumpWire.Proxy.SQL.Parser.system_schema(table)
        {schema, _} -> schema
      end
    end
    defp resolve_schema(_acc, %Field{schema: schema}), do: schema
  end

  def parse_postgresql(_query), do: :erlang.nif_error(:nif_not_loaded)
  def debug_parse(_query, _dialect), do: :erlang.nif_error(:nif_not_loaded)
  def to_sql(_query), do: :erlang.nif_error(:nif_not_loaded)
  def add_table_selection(_ref, _table, _left, _op, _right), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  In PostgreSQL, system tables names always being with `pg_`. Unqualified references will
  resolve to system tables.

  https://www.postgresql.org/docs/15/ddl-schemas.html
  """
  def system_schema("pg_" <> _), do: "pg_catalog"
  def system_schema(_), do: nil

  @doc """
  Take a SQL AST and convert it to a request object for processing.

  All fields that are accessed are recorded in the request.
  """
  def to_request(query = %Statement.Query{}) do
    acc = %Traveler{op: :select}
    |> find_fields(query)

    {:ok, acc.request}
  end

  def to_request(statement = %Statement.Update{}) do
    acc = %Traveler{op: :select}
    |> find_table(statement.from)
    |> find_table(statement.table)
    |> find_fields(statement.selection)

    acc = Enum.reduce(statement.assignments, acc, fn assignment, acc ->
      acc
      |> Map.put(:op, :update)
      |> find_fields(assignment)
    end)

    {:ok, acc.request}
  end

  def to_request(statement = %Statement.Delete{}) do
    acc = %Traveler{op: :select}
    |> find_table(statement.from)
    |> find_fields(statement.from)
    |> find_fields(statement.selection)

    # all fields on the table should be considered deleted
    acc = acc
    |> Map.put(:op, :delete)
    |> Traveler.put_field(%Field{column: :wildcard})

    {:ok, acc.request}
  end

  def to_request(statement = %Statement.Insert{}) do
    acc = %Traveler{op: :insert}
    |> find_table(statement.table_name)
    |> find_fields(statement.source)
    |> Map.put(:op, :select)
    |> find_fields(statement.returning)
    |> find_fields(statement.on)
    |> Map.put(:op, :insert)

    # parse inserts without explicit columns
    declared_field_count = Enum.count(statement.columns)
    max_field_count =
      case statement.source.body do
        %Statement.Values{rows: rows} ->
          rows
          |> Stream.map(&Enum.count/1)
          |> Enum.max()

        _ -> 0
      end

    acc =
      if max_field_count > declared_field_count do
        # this doesn't cover the edge case of inserting only some columns
        # eg, the table declares (a, b, c) but the query only inserts
        # (a, b)
        Traveler.put_field(acc, %Field{column: :wildcard})
      else
        Enum.reduce(statement.columns, acc, fn col, acc ->
          find_fields(acc, col)
        end)
      end

    {:ok, acc.request}
  end

  def to_request(%Statement.SetVariable{}), do: {:ok, %Request{}}
  def to_request(%Statement.SetTimeZone{}), do: {:ok, %Request{}}

  def to_request(_), do: {:error, :invalid}

  def find_fields(acc, query = %Statement.Query{}) do
    acc
    |> find_fields(query.with)
    |> find_fields(query.body)
  end

  def find_fields(acc, query = %Statement.SetOperation{}) do
    acc
    |> find_fields(query.left)
    |> find_fields(query.right)
  end

  def find_fields(acc, select = %Statement.Select{}) do
    %{op: op, tables: tables} = acc

    acc = acc
    |> Map.put(:tables, [])
    |> find_table(select.from)
    |> Map.put(:op, :select)
    |> find_fields(select.from)

    select.projection
    |> Enum.reduce(acc, fn name, acc ->
      find_fields(acc, name)
    end)
    |> find_fields(select.selection)
    |> Map.put(:op, op)
    |> Map.put(:tables, tables)
  end

  def find_fields(acc, %Statement.With{cte_tables: tables}) do
    Enum.reduce(tables, acc, fn table, acc -> find_fields(acc, table) end)
  end

  def find_fields(acc, cte = %Statement.Cte{}) do
    acc
    |> find_table(cte.from)
    |> find_fields(cte.query)
  end

  def find_fields(acc, %Statement.BinaryOp{left: left, right: right}) do
    op = acc.op
    acc
    |> find_fields(left)
    |> Map.put(:op, :select)
    |> find_fields(right)
    |> Map.put(:op, op)
  end

  def find_fields(acc, expr = %Statement.MapAccess{}) do
    acc = find_fields(acc, expr.column)
    Enum.reduce(expr.keys, acc, fn key, acc -> find_fields(acc, key) end)
  end

  def find_fields(acc, %Statement.JsonAccess{left: left, right: right}) do
    acc
    |> find_fields(left)
    |> find_fields(right)
  end

  def find_fields(acc, %Statement.UnaryOp{expr: expr}) do
    find_fields(acc, expr)
  end

  def find_fields(acc, %Statement.Exists{subquery: query}) do
    find_fields(acc, query)
  end

  def find_fields(acc, %Statement.InList{expr: expr, list: values}) do
    Enum.reduce(values, acc, fn val, acc -> find_fields(acc, val) end)
    |> find_fields(expr)
  end

  def find_fields(acc, %Statement.Like{expr: expr}) do
    find_fields(acc, expr)
  end

  def find_fields(acc, %Statement.ILike{expr: expr}) do
    find_fields(acc, expr)
  end

  def find_fields(acc, %Statement.Assignment{value: value, id: idents}) do
    [table | _] = tables = acc.tables
    acc
    |> Map.put(:op, :select)
    |> find_fields(value)
    |> Map.put(:op, :update)
    # updates can't be on any joined tables
    |> Map.put(:tables, [table])
    |> find_fields(idents)
    |> Map.put(:tables, tables)
  end

  def find_fields(acc, %Statement.Function{args: args}) do
    Enum.reduce(args, acc, fn arg, acc ->
      find_fields(acc, arg)
    end)
  end

  def find_fields(acc, %Statement.Case{conditions: conditions, results: results, else_result: else_result}) do
    Stream.concat(conditions, results)
    |> Enum.reduce(acc, fn c, acc -> find_fields(acc, c) end)
    |> find_fields(else_result)
  end

  def find_fields(acc, %Statement.WildcardAdditionalOptions{}) do
    Traveler.put_field(acc, %Field{column: :wildcard})
  end

  def find_fields(acc, %Statement.ExprWithAlias{expr: expr}) do
    find_fields(acc, expr)
  end

  def find_fields(acc, %Statement.TableWithJoins{joins: joins}) do
    Enum.reduce(joins, acc, fn join, acc -> find_fields(acc, join) end)
  end

  def find_fields(acc, [table = %Statement.TableWithJoins{} | rest]) do
    acc |> find_fields(table) |> find_fields(rest)
  end

  def find_fields(acc, %Statement.Join{join_operator: :none}), do: acc
  def find_fields(acc, %Statement.Join{join_operator: :natural}), do: acc
  def find_fields(acc, %Statement.Join{join_operator: expr}) do
    find_fields(acc, expr)
  end

  def find_fields(acc, %Ident{value: value}) do
    Traveler.put_field(acc, %Field{column: value})
  end
  def find_fields(acc, [%Ident{value: value}]) do
    Traveler.put_field(acc, %Field{column: value})
  end
  def find_fields(acc, [%Ident{value: table}, %Ident{value: col}]) do
    field = %Field{column: col, table: table}
    Traveler.put_field(acc, field)
  end
  def find_fields(acc, [%Ident{value: schema}, %Ident{value: table}, %Ident{value: col}]) do
    field = %Field{column: col, table: table, schema: schema}
    Traveler.put_field(acc, field)
  end

  def find_fields(acc, {:qualified_wildcard, name, _options}) do
    {schema, table} =
      case name do
        [%Ident{value: schema}, %Ident{value: table}] -> {schema, table}
        [%Ident{value: table}] -> {nil, table}
      end
    field = %Field{column: :wildcard, table: table, schema: schema}
    Traveler.put_field(acc, field)
  end

  def find_fields(acc, index = %Statement.ArrayIndex{}) do
    index.indexes
    |> Enum.reduce(acc, fn i, acc -> find_fields(acc, i) end)
    |> find_fields(index.obj)
  end

  def find_fields(acc, %Statement.ArrayAgg{expr: expr, order_by: nil}) do
    find_fields(acc, expr)
  end

  def find_fields(acc, %Statement.ArrayAgg{expr: expr, order_by: order_by}) do
    order_by
    |> Enum.reduce(acc, fn order, acc -> find_fields(acc, order.expr) end)
    |> find_fields(expr)
  end

  def find_fields(acc, %Statement.Collate{expr: expr}), do: find_fields(acc, expr)
  def find_fields(acc, %Statement.Cast{expr: expr}), do: find_fields(acc, expr)
  def find_fields(acc, %Statement.TryCast{expr: expr}), do: find_fields(acc, expr)
  def find_fields(acc, %Statement.SafeCast{expr: expr}), do: find_fields(acc, expr)
  def find_fields(acc, %Statement.Extract{expr: expr}), do: find_fields(acc, expr)
  def find_fields(acc, %Statement.Ceil{expr: expr}), do: find_fields(acc, expr)
  def find_fields(acc, %Statement.Floor{expr: expr}), do: find_fields(acc, expr)

  def find_fields(acc, query = %Statement.Position{}) do
    acc
    |> find_fields(query.expr)
    |> find_fields(query.in)
  end

  def find_fields(acc, query = %Statement.InList{}) do
    acc = find_fields(acc, query.expr)
    Enum.reduce(query.list, acc, fn expr, acc -> find_fields(acc, expr) end)
  end

  def find_fields(acc, query = %Statement.InSubquery{}) do
    acc
    |> find_fields(query.expr)
    |> find_fields(query.subquery)
  end

  def find_fields(acc, query = %Statement.InUnnest{}) do
    acc
    |> find_fields(query.expr)
    |> find_fields(query.array_expr)
  end

  def find_fields(acc, %Statement.Trim{expr: expr}), do: find_fields(acc, expr)

  def find_fields(acc, query = %Statement.Substring{}) do
    acc
    |> find_fields(query.expr)
    |> find_fields(query.substring_for)
    |> find_fields(query.substring_from)
  end

  def find_fields(acc, query = %Statement.AnyOp{}) do
    acc
    |> find_fields(query.left)
    |> find_fields(query.right)
  end

  def find_fields(acc, query = %Statement.AllOp{}) do
    acc
    |> find_fields(query.left)
    |> find_fields(query.right)
  end

  def find_fields(acc, :wildcard) do
    Traveler.put_field(acc, %Field{column: :wildcard})
  end

  def find_fields(acc, %Statement.Array{elem: elem}) do
    Enum.reduce(elem, acc, fn expr, acc -> find_fields(acc, expr) end)
  end

  def find_fields(acc, query = %Statement.OnConflict{}) do
    Enum.reduce(query.conflict_target, acc, fn expr, acc -> find_fields(acc, expr) end)
    |> find_fields(query.action)
  end
  def find_fields(acc, :do_nothing), do: acc
  def find_fields(acc, "do_nothing"), do: acc
  def find_fields(acc, query = %Statement.DoUpdate{}) do
    op = acc.op
    acc = Map.put(acc, :op, :update)
    acc = Enum.reduce(query.assignments, acc, fn expr, acc -> find_fields(acc, expr) end)

    acc =
      case query.selection do
        nil -> acc
        selection ->
          acc = Map.put(acc, :op, :select)
          Enum.reduce(selection, acc, fn expr, acc -> find_fields(acc, expr) end)
      end

    Map.put(acc, :op, op)
  end

  def find_fields(acc, expr = %Statement.SimilarTo{}) do
    acc
    |> find_fields(expr.pattern)
    |> find_fields(expr.expr)
  end

  def find_fields(acc, query = %Statement.Overlay{}) do
    acc
    |> find_fields(query.expr)
    |> find_fields(query.overlay_what)
    |> find_fields(query.overlay_from)
    |> find_fields(query.overlay_for)
  end

  def find_fields(acc, query = %Statement.AggregateExpressionWithFilter{}) do
    acc
    |> find_fields(query.expr)
    |> find_fields(query.filter)
  end

  def find_fields(acc, %Statement.MatchAgainst{columns: cols}), do: find_fields(acc, cols)
  def find_fields(acc, %Statement.CompositeAccess{expr: expr}), do: find_fields(acc, expr)

  def find_fields(acc, [expr]), do: find_fields(acc, expr)

  def find_fields(acc, %Statement.Values{}), do: acc
  def find_fields(acc, %Statement.Interval{}), do: acc
  def find_fields(acc, []), do: acc
  def find_fields(acc, nil), do: acc
  def find_fields(acc, data) when is_binary(data), do: acc

  def find_fields(acc, statement) do
    # Check if this is a simple value. If not, it is a statement that
    # the parser does not yet support.
    case Value.from_expr(statement) do
      {:ok, _value} -> acc
      _ ->
        Logger.warn("Unsupported statement: #{inspect statement}")
        acc
    end
  end

  def find_table(acc, tables) when is_list(tables) do
    Enum.reduce(tables, acc, fn table, acc -> find_table(acc, table) end)
  end

  def find_table(acc, %Statement.Join{relation: relation}) do
    find_table(acc, relation)
  end

  def find_table(acc, %Statement.TableWithJoins{relation: table, joins: joins}) do
    joins
    |> Enum.reduce(acc, fn join, acc -> find_table(acc, join) end)
    |> find_table(table)
  end

  def find_table(acc, %Statement.Table{name: name, alias: table_alias}) do
    {schema, table} =
      case name do
        [%Ident{value: table}] -> {system_schema(table), table}
        [%Ident{value: schema}, %Ident{value: table}] -> {schema, table}
      end

    acc
    |> Map.update!(:tables, fn t -> [{schema, table} | t] end)
    |> put_table_alias(table_alias)
  end
  def find_table(acc, %Statement.TableFunction{expr: expr, alias: table_alias}) do
    acc
    |> find_table(expr)
    |> put_table_alias(table_alias)
  end
  def find_table(acc, %Statement.NestedJoin{table_with_joins: expr, alias: table_alias}) do
    acc
    |> find_table(expr)
    |> put_table_alias(table_alias)
  end
  def find_table(acc, expr = %Statement.UNNEST{}) do
    acc
    |> find_fields(expr.array_exprs)
    |> put_table_alias(expr.alias)
  end
  def find_table(acc, %Statement.Derived{subquery: expr, alias: table_alias}) do
    acc
    |> find_table(expr)
    |> find_fields(expr)
    |> Map.update!(:tables, fn t -> [{nil, :derived} | t] end)
    |> put_table_alias(table_alias)
  end
  def find_table(acc, %Ident{value: table}) do
    Map.update!(acc, :tables, fn t -> [{nil, table} | t] end)
  end
  def find_table(acc, [%Ident{value: schema}, %Ident{value: table}]) do
    Map.update!(acc, :tables, fn t -> [{schema, table} | t] end)
  end
  def find_table(acc, _), do: %{acc | tables: []}

  def put_table_alias(acc, nil), do: acc
  def put_table_alias(acc, %Statement.TableAlias{name: %Ident{value: name}}) do
    [table | _] = acc.tables
    Map.update!(acc, :table_aliases, fn aliases ->
      Map.put(aliases, name, table)
    end)
  end
end
