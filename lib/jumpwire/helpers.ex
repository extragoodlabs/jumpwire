defmodule JumpWire.Helpers do
  @doc """
  Safely cast a string to an existing atom.
  """
  def to_atom(value) when is_binary(value) do
    try do
      {:ok, String.to_existing_atom(value)}
    rescue
      _ -> :error
    end
  end

  def to_atom(value) when is_atom(value), do: {:ok, value}
  def to_atom(_), do: :error
end
