---
title: Remote content
subtitle: Using JSON indexes and .url files for remote-sourced pages.
register:
  - sitemap.xml
---

## The pattern

lazysite can source page content from remote URLs using `.url` files. A
`.url` file contains a single URL - the processor fetches the Markdown
from that URL, processes it through the full pipeline, and caches the
result.

This makes it possible to maintain content in a git repository and serve
it through a lazysite site without duplicating files. The lazysite.io
documentation works exactly this way - each page is a `.url` file pointing
to the raw Markdown in the GitHub repository.

## Remote blog from a git repository

The challenge with a remote blog is discovery - how does the site know
which posts exist? Direct directory scanning of a remote repository
requires API calls with rate limits and authentication complexity.

The recommended approach is a JSON index file committed to the content
repository alongside the posts.

### 1. Content repository structure

```
my-blog/
  posts/
    2026-03-01-first-post.md
    2026-03-20-second-post.md
  index.json
```

### 2. JSON index format

`index.json` lists all posts with their metadata:

```json
[
  {
    "url": "https://raw.githubusercontent.com/owner/my-blog/main/posts/2026-03-20-second-post.md",
    "title": "Second Post",
    "subtitle": "A follow-up",
    "date": "2026-03-20",
    "tags": ["news"]
  },
  {
    "url": "https://raw.githubusercontent.com/owner/my-blog/main/posts/2026-03-01-first-post.md",
    "title": "First Post",
    "subtitle": "An introduction",
    "date": "2026-03-01",
    "tags": ["intro"]
  }
]
```

Keep posts in reverse chronological order (newest first) - the array
order is the display order.

### 3. Generating the index

A simple script in the content repository generates `index.json` from
the front matter of each post. Run it manually or via a GitHub Action
on push.

Example script (`generate-index.sh`):

```bash
#!/bin/bash
# Run from repository root
REPO="https://raw.githubusercontent.com/owner/my-blog/main"
echo "[" > index.json
first=true
for f in $(ls -r posts/*.md); do
    title=$(grep "^title:" "$f" | head -1 | sed 's/title: //')
    subtitle=$(grep "^subtitle:" "$f" | head -1 | sed 's/subtitle: //')
    date=$(grep "^date:" "$f" | head -1 | sed 's/date: //')
    filename=$(basename "$f")
    [ "$first" = true ] && first=false || echo "," >> index.json
    cat >> index.json << EOF
  {
    "url": "$REPO/posts/$filename",
    "title": "$title",
    "subtitle": "$subtitle",
    "date": "$date"
  }
EOF
done
echo "]" >> index.json
```

### 4. lazysite site setup

In `lazysite/lazysite.conf`, fetch the index as a site variable:

```yaml
blog_posts: url:https://raw.githubusercontent.com/owner/my-blog/main/index.json
```

This fetches and caches the JSON index with the page TTL.

Create a blog listing page (`public_html/blog/index.md`):

```markdown
---
title: Blog
ttl: 3600
---

[% USE JSON(pretty=>0) %]
[% posts = JSON.deserialize(blog_posts) %]
[% FOREACH post IN posts %]
## [% post.title %]

[% IF post.subtitle %][% post.subtitle %][% END %]

[% post.date %] - [Read more](/blog/[% post.date %]-[% post.title | lower | replace(' ', '-') %])

[% END %]
```

For each post, create a `.url` file:

```
public_html/blog/2026-03-20-second-post.url
```

Containing:

```
https://raw.githubusercontent.com/owner/my-blog/main/posts/2026-03-20-second-post.md
```

### 5. Keeping in sync

When a new post is added to the content repository:

1. Add the post `.md` file
2. Run the index generator to update `index.json`
3. Commit and push both files
4. On the lazysite server, create a `.url` file for the new post
5. Delete `blog/index.html` to force the listing to refresh

A GitHub Action can automate steps 1-3 on every push. Step 4-5 can be
automated via an SSH deploy hook or webhook.

The TTL on the listing page (`ttl: 3600`) means the listing refreshes
automatically every hour without manual cache deletion.

## Using with :::include

Instead of individual `.url` files, posts can be included directly into
a single page using `:::include`:

```markdown
---
title: Recent Posts
ttl: 3600
---

[% USE JSON(pretty=>0) %]
[% posts = JSON.deserialize(blog_posts) %]
[% FOREACH post IN posts.slice(0,4) %]

---

::: include
[% post.url %]
:::

[% END %]
```

This fetches and renders the most recent 4 posts inline. Suitable for a
home page "latest posts" section. The full post content is rendered
rather than just a listing.

Note that `:::include` blocks containing TT variables are not yet
resolved before inclusion - use `.url` files for per-post pages and
`:::include` for inline rendering of specific known posts.

## Caching behaviour

The JSON index is cached with the page TTL. Individual `.url` files
cache their content for `$REMOTE_TTL` (default 1 hour). Delete a
`.html` file to force immediate refresh of that page.

To refresh the listing after adding posts:

```bash
rm public_html/blog/index.html
```

To refresh a specific post:

```bash
rm public_html/blog/2026-03-20-second-post.html
```
