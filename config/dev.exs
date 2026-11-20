import Config

config :git_hooks,
  auto_install: false,
  hooks: [
    commit_msg: [
      tasks: [{Mix.Tasks.GitOps.CheckMessage, :run}]
    ]
  ]

config :git_ops,
  no_igniter?: true,
  mix_project: Jido.Statechart.MixProject,
  changelog_file: "CHANGELOG.md",
  repository_url: "https://github.com/agentjido/jido_statechart",
  manage_mix_version?: true,
  version_tag_prefix: "v"
