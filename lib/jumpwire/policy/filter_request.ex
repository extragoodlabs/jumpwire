defmodule JumpWire.Policy.FilterRequest do
  @moduledoc """
  Add a filter to each matching request.
  """

  use JumpWire.Schema
  import Ecto.Changeset
  alias JumpWire.Proxy.SQL.Parser
  require Logger

  @behaviour JumpWire.Policy

  @primary_key false
  typed_embedded_schema null: false do
    field :type, Ecto.Atom, default: :filter_request
    field :table, :string
    field :field, :string
    field :source, Ecto.Enum, values: [:user_id], default: :user_id
  end

  @doc false
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:type, :table, :field, :source])
    |> validate_required([:table, :field, :source])
  end

  @impl true
  def handle(record = %{source_data: ref}, _, policy, request) when is_reference(ref) do
    opts = policy.configuration

    with :user_id <- opts.source,
         {:ok, %{"jw_id" => id}} when is_binary(id) <- Map.fetch(request, :params) do
      case Parser.add_table_selection(ref, opts.table, opts.field, :eq, id) do
        :ok -> {:cont, record}
        err ->
          Logger.error("Unable to add filter to SQL request: #{inspect err}")
          {:halt, {:error, :sql_failure}}
      end
    else
      _ -> {:halt, {:error, :missing_sql_id}}
    end
  end

  def handle(record, _, _, _), do: {:cont, record}
end
