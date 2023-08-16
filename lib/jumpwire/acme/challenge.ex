defmodule JumpWire.ACME.Challenge do
  @moduledoc """
  A GenServer that stores ACME challenges and lets processes know when the
  challenge response is received.
  """

  use GenServer
  require Logger

  def name(), do: Hydrax.Registry.pid_name(nil, __MODULE__)

  def await_challenges(tokens) do
    GenServer.call(name(), {:await_challenges, tokens}, 60_000)
  end

  def got_challenge(token) do
    GenServer.call(name(), {:got_challenge, token})
  end

  def register_challenge(token, value) do
    GenServer.call(name(), {:register_challenge, token, value})
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: name())
  end

  @impl true
  def init(_) do
    state = %{client: nil, challenges: %{}, done: MapSet.new()}
    {:ok, state}
  end

  @impl true
  def handle_call({:register_challenge, token, value}, _from, state) do
    state = put_in(state, [:challenges, token], value)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:await_challenges, tokens}, from, state) do
    tokens = tokens |> MapSet.new() |> MapSet.difference(state.done)

    if MapSet.size(tokens) == 0 do
      {:reply, true, state}
    else
      {:noreply, %{state | client: {from, tokens}}}
    end
  end

  @impl true
  def handle_call({:got_challenge, token}, _from, state = %{challenges: challenges, client: client}) do
    Logger.debug("Challenge token #{token} received")

    value = Map.get(challenges, token)
    client = update_client(client, token)
    done = MapSet.put(state.done, token)

    {:reply, value, %{state | client: client, done: done}}
  end

  defp update_client(nil, _token), do: nil
  defp update_client({client, tokens}, token) do
    tokens = MapSet.delete(tokens, token)
    if MapSet.size(tokens) == 0 do
      GenServer.reply(client, true)
      nil
    else
      {client, tokens}
    end
  end
end
