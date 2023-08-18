defmodule MapSetEncoder do
  @moduledoc false

  defimpl Jason.Encoder, for: MapSet do
    def encode(data, opts) do
      data
      |> MapSet.to_list()
      |> Jason.Encoder.List.encode(opts)
    end
  end
end
