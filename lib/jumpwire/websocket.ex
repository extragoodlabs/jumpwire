defmodule JumpWire.Websocket do
  @moduledoc """
  Establish a connection back to the frontend cluster for RPCs.
  """

  require Logger
  alias Phoenix.Channels.GenSocketClient
  alias JumpWire.PubSub
  @behaviour GenSocketClient

  @initial_backoff :timer.seconds(1)

  def name(), do: Hydrax.Registry.pid_name(nil, __MODULE__)

  def call_if_connected(message) do
    try do
      GenSocketClient.call(name(), message)
    catch
      :exit, {:noproc, _} -> {:error, :not_connected}
    end
  end

  def push(event, message, opts \\ [])
  def push(event, message = %{organization_id: org_id}, opts) when not is_nil(org_id) do
    call_if_connected({:push, org_id, event, message, opts})
  end
  def push(event, message, _) do
    Logger.error("Failed to send #{event} event with invalid message: #{inspect message}")
    {:error, :invalid}
  end

  @doc """
  Generate a unique URL for performing a magic login.
  """
  def generate_token(nonce, type, org_id) do
    call_if_connected({:push_and_wait, org_id, "authz:generate_token", %{nonce: nonce, type: type}, []})
  end

  @doc """
  Request that the client's current privileges be expanded.
  """
  def request_access(client_id, manifest_id, org_id, permissions) do
    request = %{client_id: client_id, manifest_id: manifest_id, permissions: permissions}
    call_if_connected({:push_and_wait, org_id, "authz:access_request", request, []})
  end

  def list_clusters() do
    case call_if_connected(:list_clusters) do
      err = {:error, _} -> err
      clusters -> {:ok, clusters}
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500,
    }
  end

  def start_link(opts \\ []) do
    config = %{url: url} = Application.get_env(:jumpwire, :upstream)
    |> Keyword.merge(opts)
    |> Enum.into(%{})

    {ssl_verify, config} = Map.pop(config, :ssl_verify, :verify_peer)

    # Always perform server SSL certificate verification when using secure websockets.
    socket_opts =
      case {url, ssl_verify} do
        {_, :verify_none} -> []
        {"wss://" <> _rest, _} ->
          [cacertfile: CAStore.file_path(),
           depth: 3,
           customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
          ]
        _ -> []
      end

    # This module makes client calls in JumpWire.PubSub and JumpWire.Cloak.KeyRing.
    # Since it is dynamically supervised, there's no guarantee from the
    # applicaton supervision tree of those GenServers running when starting up.
    # Calling `Application.ensure_all_started/1 works around that.
    Application.ensure_all_started(:jumpwire)

    GenSocketClient.start_link(
      __MODULE__,
      GenSocketClient.Transport.WebSocketClient,
      config,
      [transport_opts: [ssl_verify: ssl_verify, socket_opts: socket_opts]],
      name: name()
    )
  end

  defp new_topic_state(), do: %{first_join: true, queue: :queue.new()}
  defp new_topic_state(org_id) do
    new_topic_state() |> Map.put(:org_id, org_id)
  end

  def init(%{url: nil} = opts) do
    Logger.debug("Websocket connection to frontend disabled")
    with {:ok, token} <- Map.fetch(opts, :token),
         {:ok, %{org: org_id}} <- JumpWire.token_claims(token) do
      JumpWire.Vault.load_keys(org_id)
      JumpWire.ConfigLoader.load(org_id)
    end

    :ignore
  end
  def init(%{params: params, token: token, url: url}) do
    Logger.info("Connecting to #{inspect url}")

    state = %{
      max_queue_size: 10_000,
      backoff: @initial_backoff,
      topic: nil,
      topics: %{},
      local_config: [],
      refs: %{},
    }
    params = Keyword.put(params, :token, token)

    case JumpWire.token_claims(token) do
      {:error, _} ->
        Logger.error("Invalid account token configured")
        :ignore

      {:ok, %{org: org_id, cluster: cluster_id}} ->
        JumpWire.Tracer.context(org_id: org_id)
        JumpWire.Vault.load_keys(org_id)
        topic = "cluster:#{cluster_id}"
        topics = %{topic => new_topic_state(org_id)}
        {:connect, url, params, %{state | topic: topic, topics: topics}}
    end
  end

  def handle_connected(transport, state) do
    GenSocketClient.join(transport, state.topic)
    {:ok, %{state | backoff: @initial_backoff}}
  end

  def handle_disconnected(reason, state = %{backoff: backoff}) do
    Logger.error("Socket disconnected: #{inspect(reason)}")
    Process.send_after(self(), :connect, backoff)
    backoff = min(backoff * 2, :timer.minutes(1))
    {:ok, %{state | backoff: backoff}}
  end

  def handle_joined(topic = "cluster:" <> _, _payload, transport, state) do
    Logger.info("Connected to channel #{topic}")
    JumpWire.StartupIndicator.notify_connected()
    topic_state = Map.fetch!(state.topics, topic)
    if topic_state.first_join do
      JumpWire.Vault.load_keys(topic_state.org_id)

      # Load any local configuration and sync it to the frontend
      {opts, config} = JumpWire.ConfigLoader.load(topic_state.org_id) |> Map.pop(:options)
      message = JumpWire.cluster_info(topic_state.org_id)
      message = if opts[:sync], do: Map.put(message, "config", config), else: message

      {:ok, _ref} = GenSocketClient.push(transport, topic, "cluster:start", message)

      if not :queue.is_empty(topic_state.queue) do
        Process.send_after(self(), {:push_queue, topic}, 0)
      end

      state = Map.put(state, :local_config, opts)
      {:ok, state}
    else
      {:ok, state}
    end
  end

  def handle_join_error(topic, payload, _transport, state) do
    Logger.error("Join error for #{topic}: #{inspect(payload)}")
    # TODO: bail out on an auth error, otherwise backoff and retry
    {:ok, state}
  end

  def handle_channel_closed(topic, payload, _transport, state) do
    Logger.error("Disconnected from  #{topic}: #{inspect(payload)}")
    Process.send_after(self(), {:join, topic}, :timer.seconds(1))
    {:ok, state}
  end

  def handle_reply(
    _topic,
    _ref,
    %{"response" => resp = %{
        "organization_id" => org_id,
        "schemas" => schemas,
      }
    },
    _transport,
    state
  ) do
    # parse configuration from JSON into the cluster global tables
    config = [:policies, :manifests, :client_auth, :metastores]
    |> Stream.map(fn key ->
      result = resp
      |> Map.get(to_string(key), [])
      |> JumpWire.ConfigLoader.from_json(org_id, key, state.local_config)

      {key, result}
    end)
    |> Map.new()

    # wait for all the manifest hooks to run to avoid a race condition
    # with schema hooks
    config.manifests
    |> Enum.map(fn {_, m} -> JumpWire.Manifest.hook(m, :insert) end)
    |> Task.await_many()

    schemas = Enum.reduce(schemas, [], fn schema, acc ->
      case JumpWire.Proxy.Schema.from_json(schema, org_id) do
        {:ok, schema} ->
          JumpWire.Proxy.Schema.hook(schema, :insert)
          [{{org_id, schema.manifest_id, schema.name}, schema} | acc]
        {:error, err} ->
          Logger.error("Could not convert schema object, skipping: #{inspect err}")
          acc
      end
    end)
    JumpWire.GlobalConfig.set(:proxy_schemas, org_id, schemas)

    Task.Supervisor.async_nolink(JumpWire.ProxySupervisor, &JumpWire.Proxy.measure_databases/0)

    {:ok, state}
  end

  def handle_reply(_topic, ref, payload, _transport, state) do
    {from, refs} = Map.pop(state.refs, ref)
    unless is_nil(from) do
      resp =
        case payload do
          %{"status" => "ok", "response" => resp} -> {:ok, resp}
          %{"response" => resp} -> {:error, resp}
          _ -> {:error, payload}
        end
      GenSocketClient.reply(from, resp)
    end
    {:ok, %{state | refs: refs}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, _transport, state) do
    # Some task spawned from the GenServer crashed
    {:ok, state}
  end

  def handle_info({ref, _}, _transport, state) when is_reference(ref) do
    # result from a hook task
    Process.demonitor(ref, [:flush])
    {:ok, state}
  end

  def handle_info(:connect, _transport, state) do
    {:connect, state}
  end

  def handle_info({:join, topic}, transport, state) do
    GenSocketClient.join(transport, topic)
    {:ok, state}
  end

  def handle_info({:push_queue, topic}, transport, state) do
    Logger.debug("Attempting to send all queued events for #{topic}")
    events = state |> get_in([:topics, topic, :queue]) |> :queue.to_list()
    queue = Enum.reduce(events, :queue.new(), fn {event, message}, queue ->
      case GenSocketClient.push(transport, topic, event, message) do
        {:ok, _} -> queue
        {:error, err} ->
          Logger.error("Failed to send event: #{inspect err}")
          :queue.in({event, message}, queue)
      end
    end)
    state = put_in(state, [:topics, topic, :queue], queue)
    {:ok, state}
  end

  def handle_message("organizations", "new", msg = %{"external_id" => org_id}, transport, state) do
    Logger.info("New organization reported: #{org_id}")
    topic = Map.get(msg, "topic", "cluster:#{org_id}")
    JumpWire.Vault.load_keys(org_id)
    GenSocketClient.join(transport, topic)
    state = put_in(state, [:topics, topic], new_topic_state(org_id))
    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "cluster:info", _msg, transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    {:ok, _} = send_cluster_info(transport, topic, org_id)
    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "policy:create", policy, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.Policy.from_json(policy, org_id) do
      {:ok, policy} ->
        PubSub.broadcast("*", {:update, :policy, policy})
        JumpWire.GlobalConfig.put(:policies, policy)
        JumpWire.Policy.hook(policy, :insert)

      {:error, err} ->
        Logger.error("Unable to convert new policy object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "policy:update", policy, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.Policy.from_json(policy, org_id) do
      {:ok, policy} ->
        PubSub.broadcast("*", {:update, :policy, policy})
        JumpWire.GlobalConfig.put(:policies, policy)
        JumpWire.Policy.hook(policy, :update)

      {:error, err} ->
        Logger.error("Unable to convert updated policy object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "policy:delete", policy, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.Policy.from_json(policy, org_id) do
      {:ok, policy} ->
        PubSub.broadcast("*", {:delete, :policy, policy})
        JumpWire.GlobalConfig.delete(:policies, {policy.organization_id, policy.id})
        JumpWire.Policy.hook(policy, :delete)

      {:error, err} ->
        Logger.error("Unable to convert deleted policy object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "client_auth:create", client, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.ClientAuth.from_json(client, org_id) do
      {:ok, client} ->
        PubSub.broadcast("*", {:update, :client_auth, client})
        JumpWire.GlobalConfig.put(:client_auth, client)
        JumpWire.ClientAuth.hook(client, :insert)

      {:error, err} ->
        Logger.error("Unable to convert new client auth object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "client_auth:update", client, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.ClientAuth.from_json(client, org_id) do
      {:ok, client} ->
        PubSub.broadcast("*", {:update, :client_auth, client})
        JumpWire.GlobalConfig.put(:client_auth, client)
        JumpWire.ClientAuth.hook(client, :update)

      {:error, err} ->
        Logger.error("Unable to convert updated client auth object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "client_auth:delete", client, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.ClientAuth.from_json(client, org_id) do
      {:ok, client} ->
        PubSub.broadcast("*", {:delete, :client_auth, client})
        JumpWire.GlobalConfig.delete(:client_auth, {client.organization_id, client.id})
        JumpWire.ClientAuth.hook(client, :delete)

      {:error, err} ->
        Logger.error("Unable to convert deleted client auth object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(
    topic = "cluster:" <> _,
    "client_auth:authenticated",
    %{"client" => client, "manifest_id" => manifest_id, "nonce" => nonce},
    _transport,
    state
  ) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.ClientAuth.from_json(client, org_id) do
      {:ok, client} ->
        PubSub.broadcast("*", {:client_authenticated, org_id, manifest_id, nonce, client})

      {:error, err} ->
        Logger.error("Unable to convert client auth object in authorization message: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(
    topic = "cluster:" <> _,
    "client_auth:authorization_approved",
    %{"id" => id, "client_id" => client_id, "manifest_id" => manifest_id, "expires_at" => _expires_at},
    _transport,
    state
  ) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    case JumpWire.ClientAuth.fetch(org_id, client_id) do
      {:ok, _client} ->
        PubSub.broadcast("*", {:client_authorized, org_id, manifest_id, client_id, id})

      err ->
        Logger.error("Unable to update client auth with new authorization: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "manifest:create", manifest, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, manifest} <- JumpWire.Manifest.from_json(manifest, org_id),
         {:ok, manifest} <- JumpWire.Credentials.store(manifest) do
      PubSub.broadcast("*", {:update, :manifest, manifest})
      JumpWire.Manifest.hook(manifest, :insert)
      JumpWire.GlobalConfig.put(:manifests, manifest)
      {:ok, state}
    else
      {:error, err} ->
        Logger.error("Unable to convert new manifest object: #{inspect err}")
        {:ok, state}
    end
  end

  def handle_message(topic = "cluster:" <> _, "manifest:update", manifest, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, manifest} <- JumpWire.Manifest.from_json(manifest, org_id),
         {:ok, manifest} <- JumpWire.Credentials.store(manifest) do
      PubSub.broadcast("*", {:update, :manifest, manifest})
      JumpWire.Manifest.hook(manifest, :update)
      JumpWire.GlobalConfig.put(:manifests, manifest)
    else
      {:error, err} ->
        Logger.error("Unable to convert updated manifest object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "manifest:delete", manifest, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, manifest} <- JumpWire.Manifest.from_json(manifest, org_id),
         {:ok, _} <- JumpWire.Credentials.delete(manifest) do
      org_id = manifest.organization_id
      PubSub.broadcast("*", {:delete, :manifest, manifest})
      JumpWire.GlobalConfig.delete(:manifests, {org_id, manifest.id})
      JumpWire.GlobalConfig.delete(:proxy_schemas, {org_id, manifest.id, :_})
      JumpWire.Manifest.hook(manifest, :delete)
    else
      {:error, err} ->
        Logger.error("Unable to convert deleted manifest object: #{inspect err}")
    end
    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "metastore:create", metastore, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, metastore} <- JumpWire.Metastore.from_json(metastore, org_id),
         {:ok, metastore} <- JumpWire.Credentials.store(metastore) do
      PubSub.broadcast("*", {:update, :metastore, metastore})
      JumpWire.Metastore.hook(metastore, :insert)
      JumpWire.GlobalConfig.put(:metastores, metastore)
      {:ok, state}
    else
      {:error, err} ->
        Logger.error("Unable to convert new metastore object: #{inspect err}")
        {:ok, state}
    end
  end

  def handle_message(topic = "cluster:" <> _, "metastore:update", metastore, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, metastore} <- JumpWire.Metastore.from_json(metastore, org_id),
         {:ok, metastore} <- JumpWire.Credentials.store(metastore) do
      PubSub.broadcast("*", {:update, :metastore, metastore})
      JumpWire.Metastore.hook(metastore, :update)
      JumpWire.GlobalConfig.put(:metastores, metastore)
    else
      {:error, err} ->
        Logger.error("Unable to convert updated metastore object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "metastore:delete", metastore, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, metastore} <- JumpWire.Metastore.from_json(metastore, org_id),
         {:ok, _} <- JumpWire.Credentials.delete(metastore) do
      org_id = metastore.organization_id
      PubSub.broadcast("*", {:delete, :metastore, metastore})
      JumpWire.GlobalConfig.delete(:metastores, {org_id, metastore.id})
      JumpWire.GlobalConfig.delete(:proxy_schemas, {org_id, metastore.id, :_})
      JumpWire.Metastore.hook(metastore, :delete)
    else
      {:error, err} ->
        Logger.error("Unable to convert deleted metastore object: #{inspect err}")
    end
    {:ok, state}
  end

  def handle_message(
    topic = "cluster:" <> _,
    "manifest:extract_schemas",
    manifest = %{"id" => id},
    transport,
    state
  ) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, manifest} <- JumpWire.Manifest.from_json(manifest, org_id),
         {:ok, schemas} <- JumpWire.Manifest.extract_schemas(manifest) do
      msg = %{"schemas" => schemas, "manifest" => manifest.id}
      case GenSocketClient.push(transport, topic, "manifest:schemas", msg) do
        {:ok, _} -> nil
        err -> Logger.error(inspect err)
      end
    else
      err ->
        Logger.error("Unable to extract schemas from manifest: #{inspect err}")
        msg = %{"manifest" => id, "error" => true}
        GenSocketClient.push(transport, topic, "manifest:schemas", msg)
    end
    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "schema:labels", schema, _transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, schema} <- JumpWire.Proxy.Schema.from_json(schema, org_id) do
      PubSub.broadcast("*", {:update, :schema_labels, schema})
      key = {schema.organization_id, schema.manifest_id, schema.name}
      JumpWire.GlobalConfig.put(:proxy_schemas, key, schema)
      JumpWire.Proxy.Schema.hook(schema, :insert)
    else
      {:error, err} -> Logger.error("Unable to convert schema object: #{inspect err}")
    end

    {:ok, state}
  end

  def handle_message(topic = "cluster:" <> _, "vault:rotate", _msg, transport, state) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    :ok = JumpWire.Vault.rotate(org_id)
    {:ok, _} = send_cluster_info(transport, topic, org_id)
    {:ok, state}
  end

  # Extracts schema for given manifest.
  def handle_message(
        topic = "cluster:" <> _,
        "manifest:fetch_schemas_for_refresh",
        manifest = %{"id" => id},
        transport,
        state
  ) do
    org_id = Map.fetch!(state.topics, topic) |> Map.fetch!(:org_id)
    with {:ok, manifest} <- JumpWire.Manifest.from_json(manifest, org_id),
         {:ok, schemas} <- JumpWire.Manifest.extract_schemas(manifest) do
      msg = %{"manifest_id" => id, "schemas" => schemas}

      case GenSocketClient.push(transport, topic, "manifest:schemas_for_refresh", msg) do
        {:ok, _} -> nil
        err -> Logger.error(inspect(err))
      end
    else
      err ->
        Logger.error("Unable to extract schemas from manifest: #{inspect(err)}")
        msg = %{"manifest_id" => id, "error" => true}
        GenSocketClient.push(transport, topic, "manifest:schemas_for_refresh", msg)
    end

    {:ok, state}
  end

  def handle_message(_topic, event, msg, _transport, state) do
    Logger.debug("Unknown admin message on #{event}: #{inspect msg}")
    {:ok, state}
  end

  def handle_call({:push, org_id, event, message, opts}, _from, transport, state) do
    # No more than one cluster should be connected per org
    {topic, _} = state.topics
    |> Stream.filter(&cluster_topic?/1)
    |> Enum.find(fn {_, state} -> state.org_id == org_id end)

    resp = GenSocketClient.push(transport, topic, event, message)
    state =
      case resp do
        {:ok, _} -> state
        {:error, err} ->
          if !opts[:silent_push],
            do: Logger.error("Failed to send event to #{topic}: #{inspect err}")
          queue = check_queue_size(state, topic)
          queue = :queue.in({event, message}, queue)
          put_in(state, [:topics, topic, :queue], queue)
      end
    {:reply, resp, state}
  end

  def handle_call({:push_and_wait, org_id, event, message, opts}, from, transport, state) do
    # No more than one cluster should be connected per org
    {topic, _} = state.topics
    |> Stream.filter(&cluster_topic?/1)
    |> Enum.find(fn {_, state} -> state.org_id == org_id end)

    case GenSocketClient.push(transport, topic, event, message) do
      {:ok, ref} ->
        state = put_in(state, [:refs, ref], from)
        {:noreply, state}

      {:error, err} ->
        if !opts[:silent_push],
          do: Logger.error("Failed to send event to #{topic}: #{inspect err}")
        queue = check_queue_size(state, topic)
        queue = :queue.in({event, message}, queue)
        state = put_in(state, [:topics, topic, :queue], queue)
        {:reply, {:error, err}, state}
    end
  end

  def handle_call(:list_clusters, _from, _transport, state) do
    clusters = state.topics
    |> Stream.filter(&cluster_topic?/1)
    |> Stream.map(fn {topic, _} -> topic end)
    |> Stream.map(fn topic -> {topic, GenSocketClient.joined?(topic)} end)
    |> Stream.map(fn {topic, joined} ->
      name = String.trim_leading(topic, "cluster:")
      {name, joined}
    end)
    |> Map.new()

    {:reply, clusters, state}
  end

  def handle_call(message, _from, _transport, state) do
    Logger.warn("Did not expect to receive call with message: #{inspect message}")
    {:reply, {:error, :unexpected_message}, state}
  end

  defp send_cluster_info(transport, topic, org_id) do
    message = JumpWire.cluster_info(org_id)
    GenSocketClient.push(transport, topic, "cluster:info", message)
  end

  defp check_queue_size(state, topic) do
    queue = get_in(state, [:topics, topic, :queue])
    if :queue.len(queue) > state.max_queue_size do
      Logger.error("Queue is too long, dropping oldest event")
      :queue.drop(queue)
    else
      queue
    end
  end

  defp cluster_topic?({name, _}), do: String.starts_with?(name, "cluster:")
end
