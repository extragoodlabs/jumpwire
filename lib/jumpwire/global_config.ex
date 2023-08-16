defmodule JumpWire.GlobalConfig do
  use JumpWire.ETS, tables: [
    :policies,
    :client_auth,
    :metastores,
    :manifests,
    :proxy_schemas,
    :groups,
    :tokens,
    :reverse_schemas,
    :manifest_metadata,
    :manifest_table_metadata,
    :certificates,
    :samly_assertions,
  ]
end
