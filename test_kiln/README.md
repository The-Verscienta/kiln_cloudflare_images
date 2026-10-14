# test_kiln/

Tests that need the KilnCMS core: `KilnCMS.DataCase`, `KilnCMS.Media.Ingest`,
the variant worker, adoption, `Kiln.ImageBackend.Registry` and the plugin
doctor. This plugin's own `mix test` never sees them (they aren't under
`test/`), because the plugin compiles against `kiln_plugin` alone.

CI runs them inside a kiln_cms checkout, with the plugin installed through
`config/project_deps.exs`. To run them locally, from a kiln_cms checkout:

```bash
echo '[{:kiln_cloudflare_images, path: "/path/to/kiln_cloudflare_images"}]' > config/project_deps.exs
MIX_ENV=test mix deps.get
mix test /path/to/kiln_cloudflare_images/test_kiln
```

Remove `config/project_deps.exs` and `config/project.lock` afterwards.
