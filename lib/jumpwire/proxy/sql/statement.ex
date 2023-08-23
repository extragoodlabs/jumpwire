defmodule JumpWire.Proxy.SQL.Statement do
  @moduledoc """
  Structures defined by the [sqlparser AST](https://docs.rs/sqlparser/latest/sqlparser/ast/enum.Statement.html).

  This is not comprehensive, but defines the ones used by JumpWire to improve
  ergonomics when working with SQL queries through the Rust NIF.
  """

  use TypedStruct
  alias __MODULE__

  @typedoc """
  https://docs.rs/sqlparser/latest/sqlparser/ast/enum.TableFactor.html
  """
  @type table_factor() :: Table.t() | any()

  @typedoc """
  https://docs.rs/sqlparser/latest/sqlparser/ast/enum.FunctionArgExpr.html
  """
  @type function_arg_expr() :: any()

  @type function_arg()
  :: {:named, %{name: Ident.t, arg: function_arg_expr()}}
  | {:unnamed, function_arg_expr()}

  @type object_name() :: [Ident.t]
  @type non_block() :: :Nowait | :SkipLocked
  @type lock_type() :: :Share | :Update

  @type select_item()
  :: {:unnamed_expr, expr()}
  | ExprWithAlias.t
  | {:qualified_wildcard, object_name(), WildcardAdditionalOptions.t}
  | {:wildcard, WildcardAdditionalOptions.t}

  typedstruct module: ExprWithAlias do
    field :expr, Statement.expr()
    field :alias, Statement.Ident.t()
  end

  typedstruct module: Query do
    field :with, Statement.With.t() | nil
    field :body, Statement.set_expr()
    field :order_by, [Statement.OrderByExpr.t()]
    field :limit, Statement.expr() | nil
    field :offset, Statement.Offset.t() | nil
    field :fetch, Statement.Fetch.t() | nil
    field :locks, [Statement.LockClause.t]
  end

  typedstruct module: Update do
    field :table, Statement.TableWithJoins.t
    field :assignments, [Statement.Assignment.t]
    field :from, [Statement.TableWithJoins.t] | nil
    field :selection, Statement.expr()
    field :returning, [Statement.select_item()] | nil
  end

  typedstruct module: Ident do
    field :value, String.t()
    field :quote_style, String.t() | nil  # a single character
  end

  typedstruct module: IdentWithAlias do
    field :ident, Statement.Ident.t()
    field :alias, Statement.Ident.t()
  end

  typedstruct module: TableAlias do
    field :name, Statement.Ident.t
    field :columns, [Statement.Ident.t]
  end

  typedstruct module: Function do
    field :name, Statement.object_name()
    field :args, [Statement.function_arg()]
    field :over, Statement.WindowSpec.t() | nil
    field :distinct, boolean()
    field :special, boolean()
    field :order_by, [Statement.OrderByExpr.t()]
  end

  typedstruct module: NamedFunctionArg do
    field :name, Statement.Ident.t
    field :arg, Statement.function_arg_expr()
  end

  typedstruct module: Table do
    field :name, [Statement.Ident.t]
    field :alias, Statement.TableAlias.t
    field :args, [Statement.function_arg()]
    field :with_hints, [Statement.expr()]
  end

  typedstruct module: Join do
    field :relation, Statement.table_factor()
    field :join_operator, Statement.join_operator()
  end

  @type join_operator() :: join_constraint() | :cross_join | :cross_apply | :outer_apply
  @type join_constraint() :: expr() | [Ident.t()] | :natural | :none

  typedstruct module: TableWithJoins do
    field :relation, Statement.table_factor()
    field :joins, [Statement.Join.t()]
  end

  typedstruct module: ExceptSelectItem do
    field :first_item, Statement.Ident.t()
    field :additional_elements, [Statement.Ident.t()]
  end

  typedstruct module: ReplaceSelectElement do
    field :expr, Statement.expr()
    field :column_name, Statement.Ident.t()
    field :as_keyword, boolean()
  end

  typedstruct module: WildcardAdditionalOptions do
    field :opt_exclude, {:single, Statement.Ident.t()} | {:multiple, [Statement.Ident.t()]} | nil
    field :opt_except, Statement.ExceptSelectItem.t() | nil
    field :opt_rename, {:single, Statement.IdentWithAlias.t()} | {:multiple, [Statement.IdentWithAlias.t()]} | nil
    field :opt_replace, [Statement.ReplaceSelectElement.t()] | nil
  end

  typedstruct module: Cte do
    field :alias, Statement.TableAlias.t()
    field :query, Statement.Query.t()
    field :from, Statement.Ident.t() | nil
  end

  typedstruct module: With do
    field :recursive, boolean()
    field :cte_tables, [Statement.Cte.t]
  end

  typedstruct module: OrderByExpr do
    field :expr, Statment.expr()
    field :asc, boolean()
    field :nulls_first, boolean()
  end

  typedstruct module: Offset do
    field :value, Statement.expr()
    field :rows, :none | :row | :rows
  end

  typedstruct module: Fetch do
    field :with_ties, boolean()
    field :percent, boolean()
    field :quantity, Statement.expr()
  end

  typedstruct module: LockClause do
    field :lock_type, Statement.lock_type()
    field :of, Statement.object_name()
    field :nonblock, Statement.non_block()
  end

  typedstruct module: Top do
    field :with_ties, boolean()
    field :percent, boolean()
    field :quantity, Statement.expr()
  end

  typedstruct module: SelectInto do
    field :temporary, boolean()
    field :unlogged, boolean()
    field :table, boolean()
    field :name, Statement.object_name()
  end

  typedstruct module: LateralView do
    field :lateral_view, Statement.expr()
    field :lateral_view_name, Statement.object_name()
    field :lateral_col_alias, [Statement.Ident.t]
    field :outer, boolean()
  end

  typedstruct module: DollarQuotedString do
    field :value, String.t
    field :tag, String.t
  end

  typedstruct module: WindowSpec do
    field :partition_by, [Statement.expr()]
    field :order_by, [Statement.OrderByExpr.t()]
    field :window_frame, Statement.WindowFrame.t() | nil
  end

  @type window_frame_units() :: :rows | :range | :groups
  @type window_frame_bound() :: :current_row | {:preceding, expr()} | {:following, expr()}

  typedstruct module: WindowFrame do
    field :units, Statement.window_frame_units()
    field :start_bound, Statement.window_frame_bound()
    field :end_bound, Statement.window_frame_bound()
  end

  typedstruct module: Assignment do
    field :id, [Statement.Ident.t]
    field :value, Statement.expr()
  end

  typedstruct module: DoUpdate do
    field :assignments, [Statement.Assignment.t]
    field :selection, Statement.expr()
  end

  typedstruct module: OnConflict do
    field :conflict_target, {:columns, [Statement.Ident.t()]} | {:on_constraint, Statement.object_name()}
    field :action, :do_nothing | {:do_update, Statement.DoUpdate.t()}
  end

  ########################################
  # Top level query bodies
  ########################################

  @type set_expr()
  :: Select.t
  | Query.t
  | SetOperation.t
  | Values.t
  | Insert.t
  | Table.t

  typedstruct module: Select do
    field :distinct, boolean()
    field :top, Statement.Top.t
    field :projection, Statement.select_item()
    field :into, Statement.SelectInto.t
    field :from, [Statement.TableWithJoins.t]
    field :lateral_views, [Statement.LateralView.t]
    field :selection, Statement.expr()
    field :group_by, [Statement.expr()]
    field :cluster_by, [Statement.expr()]
    field :distribute_by, [Statement.expr()]
    field :sort_by, [Statement.expr()]
    field :having, Statement.expr()
    field :named_window, [{Statement.Ident.t(), Statement.WindowSpec.t()}]
    field :qualify, Statement.expr()
  end

  @type set_operator() :: :union | :except | :intersect
  @type set_quantifier() :: :all | :distinct | :none

  typedstruct module: SetOperation do
    field :op, Statement.set_operator()
    field :set_quantifier, Statement.set_quantifier()
    field :left, Statement.set_expr()
    field :right, Statement.set_expr()
  end

  typedstruct module: Insert do
    field :or, :rollback | :abort | :fail | :ignore | :replace | nil
    field :into, boolean()
    field :table_name, Statement.object_name()
    field :columns, [Statement.Ident.t()]
    field :overwrite, boolean()
    field :source, Statement.Query.t()
    field :partitioned, [Statement.expr()] | nil
    field :after_columns, [Statement.Ident.t]
    field :table, boolean()
    field :on, {:duplicate_key_update, Statement.Assignment.t()} | Statement.OnConflict.t() | nil
    field :returning, [Statement.select_item()] | nil
  end

  typedstruct module: Delete do
    field :tables, [Statement.object_name()]
    field :from, [Statement.TableWithJoins.t()]
    field :using, [Statement.TableWithJoins.t()] | nil
    field :selection, Statement.expr()
    field :returning, [Statement.select_item()] | nil
  end

  typedstruct module: Values do
    field :explicit_row, boolean()
    field :rows, [[Statement.expr()]]
  end

  ########################################
  # Expressions and base types
  # https://docs.rs/sqlparser/latest/sqlparser/ast/enum.Expr.html
  ########################################

  @type value()
  :: {:number, String.t(), boolean()}
  | String.t()
  | DollarQuotedString.t()
  | boolean()
  | :null

  @type json_operator()
  :: :arrow
  | :long_arrow
  | :hash_arrow
  | :hash_long_arrow
  | :colon
  | :at_arrow
  | :arrow_at
  | :hash_minus
  | :at_question
  | :at_at

  @type binary_operator()
  :: :plus
  | :minus
  | :multiply
  | :divide
  | :modulo
  | :string_concat
  | :gt
  | :lt
  | :gt_eq
  | :lt_eq
  | :spaceship
  | :eq
  | :not_eq
  | :and
  | :or
  | :xor
  | :bitwise_or
  | :bitwise_and
  | :bitwise_xor
  | :pg_bitwise_xor
  | :pg_bitwise_shift_left
  | :pg_bitwise_shift_right
  | :pg_regex_match
  | :pg_regex_i_match
  | :pg_regex_not_match
  | :pg_regex_not_i_match
  | {:pg_custom_binary_operator, [String.t]}

  @type unary_operator()
  :: :plus
  | :minus
  | :not
  | :pg_bitwise_not
  | :pg_square_root
  | :pg_cube_root
  | :pg_postfix_factorial
  | :pg_prefix_factorial
  | :pg_abs

  @type char_length_units() :: :characters | :octets
  @type exact_number_info() :: :none | {:precision, integer()} | {:precision_and_scale, integer(), integer()}
  @type timezone_info() :: :none | :with_time_zone | :without_time_zone | :tz

  typedstruct module: CharacterLength do
    field :length, integer()
    field :unit, Statement.char_length_units()
  end

  @type data_type()
  :: {:character, CharacterLength.t}
  | {:char, CharacterLength.t}
  | {:character_varying, CharacterLength.t}
  | {:char_varying, CharacterLength.t}
  | {:varchar, CharacterLength.t}
  | {:nvarchar, integer()}
  | :uuid
  | {:character_large_object, integer()}
  | {:char_large_object, integer()}
  | {:clob, integer()}
  | {:binary, integer()}
  | {:varbinary, integer()}
  | {:blob, integer()}
  | {:numeric, exact_number_info()}
  | {:decimal, exact_number_info()}
  | {:dec, exact_number_info()}
  | {:float, integer()}
  | {:tiny_int, integer()}
  | {:unsigned_tiny_int, integer()}
  | {:small_int, integer()}
  | {:unsigned_small_int, integer()}
  | {:medium_int, integer()}
  | {:unsigned_medium_int, integer()}
  | {:int, integer()}
  | {:integer, integer()}
  | {:unsigned_int, integer()}
  | {:unsigned_integer, integer()}
  | {:big_int, integer()}
  | {:unsigned_big_int, integer()}
  | :real
  | :double
  | :double_precision
  | :boolean
  | :date
  | {:time, integer(), timezone_info()}
  | {:datetime, integer()}
  | {:timestamp, integer(), timezone_info()}
  | :interval
  | :regclass
  | :text
  | :string
  | :bytea
  | {:custom, object_name(), [String.t]}
  | {:array, data_type()}
  | {:enum, [String.t]}
  | {:set, [String.t]}

  @type date_time_field()
  :: :year
  | :month
  | :week
  | :day
  | :date
  | :hour
  | :minute
  | :second
  | :century
  | :decade
  | :dow
  | :doy
  | :epoch
  | :isodow
  | :isoyear
  | :julian
  | :microsecond
  | :microseconds
  | :millenium
  | :millennium
  | :millisecond
  | :milliseconds
  | :nanosecond
  | :nanoseconds
  | :quarter
  | :timezone
  | :timezone_hour
  | :timezone_minute
  | :no_date_time

  @type trim_where_field() :: :both | :leading | :trailing

  @type list_agg_on_overflow() :: :error | {:truncate, %{filler: expr(), with_count: boolean()}}

  typedstruct module: ListAgg do
    field :distinct, boolean()
    field :expr, Statement.expr()
    field :separator, Statement.expr()
    field :on_overflow, Statement.list_agg_on_overflow()
    field :within_group, [Statement.OrderByExpr.t]
  end

  typedstruct module: ArrayAgg do
    field :distinct, boolean()
    field :expr, Statement.expr()
    field :order_by, Statement.OrderByExpr.t()
    field :limit, Statement.expr()
    field :within_group, boolean()
  end

  typedstruct module: ArrayIndex do
    field :obj, Statement.expr()
    field :indexes, [Statement.expr()]
  end

  typedstruct module: Array do
    field :elem, [Statement.expr()]
    field :named, boolean()
  end

  @type search_modifier()
  :: :in_natural_language_mode
  | :in_natural_language_mode_with_query_expansion
  | :in_boolean_mode
  | :with_query_expansion

  typedstruct module: BinaryOp do
    field :left, Statement.expr()
    field :op, Statement.binary_operator()
    field :right, Statement.expr()
  end

  typedstruct module: UnaryOp do
    field :op, Statement.unary_operator()
    field :expr, Statement.expr()
  end

  typedstruct module: Case do
    field :operand, Statement.expr() | nil
    field :conditions, [Statement.expr()]
    field :results, [Statement.expr()]
    field :else_result, Statement.expr() | nil
  end

  typedstruct module: Exists do
    field :subquery, Statement.Query.t()
    field :negated, boolean()
  end

  typedstruct module: InList do
    field :expr, Statement.expr()
    field :list, [Statement.expr()]
    field :negated, boolean()
  end

  typedstruct module: Like do
    field :negated, boolean()
    field :expr, Statement.expr()
    field :pattern, Statement.expr()
    field :escape_char, String.t() | nil
  end

  typedstruct module: ILike do
    field :negated, boolean()
    field :expr, Statement.expr()
    field :pattern, Statement.expr()
    field :escape_char, String.t() | nil
  end

  typedstruct module: SetVariable do
    field :local, boolean()
    field :hivevar, boolean()
    field :variable, Statement.object_name()
    field :value, [Statement.expr()]
  end

  typedstruct module: SetTimeZone do
    field :local, boolean()
    field :value, Statement.expr()
  end

  @type expr()
  :: Ident.t
  | {:compound_identifier, [Ident.t]}
  | {:json_access, %{left: expr(), operator: json_operator(), right: expr()}}
  | {:composite_access, %{expr: expr(), key: Ident.t}}
  | {:is_false, expr()}
  | {:is_not_false, expr()}
  | {:is_true, expr()}
  | {:is_not_true, expr()}
  | {:is_null, expr()}
  | {:is_not_null, expr()}
  | {:is_unknown, expr()}
  | {:is_not_unknown, expr()}
  | {:is_distinct_from, expr(), expr()}
  | {:is_not_distinct_from, expr(), expr()}
  | InList.t()
  | {:in_subquery, %{expr: expr(), subquery: Query.t, negated: boolean()}}
  | {:in_unnest, %{expr: expr(), array_expr: expr(), negated: boolean}}
  | {:between, %{expr: expr(), negated: boolean(), low: expr(), high: expr()}}
  | BinaryOp.t()
  | Like.t()
  | ILike.t()
  | {:similar_to, %{negated: boolean(), expr: expr(), pattern: expr(), escape_char: String.t}}
  | {:any_op, expr()}
  | {:all_op, expr()}
  | UnaryOp.t()
  | {:cast, %{expr: expr(), data_type: data_type()}}
  | {:try_cast, %{expr: expr(), data_type: data_type()}}
  | {:safe_cast, %{expr: expr(), data_type: data_type()}}
  | {:at_time_zone, %{timestamp: expr(), time_zone: String.t}}
  | {:extract, %{field: date_time_field(), expr: expr()}}
  | {:ceil, %{expr: expr(), field: date_time_field()}}
  | {:floor, %{expr: expr(), field: date_time_field()}}
  | {:position, %{expr: expr(), in: expr()}}
  | {:substring, %{expr: expr(), substring_from: expr(), substring_for: expr()}}
  | {:trim, %{expr: expr(), trim_where: trim_where_field(), trim_what: expr()}}
  | {:overlay, %{expr: expr(), overlay_what: expr(), overlay_from: expr(), overlay_for: expr()}}
  | {:collate, %{expr: expr(), collation: object_name()}}
  | {:nested, expr()}
  | value()
  | {:typed_string, %{data_type: data_type(), value: String.t()}}
  | {:map_access, %{column: expr(), keys: [expr()]}}
  | Function.t()
  | {:aggregate_expression_with_filter, %{expr: expr(), filter: expr()}}
  | Case.t()
  | Exists.t()
  | {:subquery, Query.t}
  | {:array_subquery, Query.t}
  | ListAgg.t()
  | ArrayAgg.t()
  | {:grouping_sets, [[expr()]]}
  | {:cube, [[expr()]]}
  | {:rollup, [[expr()]]}
  | {:tuple, [expr()]}
  | ArrayIndex.t()
  | Array.t()
  | {:interval, %{
        value: expr(),
        leading_field: date_time_field(),
        leading_precision: integer(),
        last_field: date_time_field(),
        fractional_seconds_precision: integer()
     }}
  | {:match_against, %{columns: [Ident.t], match_value: value(), opt_search_modifier: search_modifier()}}
  | nil
end
