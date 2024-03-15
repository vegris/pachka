%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, false},
        {Credo.Check.Readability.AliasOrder, false}
      ]
    }
  ]
}
