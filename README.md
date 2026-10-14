# kiln_cloudflare_images

A [KilnCMS](https://github.com/The-Verscienta/kiln_cms) plugin that keeps new
image uploads in [Cloudflare Images](https://developers.cloudflare.com/images/)
and serves their sizes from it. It is the first implementation of Kiln's image
backend seam (`Kiln.ImageBackend`, [kiln_cms#1955](https://github.com/The-Verscienta/kiln_cms/issues/1955)).

With it selected:

- **New image uploads go to Cloudflare.** Kiln's storage key becomes the
  image's custom ID, after Kiln has stripped its metadata. Documents, video,
  audio, a site's own bucket, and any image whose metadata couldn't be stripped
  stay in Kiln's storage.
- **Variants and transforms are flexible variants.** Kiln records
  `imagedelivery.net` URLs for every responsive size and crop it would
  otherwise encode, and `/media/:id/t/…` redirects to Cloudflare after Kiln's
  own signing, allowlist and permission checks. Nothing is encoded or stored
  per size.
- **Everything else follows the item.** Downloads, rotation and deletion reach
  Cloudflare through Kiln's storage layer.
- **Images already in Cloudflare can be adopted.** Rows imported as
  `imagedelivery.net` URLs (a Directus migration, say) become ordinary Kiln
  media with `mix kiln.media.adopt_image_backend`.

## Requirements

- KilnCMS with `Kiln.ImageBackend`
  ([kiln_cms#1958](https://github.com/The-Verscienta/kiln_cms/pull/1958)) and
  the `config/project_deps.exs` hook
  ([kiln_cms#1979](https://github.com/The-Verscienta/kiln_cms/pull/1979)):
  the release after 1.3.0. The connection check needs `kiln_plugin` 1.2
  ([kiln_cms#1980](https://github.com/The-Verscienta/kiln_cms/pull/1980)).
- A Cloudflare account with Images, and an API token with **Cloudflare Images:
  Edit**.
- **Flexible variants** switched on: Cloudflare dashboard → Images → Delivery.
  Without them, set `CLOUDFLARE_IMAGES_FLEXIBLE_VARIANTS=false` and Kiln
  encodes each variant itself and uploads it as a separate image (more
  storage, still correct).

## Install

The plugin is a Mix dependency built on
[`kiln_plugin`](https://github.com/The-Verscienta/kiln_cms/blob/main/sdk/kiln_plugin/README.md),
Kiln's plugin contract. A site installs it through its overlay's
`config/project_deps.exs`
([kiln_cms#1967](https://github.com/The-Verscienta/kiln_cms/issues/1967)),
never by editing Kiln's own `mix.exs`:

```elixir
# config/project_deps.exs
[
  {:kiln_cloudflare_images,
   github: "The-Verscienta/kiln_cloudflare_images", tag: "v0.1.0"}
]
```

`mix deps.get` then locks it in `config/project.lock`, leaving Kiln's
`mix.lock` alone. Commit both files in the overlay, next to
`config/project.exs`.

Then register the plugin and select its backend in `config/project.exs`:

```elixir
config :kiln_cms, :plugins, [KilnCloudflareImages.Plugin]
config :kiln_cms, :image_backend, KilnCloudflareImages.Backend
```

`mix kiln.plugins.doctor` checks both lines, and that this plugin's
`kiln_plugin` requirement accepts the version Kiln bundles.

## Configure

Set these in the environment, or under `config :kiln_cms, KilnCloudflareImages`
with the key in brackets. The names match the ones Verscienta's frontend
already uses.

| Variable | Key | |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | `:account_id` | required |
| `CLOUDFLARE_IMAGES_TOKEN` | `:api_token` | required; *Cloudflare Images: Edit* |
| `CLOUDFLARE_IMAGES_ACCOUNT_HASH` | `:account_hash` | required; the hash in your delivery URLs |
| `CLOUDFLARE_IMAGES_VARIANT` | `:variant` | named variant for an item's plain URL; default `public` |
| `CLOUDFLARE_IMAGES_DELIVERY_BASE` | `:delivery_base` | default `https://imagedelivery.net/<hash>`; set it to serve from your own domain (`https://example.com/cdn-cgi/imagedelivery/<hash>`) |
| `CLOUDFLARE_IMAGES_FLEXIBLE_VARIANTS` | `:flexible_variants` | default `true` |

Until the three required settings are present, the backend reports itself
unconfigured and Kiln keeps storing images locally. **System → Image backend**
says which state it's in, asks Cloudflare whether the account ID and token
work (it reads the account's image count and allowance, which any Images
token may), and counts the site's images that are here, that could be
adopted, and that point elsewhere.

The delivery origin is added to the browser CSP's `img-src` automatically while
the backend is selected. If you later switch to another backend, keep this
origin in `CSP_IMG_SRC`, or the images still held here render blank.

## Adopting an imported library

```bash
mix kiln.media.adopt_image_backend --dry-run   # count only
mix kiln.media.adopt_image_backend             # --org <uuid> for another site
```

This takes every media row that has no stored file and whose URL is one of
this account's delivery URLs, including the bare `…/<hash>/<id>` form some
importers stored and IDs with subpaths (`…/<hash>/blog/hero.jpg/public`).
`imagedelivery.net` URLs count even after you set a custom
`CLOUDFLARE_IMAGES_DELIVERY_BASE`. It records the image's ID on the row and enqueues its
variants. Rows pointing anywhere else are left alone.

## How Kiln's sizes map to Cloudflare

| Kiln asks for | URL options |
|---|---|
| a responsive size | `w=…,h=…,fit=scale-down` |
| a focal-point crop (the `card` variant, or a transform with `fit=cover`) | `trim=top;right;bottom;left,w=…,h=…,fit=cover`, with the crop window in source pixels |
| WebP / AVIF / JPEG | `f=webp` / `f=avif` / `f=jpeg` |
| PNG or GIF | no `f`, so the source format is kept (Cloudflare has no PNG or GIF output) |
| a lossy quality | `q=…`, from Kiln's own `:image_variants` settings |

Every URL also carries `metadata=none`.

## Limits

- Cloudflare Images takes JPEG, PNG, GIF and WebP up to 10 MB. Anything else
  stays in Kiln's storage.
- Images uploaded with a custom ID can't require signed URLs. Kiln never gates
  images, so this doesn't come up.
- Cloudflare bills per stored image and per delivery. With flexible variants
  on, each upload is one stored image however many sizes are served.

## Development

The unit tests in `test/` need only this project:

```bash
mix deps.get
mix test
```

The tests that need Kiln itself are in `test_kiln/`, which says how to run
them from a kiln_cms checkout. CI runs both, the second against the kiln_cms
ref named at the top of `.github/workflows/ci.yml`.

## License

MIT
