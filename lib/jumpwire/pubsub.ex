defmodule JumpWire.PubSub do
  alias Phoenix.PubSub

  def server(), do: __MODULE__

  def subscribe(topic, opts \\ []) when is_binary(topic), do: PubSub.subscribe(server(), topic, opts)

  def unsubscribe(topic) when is_binary(topic), do: PubSub.unsubscribe(server(), topic)

  def broadcast(topic, message), do: PubSub.broadcast(server(), topic, message)

  def broadcast!(topic, message), do: PubSub.broadcast!(server(), topic, message)

  def local_broadcaast(topic, message), do: PubSub.local_broadcast(server(), topic, message)
end
