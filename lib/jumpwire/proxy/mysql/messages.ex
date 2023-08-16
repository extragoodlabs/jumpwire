defmodule JumpWire.Proxy.MySQL.Messages do
  require Logger
  import Bitwise
  import JumpWire.Proxy.MySQL.Parser

  @default_max_packet_size 16_777_215
  @default_charset 33  # utf8_general_ci

  # https://dev.mysql.com/doc/mysql-errors/8.0/en/server-error-reference.html
  @error_codes [
    access_denied: 1045,
    unknown_error: 1105,
    columnaccess_denied: 1143,
    not_supported_auth_mode: 1251,
  ]

  # https://dev.mysql.com/doc/internals/en/status-flags.html
  @status_flags [
    server_status_in_trans: 0x0001,
    server_status_autocommit: 0x0002,
    server_more_results_exists: 0x0008,
    server_status_no_good_index_used: 0x0010,
    server_status_no_index_used: 0x0020,
    server_status_cursor_exists: 0x0040,
    server_status_last_row_sent: 0x0080,
    server_status_db_dropped: 0x0100,
    server_status_no_backslash_escapes: 0x0200,
    server_status_metadata_changed: 0x0400,
    server_query_was_slow: 0x0800,
    server_ps_out_params: 0x1000,
    server_status_in_trans_readonly: 0x2000,
    server_session_state_changed: 0x4000
  ]

  # https://dev.mysql.com/doc/internals/en/capability-flags.html
  @capability_flags [
    client_long_password: 0x00000001,
    client_found_rows: 0x00000002,
    client_long_flag: 0x00000004,
    client_connect_with_db: 0x00000008,
    client_no_schema: 0x00000010,
    client_compress: 0x00000020,
    client_odbc: 0x00000040,
    client_local_files: 0x00000080,
    client_ignore_space: 0x00000100,
    client_protocol_41: 0x00000200,
    client_interactive: 0x00000400,
    client_ssl: 0x00000800,
    client_ignore_sigpipe: 0x00001000,
    client_transactions: 0x00002000,
    client_reserved: 0x00004000,
    client_secure_connection: 0x00008000,
    client_multi_statements: 0x00010000,
    client_multi_results: 0x00020000,
    client_ps_multi_results: 0x00040000,
    client_plugin_auth: 0x00080000,
    client_connect_attrs: 0x00100000,
    client_plugin_auth_lenenc_client_data: 0x00200000,
    client_can_handle_expired_passwords: 0x00400000,
    client_session_track: 0x00800000,
    client_deprecate_eof: 0x01000000
  ]

  defp put_status_flags(flags \\ 0, names) do
    Enum.reduce(names, flags, &(&2 ||| Keyword.fetch!(@status_flags, &1)))
  end

  def ok_msg(status_flags \\ []) do
    flags = put_status_flags(status_flags)
    rows = 0
    insert_id = 0
    warnings = 0
    <<0,
      length_encode(rows)::binary,
      length_encode(insert_id)::binary,
      flags::uint2,
      warnings::uint2
    >>
  end

  def error_msg(code, msg) do
    marker = "J"
    state = "MPWRE"
    <<255, code::uint2, marker::binary, state::binary, msg::binary>>
  end

  def auth_error(msg), do: @error_codes[:not_supported_auth_mode] |> error_msg(msg)
  def internal_error(msg), do: @error_codes[:unknown_error] |> error_msg(msg)
  def policy_blocked_error() do
    @error_codes[:columnaccess_denied] |> error_msg("Blocked by policy")
  end

  def handshake(nonce) do
    version = "8.0.28"
    [_node_id, pid_little, pid_big] = self()
    |> :erlang.pid_to_list()
    |> Stream.reject(fn c -> c == ?< || c == ?> end)
    |> Enum.chunk_by(fn c -> c == ?. end)
    |> Stream.reject(fn c -> c == '.' end)
    |> Enum.map(fn c -> List.to_integer(c) end)
    thread = <<pid_little::26-little, pid_big::2-little, 0::4>>
    character_set = 255 # 1 byte

    cap_flags = MyXQL.Protocol.Flags.put_capability_flags([
      :client_long_password,
      :client_found_rows,
      :client_long_flag,
      :client_connect_with_db,
      :client_no_schema,
      :client_compress,
      :client_odbc,
      :client_local_files,
      :client_ignore_space,
      :client_protocol_41,
      :client_interactive,
      :client_ssl,
      :client_ignore_sigpipe,
      :client_transactions,
      :client_reserved,
      :client_secure_connection,
      :client_multi_statements,
      :client_multi_results,
      :client_ps_multi_results,
      :client_plugin_auth,
      :client_connect_attrs,
      :client_plugin_auth_lenenc_client_data,
      :client_can_handle_expired_passwords,
      :client_session_track,
    ])
    <<cap_flags_1::binary-size(2), cap_flags_2::binary-size(2)>> = <<cap_flags::uint4>>
    status = <<2, 0>>  # auto_commit

    <<auth_data_head::binary-8, auth_data::binary-12>> = nonce
    nonce_len = 21
    auth_plugin = "caching_sha2_password"
    <<10,
      version::binary, 0,
      thread::binary,
      auth_data_head::binary, 0,
      cap_flags_1::binary,
      character_set,
      status::binary,
      cap_flags_2::binary,
      nonce_len,
      0::uint(10),
      auth_data::binary, 0,
      auth_plugin::binary, 0
    >>
  end

  def handshake_response(config, cap_flags, auth_response) do
    auth_plugin_name = "caching_sha2_password"
    database =
      case config.database do
        nil -> ""
        db -> <<db::binary, 0>>
      end

    <<cap_flags::uint4,
      @default_max_packet_size::uint4,
      @default_charset,
      0::23-unit(8),
      config.username::binary, 0,
      length_encode(auth_response)::binary,
      database::binary,
      auth_plugin_name::binary, 0
    >>
  end

  def ssl_request(cap_flags) do
    <<cap_flags::uint4,
      @default_max_packet_size::uint4,
      @default_charset,
      0::23-unit(8)
    >>
  end

  def fast_auth("caching_sha2_password") do
    <<1, 4>>
  end
  def fast_auth(method) do
    Logger.warn("Client requested unsupported auth method #{method}")
    auth_error("Unsupported authentication method")
  end

  def unset_capability_flag(flags, flag) do
    if MyXQL.Protocol.Flags.has_capability_flag?(flags, flag) do
      value = Keyword.fetch!(@capability_flags, flag)
      Bitwise.bxor(flags, value)
    else
      flags
    end
  end

  def length_encode(payload) when is_binary(payload) do
    size = byte_size(payload) |> length_encode()
    <<size::binary, payload::binary>>
  end
  def length_encode(int) when int < 251, do: <<int>>
  def length_encode(int) when int < 65_536, do: <<252, int::uint2>>
  def length_encode(int) when int < 16_777_216, do: <<253, int::uint3>>
  def length_encode(int), do: <<254, int::uint8>>

  def parse_null_terminated_binary(data), do: parse_null_terminated_binary(data, [])
  def parse_null_terminated_binary(<<0, rest::binary>>, acc) do
    parsed = acc |> Enum.reverse() |> :binary.list_to_bin()
    {parsed, rest}
  end
  def parse_null_terminated_binary(<<>>, _acc), do: {:error, :eof}
  def parse_null_terminated_binary(<<char, rest::binary>>, acc) do
    parse_null_terminated_binary(rest, [char | acc])
  end

  def parse_length_encoded_int(msg) do
    case msg do
      <<int, rest::binary>> when int < 251 -> {int, rest}
      <<252, int::uint2, rest::binary>> -> {int, rest}
      <<253, int::uint3, rest::binary>> -> {int, rest}
      <<254, int::uint8, rest::binary>> -> {int, rest}
    end
  end

  def parse_length_encoded(msg) do
    case msg do
      <<len, data::binary-size(len), rest::binary>> when len < 251 -> {data, rest}
      <<0xFC, len::uint2, data::binary-size(len), rest::binary>> -> {data, rest}
      <<0xFD, len::uint3, data::binary-size(len), rest::binary>> -> {data, rest}
      <<0xFE, len::uint8, data::binary-size(len), rest::binary>> -> {data, rest}
    end
  end
end
