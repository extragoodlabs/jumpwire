defmodule JumpWire.Policy do
  @moduledoc """
  A policy sets rules for how data should be manipulated. Each policy
  contains a set of attributes and a handling action.

  By default, a policy applies its action unless it matches the attributes
  of the request. Attributes are matched as a two layer boolean tree:
  each set of attributes are ANDed together, and each resulting group is
  ORed. This means that a request must match all of the attributes for
  any one group to be excluded from the handling action.
  """

  use JumpWire.Schema
  require Logger
  alias JumpWire.Record
  alias __MODULE__
  import Ecto.Changeset

  @typedoc """
  Result of applying policy.
  """
  @type result :: Record.t | :blocked | {:error, atom()}

  @callback handle(Record.t, matches :: map, Policy.t, request :: map)
  :: {:cont, Record.t} | {:halt, result} | {:skip, Record.t} | {{:skip, atom}, Record.t}

  typed_embedded_schema null: false do
    field :version, :integer, default: 2
    field :name, :string
    field :attributes, {:array, Ecto.MapSet}, default: []
    field :apply_on_match, :boolean, default: false
    field :handling, Ecto.Enum, values: [:access, :block, :drop_field, :encrypt, :tokenize, :resolve_fields]
    field :label, :string
    field :allowed_classification, :string
    field :encryption_key, Ecto.Atom, default: :aes
    field :organization_id, :string
    field :client_id, :string

    polymorphic_embeds_one :configuration,
      types: [resolve_fields: JumpWire.Policy.ResolveFields],
      on_replace: :update,
      on_type_not_found: :changeset_error,
      type_field: :type
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:version, :handling, :label, :name, :attributes, :id, :encryption_key, :allowed_classification, :organization_id, :apply_on_match, :client_id])
    |> validate_required([:handling, :label, :name, :id, :organization_id])
    |> validate_inclusion(:version, 1..2)
    |> versioned_validation()
    |> cast_polymorphic_embed(:configuration)
  end

  def from_json(policy, org_id) do
    %Policy{organization_id: org_id}
    |> changeset(policy)
    |> apply_action(:insert)
  end

  def versioned_validation(changeset) do
    case get_field(changeset, :version) do
      2 -> changeset |> validate_required([:attributes])
      _ -> changeset
    end
  end

  def hook(policy = %Policy{handling: handling, organization_id: org_id}, _lifecycle) when handling in [:encrypt, :tokenize] do
    Task.Supervisor.async_nolink(JumpWire.ProxySupervisor, fn ->
      JumpWire.Tracer.context(org_id: org_id, policy: policy.id)
      proxy_types = JumpWire.Manifest.proxy_types()

      JumpWire.GlobalConfig.all(:manifests, {org_id, :_})
      |> Stream.filter(fn %{root_type: type} -> Enum.member?(proxy_types, type) end)
      |> Enum.each(fn manifest ->
        case manifest.root_type do
          :postgresql -> JumpWire.Proxy.Postgres.Setup.enable_tables(manifest)
          :mysql -> JumpWire.Proxy.MySQL.Setup.enable_tables(manifest)

          t ->
            Logger.error("Unable to update metadata from policy, unknown type #{t}")
        end
        JumpWire.PubSub.broadcast("*", {:setup, :policy, policy})
      end)

      JumpWire.Proxy.measure_databases()
    end)
  end
  def hook(_, _), do: Task.completed(:ok)

  @action_order Enum.with_index([:access, :block, :drop_field, :resolve_fields, :encrypt, :tokenize])
  @doc """
  List all known policies for a given org. Policies are ordered based on the handling action.
  """
  def list_all(org_id) do
    JumpWire.GlobalConfig.all(:policies, {org_id, :_})
    |> Enum.sort_by(fn policy -> @action_order[policy.handling] end)
  end

  def apply_policies(policies, record, request) do
    if map_size(record.labels) == 0 do
      # shortcut to skip policies if there are no labels on the data
      record
    else
      case reduce_policies(policies, record, request) do
        {record = %Record{}, _skip} -> record
        res -> res
      end
    end
  end

  defp reduce_policies(policies, record, request) do
    Enum.reduce_while(policies, {record, []}, fn p, {record, skip_labels} ->
      if {p.label, p.handling} in skip_labels do
        {:cont, {record, skip_labels}}
      else
        case apply_policy(p, record, request) do
          {{:skip, handling}, record} ->
            {:cont, {record, [{p.label, handling} | skip_labels]}}

          {:cont, record} ->
            {:cont, {record, skip_labels}}

          res -> res
        end
      end
    end)
  end

  @spec apply_policy(policy :: Policy.t, record :: Record.t, request :: map)
  :: {:cont, Record.t} | {:halt, result}
  def apply_policy(policy, record = %Record{data: data}, request) when is_map(data) do
    with {:ok, mod} <- action_module(policy, request),
         matches when map_size(matches) > 0 <- Record.filter_by_label(record, policy.label) do
      Logger.debug("Applying policy '#{policy.name}' to record")
      mod.handle(record, matches, policy, request)
    else
      # NB: The fallthrough indicates that either the client should be excluded based on
      # attributes, or no fields match the policy label.
      _ -> {:cont, record}
    end
  end
  def apply_policy(policy, record = %Record{data: data}, stage) when is_list(data) do
    # Because we are iterating over each list element, we need to update the label(s) to
    # account for that fact. Instead of `$.[*].foo`, the policy should be applied to `$.foo`
    new_labels =
      record.labels
      |> Enum.map(fn {k, v} -> {String.replace(k, "$.[*].", "$."), v} end)
      |> Map.new()

    Enum.reduce_while(data, [], fn d, acc ->
      case apply_policy(policy, %{record | data: d, labels: new_labels}, stage) do
        {:cont, %{data: value}} ->
          {:cont, [value | acc]}
        {:halt, result} ->
          {:halt, {:halt, result}}
      end
    end)
    |> case do
      {:halt, result} ->
        {:halt, result}

      results ->
        {:cont, %{record | data: Enum.reverse(results)}}
    end
  end
  def apply_policy(_, record, _) do
    Logger.warn("Data is being sent in an unknown format, policies cannot be applied")
    {:cont, record}
  end

  defp action_module(policy, request) do
    cond do
      request_match?(policy, request) ->
        module_from_action(policy, request)

      policy.version == 2 and policy.handling == :encrypt ->
        {:ok, Policy.Decrypt}

      policy.version == 2 and policy.handling == :tokenize ->
        {:ok, Policy.Detokenize}

      true ->
        :error
    end
  end

  defp request_match?(policy = %Policy{version: 2}, request) do
    # Check the attributes of the request against the policy
    attribute_match = Enum.any?(policy.attributes, fn group ->
      missing = MapSet.difference(group, request.attributes)
      if MapSet.size(missing) == 0 do
        # all attributes of the policy group are present in the request
        true
      else
        case Enum.split_with(missing, fn a -> String.starts_with?(a, "not:") end) do
          {inverse_attrs, []} ->
            inverse_attrs = inverse_attrs |> Stream.map(fn "not:" <> rest -> rest end) |> MapSet.new()
            # match the request if any of these inverted attributes are present
            MapSet.disjoint?(request.attributes, inverse_attrs)

          _ ->
            # the request is missing attributes that are not prefixed with `not`
            false
        end
      end
    end)

    if policy.apply_on_match do
      attribute_match
    else
      not attribute_match
    end
  end
  defp request_match?(%Policy{allowed_classification: nil}, _), do: true
  defp request_match?(policy = %Policy{handling: handling}, request)
  when handling in [:block, :drop_field] do
    # check if the client is included by the policy. By default all clients are included,
    # so this function looks at any exclusion rules to find exceptions.
    request.classification != policy.allowed_classification
  end
  defp request_match?(policy = %Policy{handling: :resolve_fields}, request) do
    # resolve_fields should only apply when classifications match
    request.classification == policy.allowed_classification and not is_nil(request.classification)
  end
  defp request_match?(_, _), do: true

  defp module_from_action(%Policy{handling: handling, version: 2}, _request) do
    module_from_action(handling)
  end

  defp module_from_action(policy = %Policy{handling: :encrypt}, request) do
    handling = cond do
      is_nil(policy.allowed_classification) -> :encrypt
      request.classification == policy.allowed_classification -> :decrypt
      true -> :encrypt
    end

    module_from_action(handling)
  end

  defp module_from_action(policy = %Policy{handling: :tokenize}, request) do
    handling = cond do
      is_nil(policy.allowed_classification) -> :tokenize
      request.classification == policy.allowed_classification -> :detokenize
      true -> :tokenize
    end

    module_from_action(handling)
  end

  defp module_from_action(policy = %Policy{}, _request) do
    module_from_action(policy.handling)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp module_from_action(handling) do
    mod =
      case handling do
        :access -> Policy.Access
        :block -> Policy.Block
        :drop_field -> Policy.DropField
        :encrypt -> Policy.Encrypt
        :decrypt -> Policy.Decrypt
        :tokenize -> Policy.Tokenize
        :detokenize -> Policy.Detokenize
        :resolve_fields -> Policy.ResolveFields
        _ ->
          Logger.error("Policy handling #{handling} not implemented")
          nil
      end

    case mod do
      nil -> :error
      _ -> {:ok, mod}
    end
  end
end
