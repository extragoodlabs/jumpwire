defmodule Ecto.Tuple do
  @moduledoc """
  Custom Type to support tuples as used for aggregate values.
  """

  use Ecto.Type

  def type(), do: :tuple

  def cast(nil), do: {:ok, nil}
  def cast(data), do: decode_data(data)

  def load(nil), do: {:ok, nil}
  def load(data), do: decode_data(data)

  def dump(nil), do: {:ok, nil}
  def dump(data) do
    result = data |> Tuple.to_list() |> Jason.encode()
    case result do
      {:ok, _} -> result
      _ -> :error
    end
  end

  defp decode_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, list} -> decode_data(list)
      _ -> :error
    end
  end

  defp decode_data(data = [head | _]) when is_atom(head) do
    {:ok, List.to_tuple(data)}
  end

  defp decode_data([head | rest]) when is_binary(head) do
    value = [String.to_existing_atom(head) | rest] |> List.to_tuple()
    {:ok, value}
  end

  defp decode_data(data) when is_tuple(data), do: {:ok, data}

  defp decode_data(_), do: :error
end
