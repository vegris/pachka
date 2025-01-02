%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Readability.AliasOrder, []}
        ],
        extra: [
          {Credo.Check.Readability.StrictModuleLayout, []}
        ]
      }
    }
  ]
}
