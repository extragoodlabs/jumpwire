defmodule JumpWire.Proxy.MySQL.Resultset do
  require Logger
  alias JumpWire.Record
  alias JumpWire.Proxy.{Database, MySQL}
  import JumpWire.Proxy.MySQL.Parser
  import Bitwise

  def parse(col_count_payload, count_seq, rest, state) do
    {column_count, ""} = MySQL.Messages.parse_length_encoded_int(col_count_payload)

    {col_def_packets, rest} =
      Enum.reduce(1..column_count, {[], rest}, fn _, {pkts, msg} ->
        {payload, _, rest} = MySQL.Parser.next(msg)
        {[payload | pkts], rest}
      end)
    col_def_packets = Enum.reverse(col_def_packets)
    columns = Enum.map(col_def_packets, &parse_column_definition/1)
    # TODO: validate that the marker packet is EOF/OK and not an error
    {col_marker_pkt, col_marker_seq, rest} = MySQL.Parser.next(rest)

    col_count_packet = encode(col_count_payload, count_seq)
    col_def_packets = col_def_packets
    |> Stream.with_index(count_seq + 1)
    |> Enum.map(fn {pkt, seq} -> encode(pkt, seq) end)
    col_marker_pkt = encode(col_marker_pkt, col_marker_seq)

    packets = [col_count_packet, col_def_packets, col_marker_pkt]
    parse_data(rest, columns, packets, state)
  end

  def parse_data(data, columns, header_packets, state, acc \\ []) do
    with {:ok, records, eof_data} <- parse_result_rows(data, columns, state, acc) do
      policies = JumpWire.Policy.list_all(state.organization_id)

      row_packets = Enum.reduce_while(records, [], fn record, acc ->
        {res, msg} = apply_policies(record, policies, columns, state)
        {res, [msg | acc]}
      end)

      {:ok, [header_packets, row_packets, eof_data]}
    else
      {:eof, acc, msg} -> {:eof, {acc, columns, header_packets}, msg}
      err -> err
    end
  end

  def encode(pkt, seq) do
    [<<byte_size(pkt)::uint3, seq>>, pkt]
  end

  def apply_policies(record, policies, column_defs, state) do
    case Database.apply_policies(record, policies, state) do
      :blocked ->
        msg = MySQL.Messages.policy_blocked_error()
        |> encode(record.extra_field_info.sequence)
        {:halt, msg}
      {:error, err} ->
        Logger.error("Error applying policy: #{inspect err}")
        msg = MySQL.Messages.internal_error("Error applying policy")
        |> encode(record.extra_field_info.sequence)
        {:halt, msg}
      :error ->
        Logger.error("Unknown error applying policy")
        msg = MySQL.Messages.internal_error("Error applying policy")
        |> encode(record.extra_field_info.sequence)
        {:halt, msg}
      %Record{} = rec ->
        JumpWire.Events.database_field_accessed(rec, state.metadata)
        # serialize the fields for the wire, preserving the original order
        bitmap_size = div(length(column_defs) + 7 + 2, 8)
        null_bytes = Enum.reduce(1..bitmap_size, [], fn _, acc -> [0 | acc] end)
        {data, null_bytes} = column_defs
        |> Stream.with_index(2)
        |> Enum.reduce({[], null_bytes}, fn {%{name: name} = column_def, index}, acc ->
          rec.data |> Map.get(name) |> encode_value(index, state.command, column_def, acc)
        end)

        bitmap_packet =
          case state.command do
            {_, :binary} -> [0 | null_bytes]
            _ -> ""
          end
        data = [bitmap_packet | Enum.reverse(data)]

        len = :erlang.iolist_size(data)
        seq = Map.get(record.extra_field_info, :sequence)
        {:cont, [<<len::uint3, seq>>, data]}
    end
  end

  def parse_column_definition(payload) do
    # catalog is always def
    <<3, "def", payload::binary>> = payload
    {database, payload} = MySQL.Messages.parse_length_encoded(payload)
    {_table, payload} = MySQL.Messages.parse_length_encoded(payload)
    {orig_table, payload} = MySQL.Messages.parse_length_encoded(payload)
    {name, payload} = MySQL.Messages.parse_length_encoded(payload)
    {orig_name, payload} = MySQL.Messages.parse_length_encoded(payload)
    # field_len is always 12
    <<12, payload::binary>> = payload

    # there are always two (undocumented) null bytes at the end of the packet
    <<_charset::uint2, _field_max_len::uint4, type, flags::uint2, _decimals, 0, 0>> = payload

    # orig_name will be an empty string if a static value was selected
    # eg SELECT TRUE, FALSE, NULL
    col_name = if orig_name != "", do: orig_name, else: name

    col_def = %{
      database: database,
      table: orig_table,
      name: col_name,
      type: MyXQL.Protocol.Values.type_code_to_atom(type),
      unsigned?: MyXQL.Protocol.Flags.has_column_flag?(flags, :unsigned_flag),
      flags: flags,
    }
    Map.put(col_def, :decoder, column_def_to_type(col_def))
  end

  def parse_result_rows(
    msg = <<len::uint3, seq, payload::binary-size(len), rest::binary>>,
    cols,
    state,
    acc
  ) do
    case parse_result_row(payload, cols, state) do
      {:halt, :error} ->
        Logger.error("Error parsing rows in resultset")
        {:error, acc, msg}

      {:halt, _} ->
        {:ok, acc, msg}

      {:cont, record} ->
        record = Map.update!(record, :extra_field_info, fn info ->
          Map.put(info, :sequence, seq)
        end)
        parse_result_rows(rest, cols, state, [record | acc])
    end
  end
  def parse_result_rows(msg, _cols, _state, acc), do: {:eof, acc, msg}

  defp parse_result_row(<<254, _rest::binary>>, _, _), do: {:halt, :eof}
  defp parse_result_row(<<255, _rest::binary>>, _, _), do: {:halt, :error}
  defp parse_result_row(<<0, rest::binary>>, cols, state = %{command: {_, :binary}}) do
    size = div(length(cols) + 7 + 2, 8)
    <<null_bitmap::uint(size), values::bits>> = rest
    null_bitmap = null_bitmap >>> 2

    record = %Record{
      data: %{},
      labels: %{},
      source: "mysql",
      label_format: :key,
      extra_field_info: %{tables: %{}},
    }
    schemas =
      case Database.fetch_tables(state.organization_id, state.db_manifest.id) do
        {:ok, {_tables, schemas}} -> schemas
        _ -> %{}
      end

    decode_binary_row(values, null_bitmap, cols, schemas, record)
  end
  defp parse_result_row(payload, cols, state = %{command: {_, :text}}) do
    schemas =
      case Database.fetch_tables(state.organization_id, state.db_manifest.id) do
        {:ok, {_tables, schemas}} -> schemas
        _ -> %{}
      end

    record = %Record{
      data: %{},
      labels: %{},
      source: "mysql",
      label_format: :key,
      extra_field_info: %{tables: %{}},
    }

    {record, _rest} =
      Enum.reduce(cols, {record, payload}, fn col, {record, payload} ->
        {field, rest} =
          case payload do
            <<0xFB, rest::binary>> -> {nil, rest}
            _ -> MySQL.Messages.parse_length_encoded(payload)
          end

        field_labels = schemas |> Map.get(col.table, %{}) |> Map.get(col.name, [])
        record = record
        |> Record.put([:data, col.name], field)
        |> Record.put([:labels, col.name], field_labels)
        |> Record.put([:extra_field_info, :tables, col.name], col.table)
        {record, rest}
      end)

    {:cont, record}
  end

  defp decode_binary_row(<<rest::bits>>, null_bitmap, [col | cols], schemas, record)
  when (null_bitmap &&& 1) == 1 do
    field_labels = schemas |> Map.get(col.table, %{}) |> Map.get(col.name, [])
    record = record
    |> Record.put([:data, col.name], nil)
    |> Record.put([:labels, col.name], field_labels)
    |> Record.put([:extra_field_info, :tables, col.name], col.table)

    decode_binary_row(rest, null_bitmap >>> 1, cols, schemas, record)
  end
  defp decode_binary_row(<<payload::bits>>, null_bitmap, [col | cols], schemas, record) do
    {field, rest} =
      case col.decoder do
        :lenenc -> MySQL.Messages.parse_length_encoded(payload)

        {:uint, size} ->
          <<field::uint(size), rest::bits>> = payload
          {field, rest}

        {:int, size} ->
          <<field::uint(size)-signed, rest::bits>> = payload
          {field, rest}

        :float ->
          <<field::32-signed-little-float, rest::bits>> = payload
          {field, rest}

        :double ->
          <<field::64-signed-little-float, rest::bits>> = payload
          {field, rest}

        :datetime -> MySQL.Messages.parse_length_encoded(payload)
        :time -> MySQL.Messages.parse_length_encoded(payload)

        :json ->
          {field, rest} = MySQL.Messages.parse_length_encoded(payload)
          {Jason.decode!(field), rest}

        :null -> {nil, payload}
      end

    field_labels = schemas |> Map.get(col.table, %{}) |> Map.get(col.name, [])
    record = record
    |> Record.put([:data, col.name], field)
    |> Record.put([:labels, col.name], field_labels)
    |> Record.put([:extra_field_info, :tables, col.name], col.table)

    decode_binary_row(rest, null_bitmap >>> 1, cols, schemas, record)
  end
  defp decode_binary_row(<<>>, _null_bitmap, [], _schemas, record) do
    {:cont, record}
  end

  defp encode_value(nil, index, {_, :binary}, _, {acc, bitmap}) do
    byte = Integer.floor_div(index, 8)
    bit = Integer.mod(index, 8)
    bitmap = List.update_at(bitmap, byte, & &1 + (1 <<< bit))
    {acc, bitmap}
  end
  defp encode_value(nil, _, {_, :text}, _, {acc, bitmap}) do
    {[<<0xFB>> | acc], bitmap}
  end
  defp encode_value(value, _, {_, :text}, _, {acc, bitmap}) do
    field = MySQL.Messages.length_encode(value)
    {[field | acc], bitmap}
  end
  defp encode_value(value, _, {_, :binary}, %{type: type, unsigned?: unsigned?}, {acc, bitmap}) do
    {automatic_type, field} = MyXQL.Protocol.Values.encode_binary_value(value)

    # [JW-538] Sometimes auto-encoding value can result in different type than original, for example:
    #   MYSQL_TYPE_LONG (4 bytes) --[decode]--> elixir integer --[encode]--> MYSQL_TYPE_LONGLONG (8 bytes).
    # Therefore we must perform type correction for those cases, otherwise client will get incorrect results.
    # NOTE: It would be beneficial to report this to MyXQL, so they could provide helper for type-assisted encoding.
    field = case automatic_type == type do
      true -> field
      false -> case {type, unsigned?} do
        # Cases where integer MUST NOT be encoded as int8:
        {:mysql_type_tiny, true} -> <<value::uint1>>
        {:mysql_type_tiny, false} -> <<value::int1>>
        {:mysql_type_short, true} -> <<value::uint2>>
        {:mysql_type_short, false} -> <<value::int2>>
        {:mysql_type_long, true} -> <<value::uint4>>
        {:mysql_type_long, false} -> <<value::int4>>
        {:mysql_type_int24, true} -> <<value::uint4>>
        {:mysql_type_int24, false} -> <<value::int4>>
        {:mysql_type_longlong, true} -> <<value::uint8>>
        {:mysql_type_year, _} -> <<value::uint2>>
        # Cases where type CAN be coerced into mysql_type_var_string:
        {:mysql_type_blob, _} -> field
        {:mysql_type_tiny_blob, _} -> field
        {:mysql_type_medium_blob, _} -> field
        {:mysql_type_long_blob, _} -> field
        {:mysql_type_string, _} -> field
        # Other cases:
        _ ->
          Logger.error("Unexpected type conversion from '#{type}' to '#{automatic_type}'.")
          field
      end
    end

    {[field | acc], bitmap}
  end

  defp column_def_to_type(%{type: :mysql_type_tiny, unsigned?: true}), do: {:uint, 1}
  defp column_def_to_type(%{type: :mysql_type_tiny, unsigned?: false}), do: {:int, 1}
  defp column_def_to_type(%{type: :mysql_type_short, unsigned?: true}), do: {:uint, 2}
  defp column_def_to_type(%{type: :mysql_type_short, unsigned?: false}), do: {:int, 2}
  defp column_def_to_type(%{type: :mysql_type_long, unsigned?: true}), do: {:uint, 4}
  defp column_def_to_type(%{type: :mysql_type_long, unsigned?: false}), do: {:int, 4}
  defp column_def_to_type(%{type: :mysql_type_int24, unsigned?: true}), do: {:uint, 4}
  defp column_def_to_type(%{type: :mysql_type_int24, unsigned?: false}), do: {:int, 4}
  defp column_def_to_type(%{type: :mysql_type_longlong, unsigned?: true}), do: {:uint, 8}
  defp column_def_to_type(%{type: :mysql_type_longlong, unsigned?: false}), do: {:int, 8}
  defp column_def_to_type(%{type: :mysql_type_year}), do: {:uint, 2}
  defp column_def_to_type(%{type: :mysql_type_float}), do: :float
  defp column_def_to_type(%{type: :mysql_type_double}), do: :double
  defp column_def_to_type(%{type: :mysql_type_newdecimal}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_timestamp}), do: :datetime
  defp column_def_to_type(%{type: :mysql_type_date}), do: :datetime
  defp column_def_to_type(%{type: :mysql_type_datetime}), do: :datetime
  defp column_def_to_type(%{type: :mysql_type_time}), do: :time
  defp column_def_to_type(%{type: :mysql_type_json}), do: :json
  defp column_def_to_type(%{type: :mysql_type_null}), do: :null
  defp column_def_to_type(%{type: :mysql_type_blob}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_tiny_blob}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_medium_blob}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_long_blob}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_var_string}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_string}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_bit}), do: :lenenc
  defp column_def_to_type(%{type: :mysql_type_geometry}), do: :lenenc
end
