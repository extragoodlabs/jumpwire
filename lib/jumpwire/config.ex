defmodule JumpWire.Config do
  @moduledoc """
  Helpers for working with application config, primarily through environmental variables.
  """

  @doc """
  Get a value from an env var and cast it to a boolean.

  This will return `true` if the env var exists and is set to `true` or `1`, and `false` if the var is set
  to `false` or `0`. Any other value or a nonexistant env var will return the default.
  """
  @spec get_boolean_env(String.t, boolean) :: boolean
  def get_boolean_env(name, default) do
    case fetch_boolean_env(name) do
      {:ok, val} -> val
      :error -> default
    end
  end

  @spec fetch_boolean_env(String.t) :: {:ok, boolean} | :error
  def fetch_boolean_env(name) do
    case System.fetch_env(name) do
      {:ok, "1"} -> {:ok, true}
      {:ok, "0"} -> {:ok, false}

      {:ok, val} ->
        case String.downcase(val) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          _ -> :error
        end

      _ -> :error
    end
  end

  @spec fetch_integer_env(String.t) :: {:ok, integer} | :error
  def fetch_integer_env(name) do
    with {:ok, val} <- System.fetch_env(name),
         {val, ""} <- Integer.parse(val) do
      {:ok, val}
    else
      _ -> :error
    end
  end
end
