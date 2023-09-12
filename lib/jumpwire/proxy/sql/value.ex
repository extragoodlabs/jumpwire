defmodule JumpWire.Proxy.SQL.Value do
  @moduledoc """
  Literal values along with type information parsed into a SQL AST.
  """

  alias JumpWire.Proxy.SQL.Statement
  require Logger

  @doc """
  Turn a value from the SQL AST into a literal Elixir term, removing any wrappers from it.
  """
  @spec from_expr(Statement.value()) :: {:ok, boolean() | String.t() | number() | nil} | :error

  def from_expr(val) when is_binary(val) or is_boolean(val), do: {:ok, val}

  def from_expr({:number, val, _}) do
    case Integer.parse(val) do
      {n, ""} ->
        {:ok, n}

      :error ->
        Logger.error("Failed to parse invalid number from SQL query: #{val}")
        :error

      _ ->
        case Float.parse(val) do
          {n, ""} -> {:ok, n}
          _ ->
            Logger.error("Failed to parse invalid number from SQL query: #{val}")
            :error
        end
    end
  end

  def from_expr(%Statement.DollarQuotedString{value: val}), do: {:ok, val}

  def from_expr(:null), do: {:ok, nil}

  def from_expr(_), do: :error
end
