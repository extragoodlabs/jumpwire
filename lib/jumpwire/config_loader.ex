defmodule JumpWire.ConfigLoader do
  @moduledoc """
  Load configuration objects from multiple sources and merge them together.
  """

  require Logger

  @modules [
    policies: JumpWire.Policy,
    manifests: JumpWire.Manifest,
    client_auth: JumpWire.ClientAuth,
    metastores: JumpWire.Metastore,
    proxy_schemas: JumpWire.Proxy.Schema,
    groups: JumpWire.Group,
  ]

  @default_opts [generate_ids: false, sync: true, merge: false]

  @doc """
  Load JSONified objects.
  """
  def from_json(data, org_id, key, opts \\ []) do
    mod = find_module(key)
    gen_ids = Keyword.get(opts, :generate_ids, false)

    result = data
    |> Stream.map(fn data -> with_id(data, gen_ids) end)
    |> Enum.reduce(%{}, fn data, acc ->
      case mod.from_json(data, org_id) do
        {:ok, value = %JumpWire.Proxy.Schema{}} ->
          mod.hook(value, :insert) |> Task.await()
          Map.put(acc, {org_id, value.manifest_id, value.id}, value)

        {:ok, value} ->
          mod.hook(value, :insert) |> Task.await()
          Map.put(acc, {org_id, value.id}, value)

        {:error, err} ->
          Logger.error("Could not convert #{mod}, skipping: #{inspect err}")
          acc
      end
    end)

    case Keyword.get(opts, :merge) do
      "all" ->
        # merge the newly parsed objects with any existing ones
        JumpWire.GlobalConfig.put_all(key, result)

      _ ->
        # default to overwriting any existing configuration objects
        JumpWire.GlobalConfig.set(key, org_id, result)
    end

    result
  end

  defp with_id(data, true) when is_list(data) do
    Map.put_new_lazy(data, "id", &Uniq.UUID.uuid4/0)
  end
  defp with_id(data, _gen_ids), do: data

  @doc """
  Load objects from all configured stores.
  """
  def load(org_id), do: from_disk(org_id)

  @doc """
  Load configuration objects from YAML files located in a specified directory.
  """
  def from_disk(org_id), do: Application.get_env(:jumpwire, :config_dir) |> from_disk(org_id)

  def from_disk(path, org_id) do
    Logger.info("Loading configuration objects from #{path}")

    path
    |> Path.join("**/*.y{,a}ml")
    |> Path.wildcard()
    |> Stream.map(fn path ->
      case YamlElixir.read_from_file(path) do
        {:ok, contents} -> contents
        _ ->
          Logger.error("Could not read YAML file at #{path}")
          nil
      end
    end)
    |> Stream.filter(&is_map/1)
    |> Enum.reduce(%{}, fn contents, acc -> Map.merge(contents, acc) end)
    |> from_map(org_id)
  end

  def from_map(contents, org_id) do
    Logger.debug("Configuration: #{inspect contents}")

    {opts, contents} = Map.pop(contents, "global", %{})
    opts = convert_options(opts)

    Enum.reduce(@modules, %{options: opts}, fn {key, _}, acc ->
      result = contents
      |> Map.get(to_string(key), [])
      |> from_json(org_id, key, opts)
      |> Map.values()
      |> Stream.map(&JumpWire.Credentials.store/1)
      |> Stream.map(fn
        {:ok, val} -> val
        err ->
          Logger.error("Failed to store credentials: #{inspect err}")
          nil
      end)
      |> Enum.reject(&is_nil/1)

      Map.put(acc, key, result)
    end)
  end

  defp find_module(key) when is_binary(key), do: key |> String.to_existing_atom() |> find_module()
  defp find_module(key), do: Keyword.fetch!(@modules, key)

  defp convert_options(opts) do
    opts = opts
    |> Stream.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Enum.into([])

    Keyword.merge(@default_opts, opts)
  end
end
