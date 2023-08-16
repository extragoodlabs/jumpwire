defmodule Ecto.Any do
  use Ecto.Type

  def type(), do: :any
  def cast(val), do: {:ok, val}
  def load(val), do: {:ok, val}
  def dump(val), do: {:ok, val}
end
