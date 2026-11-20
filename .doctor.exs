%Doctor.Config{
  # These private implementation modules have @moduledoc false.
  ignore_modules: [
    ~r/^Jido\.Statechart\.(Configuration|Conformance|SCXML|Sends|Turn)(\.|$)/,
    Jido.Statechart.Plugin.Commit,
    Jido.Statechart.Plugin.Effects
  ],
  min_module_doc_coverage: 100,
  min_overall_doc_coverage: 100,
  min_overall_spec_coverage: 100
}
