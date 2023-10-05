defmodule JumpWire.Schema.LabelsForManifest do
  alias JumpWire.Schema.LabelsForTerm

  @spec extract(JumpWire.Manifest.t()) :: list | {:error, any}
  def extract(manifest = %{root_type: :postgresql}) do
    with {:ok, %{schemas: schemas}} <- JumpWire.Manifest.Postgresql.extract(manifest) do
      # Flatten extracted schemas into a tuple of [schema name, column name]
      Enum.flat_map(schemas, fn {schemaname, %{"properties" => columns}} ->
        Enum.map(columns, fn {colname, _} -> [schemaname, colname] end)
      end)
      # Remove "reserved" tables from the list
      |> Enum.reject(fn [schemaname, _colname] -> schemaname == "jumpwire_proxy_schema_fields" end)
      |> Enum.reject(fn [_schemaname, colname] -> String.ends_with?(colname, "id") end)
      |> Enum.map(fn [schemaname, colname] -> [schemaname, colname, LabelsForTerm.labels(colname)] end)
      |> Enum.reject(fn [_, _, labels] -> is_nil(labels) end)
      |> Enum.map(fn [schemaname, colname, labels] -> {schemaname <> "." <> colname, labels} end)
      |> Map.new()
    end
  end
end
