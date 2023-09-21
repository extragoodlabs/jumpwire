defmodule JumpWire.Proxy.Database do
  @type state() :: map()

  @type handle_info_result() ::
  {:noreply, state :: state()}
  | {:noreply, state :: state(), timeout() | :hibernate | {:continue, state()}}
  | {:stop, reason :: term(), state :: term()}

  @callback on_boot() :: map()
  @callback init(map) :: map()
  @callback db_recv(msg :: binary(), state :: state()) :: handle_info_result()
  @callback client_recv(msg :: binary(), state :: state()) :: handle_info_result()
  @callback params_from_manifest(JumpWire.Manifest.t) :: {:ok, Keyword.t, map | nil}
  @callback client_authenticated(JumpWire.ClientAuth.t(), org_id :: Ecto.UUID.t(), db_id :: Ecto.UUID.t(), state()) :: {:ok, state()} | {:error, any}
  @callback client_authorized(client_id :: Ecto.UUID.t(), request_id :: Ecto.UUID.t(), state()) :: {:ok, state()} | {:error, any}

  @doc false
  defmacro __using__(opts) do
    manifest_type = Keyword.fetch!(opts, :manifest_type)
    quote do
      alias JumpWire.Manifest
      alias JumpWire.Proxy.Schema
      alias JumpWire.Record
      alias JumpWire.Proxy.Database.Socket
      require Logger

      @behaviour JumpWire.Proxy.Database
      @behaviour :ranch_protocol
      @timeout 5_000
      @socket_opts [:binary, active: :once, packet: 0, nodelay: true]

      def child_spec({opts, arg}) do
        arg = on_boot() |> Map.merge(arg)
        :ranch.child_spec(__MODULE__, :ranch_tcp, opts, __MODULE__, arg)
      end

      @impl :ranch_protocol
      def start_link(ref, transport, opts) do
        {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}, __MODULE__])}
      end

      @impl JumpWire.Proxy.Database
      def on_boot(), do: %{}
      defoverridable on_boot: 0

      @impl JumpWire.Proxy.Database
      def init(state), do: state
      defoverridable init: 1

      @impl JumpWire.Proxy.Database
      def client_authenticated(_client, _org_id, _db_id, state), do: {:ok, state}
      defoverridable client_authenticated: 4

      @impl JumpWire.Proxy.Database
      def client_authorized(_client_id, _request_id, state), do: {:ok, state}
      defoverridable client_authorized: 3

      def init(arg, name) do
        if Application.get_env(:jumpwire, :trace_proxy, false) do
          Process.register(self(), Module.concat(name, Client))
        end
        state = arg |> JumpWire.Proxy.Database.init() |> init()
        :gen_server.enter_loop(name, [], state, @timeout)
      end

      def handle_info({:vault_renew, lease_id}, state) do
        case JumpWire.Proxy.Storage.Vault.renew(lease_id) do
          {:ok, lease_id, ttl} ->
            Logger.debug("Vault credentials for lease #{lease_id} renewed for #{ttl}s")
            timer = Integer.floor_div(ttl * 1000,  2)
            Process.send_after(self(), {:vault_renew, lease_id}, timer)

          _ ->
            Logger.error("Failed to renew #{lease_id} for Vault credentials")
        end
        {:noreply, state}
      end

      def handle_info({:update, :schema_labels, schema = %Schema{manifest_id: manifest_id}}, state) do
        with %{id: ^manifest_id} <- state.db_manifest do
          JumpWire.Proxy.Database.set_table_schema(state.organization_id, manifest_id, schema)
        end

        {:noreply, state}
      end

      def handle_info({:delete, :manifest, %Manifest{id: id, root_type: unquote(manifest_type)}}, state) do
        case state.db_manifest do
          %{id: ^id} ->
            Logger.info("#{unquote(manifest_type)} manifest #{id} was deleted, closing active connection")
            JumpWire.Proxy.Database.close_proxy(state)

          _ -> {:noreply, state}
        end
      end

      def handle_info({:delete, :manifest, %Manifest{id: id, root_type: :jumpwire}}, state) do
        case state.client_auth do
          %{id: ^id} ->
            Logger.info("Auth manifest #{id} was deleted, closing active connection")
            JumpWire.Proxy.Database.close_proxy(state)

          _ -> {:noreply, state}
        end
      end

      def handle_info({action, _, _}, state) when action in [:update, :delete, :setup] do
        {:noreply, state}
      end

      def handle_info({:client_authenticated, org_id, db_id, nonce, client}, state)
      when nonce == state.client_id do
        with {:ok, %{root_type: unquote(manifest_type)}} <- JumpWire.Manifest.fetch(org_id, db_id),
             {:ok, state} <- client_authenticated(client, org_id, db_id, state) do
          Logger.debug("Client authenticated")
          JumpWire.Analytics.proxy_authenticated(org_id, unquote(manifest_type))
          {:noreply, state}
        else
          _ ->
            Logger.error("Could not find database for authenticated client", manifest: db_id)
            {:noreply, state}
        end
      end

      def handle_info({:client_authenticated, _, _, _, _}, state) do
        {:noreply, state}
      end

      def handle_info({:client_authorized, org_id, db_id, client_id, id}, state) when client_id == state.client_id do
        with {:ok, %{root_type: unquote(manifest_type)}} <- JumpWire.Manifest.fetch(org_id, db_id),
             {:ok, state} <- client_authorized(client_id, id, state) do
          Logger.debug("Client access request #{id} approved")
          {:noreply, state}
        else
          _ ->
            Logger.error("Could not find database for authenticated client", manifest: db_id)
            {:noreply, state}
        end
      end

      def handle_info({:client_authorized, _, _, _, _}, state) do
        {:noreply, state}
      end

      def handle_info({:tcp, socket, data}, state) do
        case state do
          %{client_socket: %Socket{transport: :ranch_tcp, socket: ^socket}} ->
            client_recv(data, state)

          %{db_socket: %Socket{transport: :ranch_tcp, socket: ^socket}} ->
            db_recv(data, state)

          _ ->
            Logger.error("Message received from invalid TCP socket")
            JumpWire.Proxy.Database.close_proxy(state)
        end
      end

      def handle_info({:ssl, socket, data}, state) do
        case state do
          %{client_socket: %Socket{socket: ^socket}} ->
            client_recv(data, state)

          %{db_socket: %Socket{socket: ^socket}} ->
            db_recv(data, state)

          _ ->
            Logger.error("Message received from invalid SSL socket")
            JumpWire.Proxy.Database.close_proxy(state)
        end
      end

      def handle_info(msg, state) do
        # TODO: if the socket is closed from the DBs side,
        # we should try to re-establish it
        # Logger.debug("Closing sockets: #{inspect msg}")
        JumpWire.Proxy.Database.close_proxy(state)
      end
    end
  end

  require Logger
  alias JumpWire.Proxy.Schema
  alias JumpWire.Record
  use TypedStruct

  defmodule Socket do
    @moduledoc """
    This module defines the structure for working with a socket when
    proxying a database connection.
    """

    typedstruct do
      field :state, :init | :ready | {atom(), term()}, default: :init
      field :ssl, nil | :require | :verify
      field :transport, module()
      field :socket, any()
    end

    def set_state(socket, state), do: Map.put(socket, :state, state)
  end

  def init({ref, transport, opts}) do
    {:ok, client_socket} = :ranch.handshake(ref)
    :ok = transport.setopts(client_socket, [:binary, active: :once])
    JumpWire.PubSub.subscribe("*")

    proxy_opts = Application.get_env(:jumpwire, :proxy)

    flags = proxy_opts
    |> Keyword.take([:parse_responses, :parse_requests])
    |> Map.new()

    ssl_opts = proxy_opts[:server_ssl]
    ssl_opts =
      if proxy_opts[:use_sni] do
        Keyword.put(ssl_opts, :sni_fun, &JumpWire.TLS.sni_fun/1)
      else
        ssl_opts
      end

    state = %{
      client_socket: %Socket{transport: transport, socket: client_socket},
      db_socket: nil,
      startup_params: nil,
      organization_id: Map.get(opts, :org_id),
      client_id: nil,
      client_auth: nil,
      db_manifest: nil,
      db_opts: nil,
      fields: nil,
      policies: [],
      db_buffer: "",
      client_buffer: nil,
      server_ssl_opts: ssl_opts,
      metadata: %{attributes: MapSet.new(["*"]), session_id: nil},
      start_time: nil,
      stop_time: nil,
      row_count: 0,
      policy_error: false,
      queue: [],
      flags: flags,
    }
    Map.merge(state, opts)
  end

  @doc """
  Convert a schema object to a format that makes for easier lookups.

  Uses the table OID as the key.
  """
  @spec convert_schema(Schema.t, map) :: {integer, map}
  def convert_schema(schema = %Schema{}, tables) do
    {_key, table} = Enum.find(tables, {nil, []}, fn {{_, name}, _} -> name == schema.name end)
    oid = table |> List.first(%{}) |> Map.get(:id)
    fields = schema.fields
    |> Stream.map(fn
      {"$." <> name, labels} -> {name, labels}
      field -> field
    end)
    |> Stream.map(fn {field, labels} ->
      case Enum.find(table, fn row -> row.column == field end) do
        nil -> nil
        row -> {row.column_id, {field, labels}}
      end
    end)
    |> Stream.reject(&is_nil/1)
    |> Map.new()

    {oid, fields}
  end


  @spec apply_policies(Record.t, [JumpWire.Policy.t], state) :: Record.t | atom | {:error, any}
  def apply_policies(record, policies, state) do
    client =
      case JumpWire.ClientAuth.fetch(state.organization_id, state.client_id) do
        {:ok, client} -> client
        _ -> state.client_auth
      end

    attributes = client
    |> JumpWire.ClientAuth.get_attributes()
    |> MapSet.union(state.metadata.attributes)
    |> MapSet.union(record.attributes)

    info = Map.merge(state.metadata, %{
      module: __MODULE__,
      type: :db_proxy,
      classification: client.classification,
      attributes: attributes,
    })

    JumpWire.Policy.apply_policies(policies, record, info)
  end

  def close_db_socket(state = %{db_socket: nil}), do: state
  def close_db_socket(state = %{db_socket: %Socket{transport: transport, socket: socket}}) do
    transport.close(socket)
    JumpWire.Events.database_client_disconnected(state.metadata)
    %{state | db_socket: nil}
  end

  def close_proxy(state) do
    %Socket{transport: transport, socket: socket} = state.client_socket
    transport.close(socket)
    state = close_db_socket(state)
    {:stop, :shutdown, state}
  end

  def msg_send(nil, _) do
    Logger.error("Attempted to send data with no TCP connection!")
    :error
  end
  def msg_send(%Socket{transport: transport, socket: sock}, data), do: transport.send(sock, data)

  def socket_active(%Socket{transport: transport, socket: sock}), do: transport.setopts(sock, [active: :once])

  def fetch_tables(org_id, db_id) do
    JumpWire.GlobalConfig.fetch(:manifest_table_metadata, {org_id, db_id})
  end

  def put_tables(org_id, db_id, tables, schemas) do
    # Update part of the object in the ETS table
    JumpWire.GlobalConfig.put(
      :manifest_table_metadata,
      {org_id, db_id},
      {tables, schemas}
    )
  end

  @doc """
  Set the OID -> field mapping for a schema in the ETS table.
  """
  def set_table_schema(org_id, db_id, schema) do
    {tables, schemas} =
      case fetch_tables(org_id, db_id) do
        {:ok, tables} -> tables
        _ -> {%{}, %{}}
      end

    {oid, fields} = convert_schema(schema, tables)
    schemas = Map.put(schemas, oid, fields)

    put_tables(org_id, db_id, tables, schemas)
  end
end
