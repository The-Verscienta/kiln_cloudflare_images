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

- KilnCMS with `Kiln.ImageBackend`, which arrives in
  [kiln_cms#1958](https://github.com/The-Verscienta/kiln_cms/pull/1958) (the
  release after 1.3.0).
- A Cloudflare account with Images, and an API token with **Cloudflare Images:
  Edit**.
- **Flexible variants** switched on: Cloudflare dashboard → Images → Delivery.
  Without them, set `CLOUDFLARE_IMAGES_FLEXIBLE_VARIANTS=false` and Kiln
  encodes each variant itself and uploads it as a separate image (more
  storage, still correct).

## Install

A Kiln plugin is compiled with Kiln, not added as a Mix dependency
([kiln_cms#1909](https://github.com/The-Verscienta/kiln_cms/issues/1909)).
Vendor this repository into your Kiln checkout's `projects/` directory, the
same way an overlay is:

```bash
git submodule add https://github.com/The-Verscienta/kiln_cloudflare_images projects/cloudflare_images
```

or copy it in your image build:

```dockerfile
COPY cloudflare_images projects/cloudflare_images
```

Then register the plugin and select its backend in `config/project.exs`:

```elixir
config :kiln_cms, :plugins, [KilnCloudflareImages.Plugin]
config :kiln_cms, :image_backend, KilnCloudflareImages.Backend
```

`mix kiln.plugins.doctor` checks both lines.

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
unconfigured and Kiln keeps storing images locally. **System → Plugins** says
which state it's in.

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
importers stored. It records the image's ID on the row and enqueues its
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

The tests run inside a Kiln checkout:

```bash
cd path/to/kiln_cms
ln -s path/to/kiln_cloudflare_images projects/cloudflare_images
mix test projects/cloudflare_images/test
```

CI does the same against the kiln_cms ref named at the top of `.github/workflows/ci.yml`.

## License

MIT
