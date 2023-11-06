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
  @type table_factor() :: Table.t() | Derived.t() | TableFunction.t() | UNNEST.t() | NestedJoin.t() | Pivot.t()

  @typedoc """
  https://docs.rs/sqlparser/latest/sqlparser/ast/enum.FunctionArgExpr.html
  """
  @type function_arg_expr() :: expr() | object_name() | :wildcard
  @type function_arg() :: Named.t() | function_arg_expr()

  typedstruct module: Named do
    field :name, Statement.Ident.t()
    field :arg, Statement.function_arg_expr()
  end

  @type object_name() :: [Ident.t()]
  @type non_block() :: :Nowait | :SkipLocked
  @type lock_type() :: :Share | :Update

  @type select_item()
  :: {:unnamed_expr, expr()}
  | ExprWithAlias.t()
  | {:qualified_wildcard, object_name(), WildcardAdditionalOptions.t()}
  | {:wildcard, WildcardAdditionalOptions.t()}

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
    field :locks, [Statement.LockClause.t()]
  end

  typedstruct module: Update do
    field :table, Statement.TableWithJoins.t()
    field :assignments, [Statement.Assignment.t()]
    field :from, [Statement.TableWithJoins.t()] | nil
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
    field :name, Statement.Ident.t()
    field :columns, [Statement.Ident.t()]
  end

  typedstruct module: TypedString do
    field :data_type, Statement.data_type()
    field :value, String.t()
  end

  typedstruct module: MapAccess do
    field :column, Statement.expr()
    field :keys, [Statement.expr()]
  end

  typedstruct module: JsonAccess do
    field :left, Statement.expr()
    field :operator, Statement.json_operator()
    field :right, Statement.expr()
  end

  typedstruct module: CompositeAccess do
    field :expr, Statement.expr()
    field :key, Statement.Ident.t()
  end

  typedstruct module: Function do
    field :name, Statement.object_name()
    field :args, [Statement.function_arg()]
    field :over, Statement.WindowSpec.t() | nil
    field :distinct, boolean()
    field :special, boolean()
    field :order_by, [Statement.OrderByExpr.t()]
  end

  typedstruct module: AggregateExpressionWithFilter do
    field :expr, Statement.expr()
    field :filter, Statement.expr()
  end

  typedstruct module: NamedFunctionArg do
    field :name, Statement.Ident.t()
    field :arg, Statement.function_arg_expr()
  end

  typedstruct module: Table do
    field :name, [Statement.Ident.t()]
    field :alias, Statement.TableAlias.t() | nil
    field :args, [Statement.function_arg()] | nil
    field :with_hints, [Statement.expr()]
    field :version, Statement.table_version() | nil
    field :partitions, [Statement.Ident.t()]
  end

  @type table_version() :: {:for_system_time_as_of, expr()}

  typedstruct module: Derived do
    field :lateral, boolean()
    field :subquery, Statement.Query.t()
    field :alias, Statement.TableAlias.t()
  end

  typedstruct module: TableFunction do
    field :expr, Statement.expr()
    field :alias, Statement.TableAlias.t() | nil
  end

  typedstruct module: UNNEST do
    field :alias, Statement.TableAlias.t() | nil
    field :array_exprs, [Statement.expr()]
    field :with_offset, boolean()
    field :with_offset_alias, Statement.Ident.t() | nil
  end

  typedstruct module: NestedJoin do
    field :table_with_joins, Statement.TableWithJoins.t()
    field :alias, Statement.TableAlias.t() | nil
  end

  # Only used by Snowflake
  typedstruct module: Pivot do
    field :name, Statement.object_name()
    field :table_alias, Statement.TableAlias.t() | nil
    field :aggregate_function, Statement.expr()
    field :value_column, [Statement.Ident.t()]
    field :pivot_values, [Statement.value()]
    field :pivot_alias, Statement.TableAlias.t() | nil
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
    field :cte_tables, [Statement.Cte.t()]
  end

  typedstruct module: OrderByExpr do
    field :expr, Statment.expr()
    field :asc, boolean()
    field :nulls_first, boolean() | nil
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
    field :lateral_col_alias, [Statement.Ident.t()]
    field :outer, boolean()
  end

  typedstruct module: DollarQuotedString do
    field :value, String.t()
    field :tag, String.t()
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
    field :id, [Statement.Ident.t()]
    field :value, Statement.expr()
  end

  typedstruct module: DoUpdate do
    field :assignments, [Statement.Assignment.t()]
    field :selection, Statement.expr() | nil
  end

  typedstruct module: OnConflict do
    field :conflict_target, [Statement.Ident.t()] | Statement.object_name()
    field :action, :do_nothing | Statement.DoUpdate.t()
  end

  ########################################
  # Top level query bodies
  ########################################

  @type set_expr()
  :: Select.t()
  | Query.t()
  | SetOperation.t()
  | Values.t()
  | Insert.t()
  | Table.t()

  typedstruct module: Select do
    field :distinct, boolean()
    field :top, Statement.Top.t()
    field :projection, Statement.select_item()
    field :into, Statement.SelectInto.t()
    field :from, [Statement.TableWithJoins.t()]
    field :lateral_views, [Statement.LateralView.t()]
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
  | {:pg_custom_binary_operator, [String.t()]}

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
  :: {:character, CharacterLength.t()}
  | {:char, CharacterLength.t()}
  | {:character_varying, CharacterLength.t()}
  | {:char_varying, CharacterLength.t()}
  | {:varchar, CharacterLength.t()}
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
  | {:custom, object_name(), [String.t()]}
  | {:array, data_type()}
  | {:enum, [String.t()]}
  | {:set, [String.t()]}

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

  @type list_agg_on_overflow() :: :error | Truncate.t()

  typedstruct module: Truncate do
    field :table_name, Statement.object_name()
    field :partitions, [Statement.expr()] | nil
    field :table, boolean()
  end

  typedstruct module: ListAgg do
    field :distinct, boolean()
    field :expr, Statement.expr()
    field :separator, Statement.expr()
    field :on_overflow, Statement.list_agg_on_overflow()
    field :within_group, [Statement.OrderByExpr.t()]
  end

  typedstruct module: ArrayAgg do
    field :distinct, boolean()
    field :expr, Statement.expr()
    field :order_by, Statement.OrderByExpr.t() | nil
    field :limit, Statement.expr() | nil
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

  typedstruct module: AnyOp do
    field :left, Statement.expr()
    field :compare_op, Statement.binary_operator()
    field :right, Statement.expr()
  end

  typedstruct module: AllOp do
    field :left, Statement.expr()
    field :compare_op, Statement.binary_operator()
    field :right, Statement.expr()
  end

  typedstruct module: UnaryOp do
    field :op, Statement.unary_operator()
    field :expr, Statement.expr()
  end

  typedstruct module: Cast do
    field :expr, Statement.expr()
    field :data_type, Statement.data_type()
  end

  typedstruct module: TryCast do
    field :expr, Statement.expr()
    field :data_type, Statement.data_type()
  end

  typedstruct module: SafeCast do
    field :expr, Statement.expr()
    field :data_type, Statement.data_type()
  end

  typedstruct module: AtTimeZone do
    field :timestamp, Statement.expr()
    field :time_zone, String.t()
  end

  typedstruct module: Extract do
    field :expr, Statement.expr()
    field :field, Statement.date_time_field()
  end

  typedstruct module: Ceil do
    field :expr, Statement.expr()
    field :field, Statement.date_time_field()
  end

  typedstruct module: Floor do
    field :expr, Statement.expr()
    field :field, Statement.date_time_field()
  end

  typedstruct module: Position do
    field :expr, Statement.expr()
    field :in, Statement.expr()
  end

  typedstruct module: Substring do
    field :expr, Statement.expr()
    field :special, boolean()
    field :substring_from, Statement.expr() | nil
    field :substring_for, Statement.expr() | nil
  end

  typedstruct module: Trim do
    field :expr, Statement.expr()
    field :trim_where, Statement.trim_where_field()
    field :trim_what, Statement.expr()
  end

  typedstruct module: Overlay do
    field :expr, Statement.expr()
    field :overlay_what, Statement.expr()
    field :overlay_from, Statement.expr()
    field :overlay_for, Statement.expr() | nil
  end

  typedstruct module: Collate do
    field :expr, Statement.expr()
    field :collation, Statement.object_name()
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

  typedstruct module: InSubquery do
    field :expr, Statement.expr()
    field :subquery, Statement.Query.t()
    field :negated, boolean()
  end

  typedstruct module: InUnnest do
    field :expr, Statement.expr()
    field :array_expr, Statement.expr()
    field :negated, boolean()
  end

  typedstruct module: Between do
    field :expr, Statement.expr()
    field :negated, boolean()
    field :low, Statement.expr()
    field :high, Statement.expr()
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

  typedstruct module: SimilarTo do
    field :negated, boolean()
    field :expr, Statement.expr()
    field :pattern, Statement.expr()
    field :escape_char, String.t()
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

  typedstruct module: Interval do
    field :value, Statement.expr()
    field :leading_field, Statement.date_time_field() | nil
    field :leading_precision, Statement.integer() | nil
    field :last_field, Statement.date_time_field() | nil
    field :fractional_seconds_precision, Statement.integer() | nil
  end

  # MySQL specific search
  # https://dev.mysql.com/doc/refman/8.0/en/fulltext-search.html#function_match
  typedstruct module: MatchAgainst do
    field :columns, [Statement.Ident.t()]
    field :match_value, Statement.value()
    field :opt_search_modifier, Statement.search_modifier() | nil
  end

  @type copy_target() :: :stdin | :stdout | %{filename: String.t()} | %{command: String.t()}
  @type copy_option()
  :: {:format, Ident.t()}
  | {:freeze, boolean()}
  | {:delimiter, char()}
  | {:null, String.t}
  | {:header, boolean()}
  | {:quote, char()}
  | {:escape, char()}
  | {:force_quote, [Ident.t()]}
  | {:force_not_null, [Ident.t()]}
  | {:force_null, [Ident.t()]}
  | {:encoding, String.t()}
  @type copy_legacy_option() :: :binary | {:delimiter, char()} | {:null, String.t()} | {:csv, [copy_legacy_csv_option()]}
  @type copy_legacy_csv_option()
  :: :header
  | {:quote, char()}
  | {:escape, char()}
  | {:force_quote, [Ident.t()]}
  | {:force_not_null, [Ident.t()]}

  typedstruct module: Copy do
    field :source, %{table_name: Statement.object_name(), columns: [Statement.Ident.t()]} | Statement.Query.t()
    field :to, boolean()
    field :target, Statement.copy_target()
    field :options, [Statement.copy_option()]
    field :legacy_options, [Statement.copy_legacy_csv_option()]
    field :values, [String.t() | nil]
  end

  typedstruct module: SqlOption do
    field :name, Statement.Ident.t()
    field :value, Statement.value()
  end

  typedstruct module: CreateView do
    field :or_replace, boolean()
    field :materialized, boolean()
    field :name, Statement.object_name()
    field :columns, Statement.Ident.t()
    field :query, Statement.Query.t()
    field :with_options, [Statement.SqlOption.t()]
    field :cluster_by, [Statement.Ident.t()]
  end

  @type expr()
  :: Ident.t
  | {:compound_identifier, [Ident.t]}
  | JsonAccess.t()
  | CompositeAccess.t()
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
  | InSubquery.t()
  | InUnnest.t()
  | Between.t()
  | BinaryOp.t()
  | Like.t()
  | ILike.t()
  | SimilarTo.t()
  | AnyOp.t()
  | AllOp.t()
  | UnaryOp.t()
  | Cast.t()
  | TryCast.t()
  | SafeCast.t()
  | AtTimeZone.t()
  | Extract.t()
  | Ceil.t()
  | Floor.t()
  | Position.t()
  | Substring.t()
  | Trim.t()
  | Overlay.t()
  | Collate.t()
  | {:nested, expr()}
  | value()
  | TypedString.t()
  | MapAccess.t()
  | Function.t()
  | AggregateExpressionWithFilter.t()
  | Case.t()
  | Exists.t()
  | {:subquery, Query.t()}
  | {:array_subquery, Query.t()}
  | ListAgg.t()
  | ArrayAgg.t()
  | {:grouping_sets, [[expr()]]}
  | {:cube, [[expr()]]}
  | {:rollup, [[expr()]]}
  | {:tuple, [expr()]}
  | ArrayIndex.t()
  | Array.t()
  | Interval.t()
  | MatchAgainst.t()
  | nil
end
