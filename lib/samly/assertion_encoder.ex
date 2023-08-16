defmodule Samly.AssertionEncoder do
  @moduledoc """
  Implementation of the Jason.Encoder protocol for Samly structs.
  """

  defimpl Jason.Encoder, for: Samly.Assertion do
    def encode(data, opts) do
      data
      |> Map.from_struct()
      |> Jason.Encoder.Map.encode(opts)
    end
  end

  defimpl Jason.Encoder, for: Samly.Subject do
    def encode(data, opts) do
      data
      |> Map.from_struct()
      |> Jason.Encoder.Map.encode(opts)
    end
  end
end
