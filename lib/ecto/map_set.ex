defmodule Ecto.MapSet do
  @moduledoc """
  Custom Type to support `MapSet`

  ```
  defmodule Post do
    use Ecto.Schema
    schema "posts" do
      field :atom_field, Ecto.MapSet
    end
  end
  ```
  """

  use Ecto.Type

  def type, do: :string

  def cast(value = %MapSet{}), do: {:ok, value}
  def cast(value) when is_list(value) do
    {:ok, MapSet.new(value)}
  end
  def cast(_), do: :error

  def load(value), do: {:ok, MapSet.new(value)}

  def dump(value = %MapSet{}), do: {:ok, MapSet.to_list(value)}
  def dump(_), do: :error
end
