defmodule JumpWire.Schema do
  defmacro __using__(_arg) do
    quote do
      use TypedEctoSchema
      import PolymorphicEmbed

      @primary_key {:id, Ecto.UUID, autogenerate: false}
      @foreign_key_type Ecto.UUID
      @timestamps_opts [type: :utc_datetime]
      @derive Jason.Encoder
    end
  end
end
