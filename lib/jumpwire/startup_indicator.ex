defmodule JumpWire.StartupIndicator do
  @moduledoc """
  Displays an useful message on JumpWire startup.
  """

  use GenServer, restart: :temporary
  require Logger

  @startup_check_interval 1_000

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def notify_connected() do
    GenServer.cast(__MODULE__, :notify_connected)
  end

  @doc """
  Displays the startup indicator message.

  This message is displayed after JumpWire connects to the `organizations`
  channel in a web controller if one is configured, or immediately on
  startup otherwise.
  """
  def show_indicator(org_id, host, kv_info) do
    # Infers this information based on whether GlobalConfig for manifests is empty
    has_manifests? = :ets.first(:manifests) != :"$end_of_table"

    base_msg =
      if has_manifests? or is_nil(host) do
        ""
      else
        "\nYou can set up your first connection at https://#{host}.\n"
      end

    version =
      case JumpWire.node_info() do
        {:ok, %{version: version}} -> version
        _ -> "unknown"
      end
    kv_info = [{"Version", version} | kv_info]

    info = kv_info
    |> Stream.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join("\n")

    JumpWire.UiLog.create(org_id, :info, "JumpWire engine version #{version} is up and connected to #{host}")

    connection_msg = unless is_nil(host), do: "and connected to #{host}"

    """

    ************************************************************
    The JumpWire engine is up#{connection_msg}!
    #{base_msg}
    Check out our documentation at https://docs.jumpwire.io.

    #{info}
    ************************************************************
    """
    |> IO.puts()
  end

  # Callbacks

  @impl true
  def init({org_id, user_msgs}) do
    case Application.get_env(:jumpwire, :upstream)[:url] do
      nil ->
        # When not connecting to a remote web controller, immediately show the startup message and exit
        if Application.get_env(:jumpwire, :environment) != :test do
          show_indicator(org_id, nil, user_msgs)
        end
        :ignore

      url ->
        Process.send_after(self(), {:check_startup, 0}, @startup_check_interval * 2)
        host = url |> URI.parse() |> Map.fetch!(:host)
        state = %{connected: false, indicator_shown: false, org_id: org_id, info: user_msgs, host: host}
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:check_startup, 30}, state) do
    Logger.debug("Giving up after 30 attempts")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:check_startup, _n}, state = %{connected: true}) do
    show_indicator(state.org_id, state.host, state.info)
    {:stop, :normal, %{indicator_shown: true}}
  end

  @impl true
  def handle_info({:check_startup, n}, state) do
    Process.send_after(self(), {:check_startup, n + 1}, @startup_check_interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:notify_connected, state) do
    {:noreply, %{state | connected: true}}
  end
end
