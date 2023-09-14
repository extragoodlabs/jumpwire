defmodule JumpWire.Proxy.SQL.ParserTest do
  use ExUnit.Case, async: true
  alias JumpWire.Proxy.SQL.{Parser, Field}
  alias JumpWire.Proxy.SQL.Statement.{Ident, WildcardAdditionalOptions, BinaryOp, Query, Table, TableWithJoins, Select, Function, Update, Delete, Insert}

  describe "postgresql" do
    test "invalid statement" do
      assert {:error, {:parser_error, _}} = Parser.parse_postgresql("whabadabadoooooo")
    end

    test "wildcard select" do
      assert {:ok, [statement]} = Parser.parse_postgresql("select * from foo;")
      assert_table_select(statement, "foo")
      assert [
        %WildcardAdditionalOptions{},
      ] = statement.body.projection

      assert {:ok, request} = Parser.to_request(statement)
      assert request.select == [
        %Field{column: :wildcard, table: "foo"},
      ]
    end

    test "column select" do
      assert {:ok, [statement]} = Parser.parse_postgresql("select baz, ya from foo;")
      assert_table_select(statement, "foo")
      assert [
        %Ident{value: "baz"},
        %Ident{value: "ya"},
      ] = statement.body.projection

      assert {:ok, request} = Parser.to_request(statement)
      assert request.select == [
        %Field{column: "ya", table: "foo"},
        %Field{column: "baz", table: "foo"},
      ]
    end

    test "complex select" do
      query = "SELECT a, b, 123, myfunc(b) \
           FROM table_1 \
           WHERE a > b AND b <= 100 \
           ORDER BY a DESC, b"
      assert {:ok, [statement]} = Parser.parse_postgresql(query)
      assert_table_select(statement, "table_1")
      assert [
        %Ident{value: "a"},
        %Ident{value: "b"},
        {:number, "123", false},
        %Function{args: [%Ident{value: "b"}]},
      ] = statement.body.projection
      assert %BinaryOp{
        op: :and,
        left: %BinaryOp{
          op: :gt,
          left: %Ident{value: "a"},
          right: %Ident{value: "b"},
        },
        right: %BinaryOp{
          op: :lt_eq,
          left: %Ident{value: "b"},
          right: {:number, "100", false},
        },
      } = statement.body.selection

      assert {:ok, request} = Parser.to_request(statement)
      assert MapSet.new(request.select) == MapSet.new([
        %Field{column: "b", table: "table_1"},
        %Field{column: "a", table: "table_1"},
      ])
    end
  end

  test "parsing of a single conditional" do
    query = "SELECT * FROM jam WHERE price = 1"
    assert {:ok, [query]} = Parser.parse_postgresql(query)
    assert_table_select(query, "jam")

    assert {:ok, request} = Parser.to_request(query)
    assert request.select == [
      %Field{column: "price", table: "jam"},
      %Field{column: :wildcard, table: "jam"}
    ]
  end

  test "parsing of multiple where clauses" do
    query = "SELECT * FROM jam WHERE price < 5 OR (flavor = 'berry good' AND sale = true)"
    assert {:ok, [query]} = Parser.parse_postgresql(query)
    assert_table_select(query, "jam")

    assert {:ok, request} = Parser.to_request(query)
    assert request.select == [
      %Field{column: "sale", table: "jam"},
      %Field{column: "flavor", table: "jam"},
      %Field{column: "price", table: "jam"},
      %Field{column: :wildcard, table: "jam"},
    ]
  end

  test "parsing of list membership queries" do
    query = "SELECT * FROM parser WHERE work IN ('fun', 'easy');"
    assert {:ok, [query]} = Parser.parse_postgresql(query)
    assert_table_select(query, "parser")

    assert {:ok, request} = Parser.to_request(query)
    assert request.select == [
      %Field{column: "work", table: "parser"},
      %Field{column: :wildcard, table: "parser"},
    ]
  end

  test "parsing of list exclusion queries" do
    query = "SELECT * FROM parser WHERE work NOT IN ('fun', 'easy');"
    assert {:ok, [query]} = Parser.parse_postgresql(query)
    assert_table_select(query, "parser")

    assert {:ok, request} = Parser.to_request(query)
    assert request.select == [
      %Field{column: "work", table: "parser"},
      %Field{column: :wildcard, table: "parser"},
    ]
  end

  test "parsing of a select with dot syntax" do
    query = "SELECT foo FROM public.jam WHERE jam.price = 1"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "jam", column: "price", schema: "public"},
      %Field{table: "jam", column: "foo", schema: "public"},
    ]
  end

  test "parsing of an update statement" do
    query = "UPDATE parser SET flavor = 'mud' WHERE flavor = 'candy apple'"
    assert {:ok, [query]} = Parser.parse_postgresql(query)
    assert_table_update(query, "parser")

    assert {:ok, request} = Parser.to_request(query)
    assert request.select == [%Field{column: "flavor", table: "parser"}]
    assert request.update == [%Field{column: "flavor", table: "parser"}]
  end

  test "parsing of an update with ambiguous field names" do
    query = """
    UPDATE accounts SET contact_first_name = first_name
    FROM employees WHERE employees.id = accounts.sales_person;
    """
    assert {:ok, [query]} = Parser.parse_postgresql(query)
    assert_table_update(query, "accounts")

    assert {:ok, request} = Parser.to_request(query)
    assert request.select == [
      %Field{column: "first_name", table: "employees"},
      %Field{column: "first_name", table: "accounts"},
      %Field{column: "sales_person", table: "accounts"},
      %Field{column: "id", table: "employees"},
    ]
    assert request.update == [
      %Field{column: "contact_first_name", table: "accounts"},
    ]
  end

  test "parsing of an update with math" do
    query = """
    UPDATE employees SET sales_count = sales_count + 1 WHERE id =
    (SELECT sales_person FROM accounts WHERE name = 'Acme Corporation');
    """
    assert {:ok, [query]} = Parser.parse_postgresql(query)
    assert_table_update(query, "employees")

    assert {:ok, request} = Parser.to_request(query)
    assert request.select == [
      %Field{column: "sales_count", table: "employees"},
      %Field{column: "name", table: "accounts"},
      %Field{column: "sales_person", table: "accounts"},
      %Field{column: "id", table: "employees"},
    ]
    assert request.update == [
      %Field{column: "sales_count", table: "employees"},
    ]
  end

  test "unbounded deletion" do
    assert {:ok, [statement]} = Parser.parse_postgresql("delete from foo;")
    assert_table_delete(statement, "foo")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.delete == [
      %Field{column: :wildcard, table: "foo"},
    ]
    assert request.select == []
  end

  test "deletion with a where clause" do
    query = """
    delete from foo where abc = '123';
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_delete(statement, "foo")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.delete == [
      %Field{column: :wildcard, table: "foo"},
    ]
    assert request.select == [
      %Field{column: "abc", table: "foo"},
    ]
  end

  test "inserting specific columns" do
    query = """
    insert into my_table (a, b, c) values ('q', 1, false);
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_insert(statement, "my_table")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.insert == [
      %Field{column: "c", table: "my_table"},
      %Field{column: "b", table: "my_table"},
      %Field{column: "a", table: "my_table"},
    ]
  end

  test "inserting multiple rows" do
    query = """
    insert into my_table (a, b) values ('q', 1), ('hello', 2);
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_insert(statement, "my_table")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.insert == [
      %Field{column: "b", table: "my_table"},
      %Field{column: "a", table: "my_table"},
    ]
  end

  test "inserting by default columns" do
    query = """
    insert into my_table values ('q', 1);
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_insert(statement, "my_table")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.insert == [
      %Field{column: :wildcard, table: "my_table"},
    ]
  end

  @tag :skip
  test "insert from with statement" do
    # query taken from
    # https://www.postgresql.org/docs/current/sql-insert.html
    query = """
    WITH upd AS (
      UPDATE employees SET sales_count = sales_count + 1 WHERE id =
        (SELECT sales_person FROM accounts WHERE name = 'Acme Corporation')
        RETURNING *
    )
    INSERT INTO employees_log SELECT *, current_timestamp FROM upd;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_insert(statement, "employees_log")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.insert == [
      %Field{column: :wildcard, table: "employees_log"},
    ]
    assert request.update == [
      %Field{column: "sales_count", table: "employees"},
    ]
    assert request.select == [
      %Field{column: "id", table: "employees"},
      %Field{column: "sales_count", table: "employees"},
      %Field{column: "sales_person", table: "accounts"},
      %Field{column: "name", table: "accounts"},
    ]
  end

  test "parsing of LIKE clauses" do
    query = "UPDATE employees SET city = 'foo' WHERE city LIKE 'notfoo%';"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_update(statement, "employees")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.update == [
      %Field{column: "city", table: "employees"},
    ]
    assert request.select == [
      %Field{column: "city", table: "employees"},
    ]
  end

  test "parsing of ILIKE clauses" do
    query = "UPDATE employees SET city = 'foo' WHERE city ILIKE 'notfoo%';"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_update(statement, "employees")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.update == [
      %Field{column: "city", table: "employees"},
    ]
    assert request.select == [
      %Field{column: "city", table: "employees"},
    ]
  end

  test "parsing of SELECT with JOIN table" do
    query = """
    SELECT name FROM employees
    LEFT JOIN cities
    WHERE city_id = cities.id AND cities.name = 'foo';
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_select(statement, "employees")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{column: "name", table: "cities"},
      %Field{column: "id", table: "cities"},
      %Field{column: "city_id", table: "cities"},
      %Field{column: "city_id", table: "employees"},
      %Field{column: "name", table: "cities"},
      %Field{column: "name", table: "employees"},
    ]
  end

  test "parsing of column aliases" do
    query = "SELECT city AS township FROM employees;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_select(statement, "employees")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{column: "city", table: "employees"},
    ]
  end

  test "parsing of table aliases" do
    query = """
    SELECT c.name
    FROM public.employees e
    LEFT JOIN other_schema.cities c
    ON e.city_id = c.id;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)

    assert request.select == [
      %Field{schema: "other_schema", column: "name", table: "cities"},
      %Field{schema: "other_schema", column: "id", table: "cities"},
      %Field{schema: "public", column: "city_id", table: "employees"},
    ]
  end

  test "parsing of CASE clauses" do
    query = "SELECT CASE WHEN id=1 THEN id WHEN id=2 THEN 'two' ELSE name END FROM test;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert_table_select(statement, "test")

    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{column: "name", table: "test"},
      %Field{column: "id", table: "test"},
      %Field{column: "id", table: "test"},
      %Field{column: "id", table: "test"},
    ]
  end

  test "parsing of pg catalog lookup query" do
    query = """
    SELECT n.nspname as "Schema",
      c.relname as "Name",
      CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' WHEN 'i' THEN 'index' WHEN 'S' THEN 'sequence' WHEN 's' THEN 'special' WHEN 't' THEN 'TOAST table' WHEN 'f' THEN 'foreign table' WHEN 'p' THEN 'partitioned table' WHEN 'I' THEN 'partitioned index' END as "Type",
      pg_catalog.pg_get_userbyid(c.relowner) as "Owner"
    FROM pg_catalog.pg_class c
         LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
         LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
    WHERE c.relkind IN ('r','p','v','m','S','f','')
          AND n.nspname <> 'pg_catalog'
          AND n.nspname !~ '^pg_toast'
          AND n.nspname <> 'information_schema'
      AND pg_catalog.pg_table_is_visible(c.oid)
    ORDER BY 1,2;
    """

    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_class", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: "nspname"},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: "nspname"},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: "nspname"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relkind"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relowner"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relname"},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: "nspname"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relam"},
      %Field{schema: "pg_catalog", table: "pg_am", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relnamespace"},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: "oid"},
    ]
  end

  test "parsing of qualified wildcards" do
    query = """
    SELECT staff.*, sum(payment.amount) AS revenue
    FROM rental
    INNER JOIN staff ON rental.staff_id = staff.staff_id
    LEFT JOIN payment ON payment.rental_id = rental.rental_id
    WHERE payment.amount IS NOT NULL
    GROUP BY staff.staff_id;
    """

    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
     %Field{table: "payment", column: "amount"},
     %Field{table: "payment", column: "amount"},
     %Field{table: "staff", column: :wildcard},
     %Field{table: "rental", column: "rental_id"},
     %Field{table: "payment", column: "rental_id"},
     %Field{table: "staff", column: "staff_id"},
     %Field{table: "rental", column: "staff_id"},
   ]
  end

  test "parsing of query with CTEs" do
    query = """
    WITH workers AS (
      SELECT staff_id, first_name, password AS last_name
      FROM staff
    ), rental_days AS (
      SELECT staff_id, array_agg(rental_date ORDER BY rental_date ASC) AS days_worked
      FROM rental
      GROUP BY staff_id
    ) SELECT first_name, last_name, days_worked[array_upper(days_worked, 1)] as last_workday
      FROM rental_days
      INNER JOIN workers ON rental_days.staff_id = workers.staff_id;
    """

    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "workers", column: "days_worked"},
      %Field{table: "rental_days", column: "days_worked"},
      %Field{table: "workers", column: "days_worked"},
      %Field{table: "rental_days", column: "days_worked"},
      %Field{table: "workers", column: "last_name"},
      %Field{table: "rental_days", column: "last_name"},
      %Field{table: "workers", column: "first_name"},
      %Field{table: "rental_days", column: "first_name"},
      %Field{table: "workers", column: "staff_id"},
      %Field{table: "rental_days", column: "staff_id"},
      %Field{table: "rental", column: "rental_date"},
      %Field{table: "rental", column: "rental_date"},
      %Field{table: "rental", column: "staff_id"},
      %Field{table: "staff", column: "password"},
      %Field{table: "staff", column: "first_name"},
      %Field{table: "staff", column: "staff_id"},
    ]
  end

  test "parsing of postgres ORM startup query" do
    # all tables starting with `pg_` are reserved for postgres and don't require explicitly specifying
    # the namespace
    query = """
    SELECT t.oid, t.typname, t.typsend, t.typreceive, t.typoutput, t.typinput,
           coalesce(d.typelem, t.typelem), coalesce(r.rngsubtype, 0),
           ARRAY (
               SELECT a.atttypid
               FROM pg_attribute AS a
               WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped
               ORDER BY a.attnum
           )
    FROM pg_type AS t
    LEFT JOIN pg_type AS d ON t.typbasetype = d.oid
    LEFT JOIN pg_range AS r ON r.rngtypid = t.oid OR (t.typbasetype <> 0 AND r.rngtypid = t.typbasetype)
    WHERE (t.typrelid = 0)
    AND (t.typelem = 0 OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type s WHERE s.typrelid != 0 AND s.oid = t.typelem))
    """

    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_type", column: "typelem"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typrelid"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typelem"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typrelid"},
      %Field{schema: "pg_catalog", table: "pg_attribute", column: "attisdropped"},
      %Field{schema: "pg_catalog", table: "pg_attribute", column: "attnum"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typrelid"},
      %Field{schema: "pg_catalog", table: "pg_attribute", column: "attrelid"},
      %Field{schema: "pg_catalog", table: "pg_attribute", column: "atttypid"},
      %Field{schema: "pg_catalog", table: "pg_range", column: "rngsubtype"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typelem"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typelem"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typinput"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typoutput"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typreceive"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typsend"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typname"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typbasetype"},
      %Field{schema: "pg_catalog", table: "pg_range", column: "rngtypid"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typbasetype"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_range", column: "rngtypid"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_type", column: "typbasetype"}
    ]
  end

  test "parsing of variable sets" do
    query = "SET client_min_messages TO warning;SET TIME ZONE INTERVAL '+00:00' HOUR TO MINUTE;"
    assert {:ok, [var_statement, tz_statement]} = Parser.parse_postgresql(query)
    assert {:ok, _request} = Parser.to_request(var_statement)
    assert {:ok, _request} = Parser.to_request(tz_statement)
  end

  test "parsing of COLLATE statement" do
    query = """
    SELECT c.oid, n.nspname, c.relname
    FROM pg_catalog.pg_class c
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname OPERATOR(pg_catalog.~) '^(test_db)$' COLLATE pg_catalog.default
      AND pg_catalog.pg_table_is_visible(c.oid)
    ORDER BY 2, 3;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_class", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relname"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relname"},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: "nspname"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_class", column: "relnamespace"},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: "oid"},
    ]
  end

  test "parsing of cast" do
    query = """
    SELECT c.reloftype::pg_catalog.regtype::pg_catalog.text
    FROM pg_catalog.pg_class c;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_class", column: "reloftype"},
    ]
  end

  test "parsing implicit cross join" do
    query = "SELECT * FROM pg_catalog.pg_collation, pg_catalog.pg_type"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_collation", column: :wildcard},
      %Field{schema: "pg_catalog", table: "pg_type", column: :wildcard},
    ]
  end

  test "parsing of union join" do
    query = """
    SELECT pubname
    FROM pg_catalog.pg_publication p
    JOIN pg_catalog.pg_publication_rel pr ON p.oid = pr.prpubid
    WHERE pr.prrelid = '155324'
    UNION ALL
    SELECT pubname
    FROM pg_catalog.pg_publication p
    WHERE p.puballtables AND pg_catalog.pg_relation_is_publishable('1234');
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_publication", column: "puballtables"},
      %Field{schema: "pg_catalog", table: "pg_publication", column: "pubname"},
      %Field{schema: "pg_catalog", table: "pg_publication_rel", column: "prrelid"},
      %Field{schema: "pg_catalog", table: "pg_publication_rel", column: "pubname"},
      %Field{schema: "pg_catalog", table: "pg_publication", column: "pubname"},
      %Field{schema: "pg_catalog", table: "pg_publication_rel", column: "prpubid"},
      %Field{schema: "pg_catalog", table: "pg_publication", column: "oid"},

    ]
  end

  test "parsing of subquery membership" do
    query = """
    SELECT conname, conrelid::pg_catalog.regclass AS ontable,
           pg_catalog.pg_get_constraintdef(oid, true) AS condef
    FROM pg_catalog.pg_constraint c
    WHERE confrelid IN (SELECT pg_catalog.pg_partition_ancestors('1234')
                        UNION ALL VALUES ('1234'::pg_catalog.regclass))
    AND contype = 'f' AND conparentid = 0
    ORDER BY conname;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_constraint", column: "conparentid"},
      %Field{schema: "pg_catalog", table: "pg_constraint", column: "contype"},
      %Field{schema: "pg_catalog", table: "pg_constraint", column: "confrelid"},
      %Field{schema: "pg_catalog", table: "pg_constraint", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_constraint", column: "conrelid"},
      %Field{schema: "pg_catalog", table: "pg_constraint", column: "conname"},
    ]
  end

  @tag :skip
  # skipping until WITH ORDINALITY is supported upstream
  test "parsing queries with ordinality" do
    query = """
    SELECT * FROM unnest(ARRAY['a', 'b', 'c']) WITH ORDINALITY;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, _request} = Parser.to_request(statement)
  end

  test "parsing of TRIM statements" do
    query = """
    SELECT trim(trailing ';' from pg_catalog.pg_get_ruledef(r.oid, true))
    FROM pg_catalog.pg_rewrite r;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_rewrite", column: "oid"},
    ]
  end

  test "parsing of SUBSTRING statements" do
    query = "SELECT substring(name, 1, name_len) FROM users;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "users", column: "name_len"},
      %Field{table: "users", column: "name"},
    ]
  end

  @tag :skip
  # skipping until https://github.com/sqlparser-rs/sqlparser-rs/pull/968
  test "parsing unnest" do
    query = """
    SELECT (SELECT * FROM unnest(stxkeys)) AS columns
    FROM pg_catalog.pg_statistic_ext;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_statistic_ext", column: :wildcard},
      %Field{schema: "pg_catalog", table: "pg_statistic_ext", column: "stxkeys"},
    ]
  end

  test "parsing of derived table name" do
    query = "SELECT * FROM (SELECT name FROM users) AS t;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: :derived, column: :wildcard},
      %Field{table: "users", column: "name"},
    ]
  end

  test "parsing of table function" do
    query = "SELECT bar.bam FROM TABLE(foo) as bar"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "foo", column: "bam"},
    ]
  end

  test "parsing of nested joins table" do
    query = "SELECT * FROM (a NATURAL JOIN b) c";
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "b", column: :wildcard},
      %Field{table: "a", column: :wildcard},
    ]
  end

  test "parsing of ANY" do
    query = """
    SELECT pg_catalog.array_to_string(array(select rolname from pg_catalog.pg_roles where oid = any (pol.polroles)),',')
    FROM pg_catalog.pg_policy pol;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_policy", column: "polroles"},
      %Field{schema: "pg_catalog", table: "pg_roles", column: "oid"},
      %Field{schema: "pg_catalog", table: "pg_roles", column: "rolname"},
    ]
  end

  test "parsing of multiple union selects" do
    query = """
    SELECT *
    UNION SELECT * FROM pg_namespace
    UNION SELECT * FROM pg_class;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{schema: "pg_catalog", table: "pg_class", column: :wildcard},
      %Field{schema: "pg_catalog", table: "pg_namespace", column: :wildcard},
    ]
  end

  test "parsing wildcard as function argument" do
    query = "SELECT count(*) FROM test;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "test", column: :wildcard},
    ]
  end

  test "parsing arrays" do
    query = "SELECT ARRAY[a, b] FROM test;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "test", column: "b"},
      %Field{table: "test", column: "a"},
    ]
  end

  test "parsing json access" do
    query = "SELECT data->>'region' FROM test;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "test", column: "data"},
    ]
  end

  test "parsing hstore access" do
    query = "SELECT a->'key' FROM test;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "test", column: "a"},
    ]
  end

  test "parsing ON CONFLICT statement" do
    query = """
    INSERT INTO transactions(name, amount)
    VALUES ('bob', '1234'), ('alice', '4321')
    ON CONFLICT (name) DO NOTHING;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "transactions", column: "name"},
    ]

    query = """
    INSERT INTO customers (name, email)
    VALUES('Microsoft','hotline@microsoft.com')
    ON CONFLICT (name)
    DO UPDATE SET email = EXCLUDED.email || ';' || customers.email;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "customers", column: "email"},
      %Field{table: "EXCLUDED", column: "email"},
      %Field{table: "customers", column: "name"},
    ]
    assert request.update == [
      %Field{table: "customers", column: "email"},
    ]
  end

  test "parsing SIMILAR TO statement" do
    query = "SELECT a SIMILAR TO '%' + b + '%' FROM test;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "test", column: "a"},
      %Field{table: "test", column: "b"},
    ]
  end

  test "parsing composite access" do
    query = "SELECT (item).name FROM on_hand WHERE (item).price > 9.99;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "on_hand", column: "item"},
      %Field{table: "on_hand", column: "item"},
    ]
  end

  test "parsing OVERLAY statement" do
    query = "SELECT overlay(a placing b from 3) FROM test;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "test", column: "b"},
      %Field{table: "test", column: "a"},
    ]
  end

  test "parsing of aggregates with filter" do
    query = "SELECT AVG(mark) FILTER (WHERE mark > 0) FROM scores;"
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "scores", column: "mark"},
      %Field{table: "scores", column: "mark"},
    ]
  end

  test "parsing implicit table name in join" do
    query = """
    SELECT * FROM weather JOIN cities ON city = name;
    """
    assert {:ok, [statement]} = Parser.parse_postgresql(query)
    assert {:ok, request} = Parser.to_request(statement)
    assert request.select == [
      %Field{table: "cities", column: :wildcard},
      %Field{table: "weather", column: :wildcard},
      %Field{table: "cities", column: "name"},
      %Field{table: "weather", column: "name"},
      %Field{table: "cities", column: "city"},
      %Field{table: "weather", column: "city"},
    ]
  end

  defp assert_table_select(statement, name) do
    assert %Query{
      body: %Select{
        from: [
          %TableWithJoins{
            relation: %Table{name: [%{value: ^name}]},
          },
        ],
      }
    } = statement
  end

  defp assert_table_update(statement, name) do
    assert %Update{
      table: %TableWithJoins{
        relation: %Table{name: [%{value: ^name}]},
      },
    } = statement
  end

  defp assert_table_delete(statement, name) do
    assert %Delete{
      from: [
        %TableWithJoins{
          relation: %Table{name: [%{value: ^name}]}
        },
      ],
    } = statement
  end

  defp assert_table_insert(statement, name) do
    assert %Insert{
      table_name: [%Ident{value: ^name}],
    } = statement
  end
end
