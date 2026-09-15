# The lazysite skill for claude.ai

Gives Claude a working lazysite in the conversation, so it can check a page by
running it instead of reasoning about it.

It is **additional to your MCP connector and independent of it**. MCP writes to
your site; this decides whether what is about to be written will work. Either
works without the other.

## Install it

1. Download `lazysite-skill-<version>.zip` from the release.
2. Upload it as a skill in your claude.ai settings.

That is all. The engine is inside the zip, so nothing is downloaded from
anywhere when it runs, and the version Claude tests against is the version the
zip carries.

## Update it

Download the zip from the new release and upload it again. Claude prints the
engine version on every run, so you can see when it is behind:

```
lazysite: engine 0.14.3-1
```

There is no self-update. A skill that rewrote itself from the network would
need to reach a host your container may not allow, and would fail for you in a
way that looked like a bug in your page.

## What it does when Claude uses it

1. Installs the bundled engine (about 2 MB, plus two Perl packages from the
   Ubuntu archive your container already uses).
2. Makes a local copy of a starter site.
3. Validates the page source, and renders the page through a local dev server.
4. Pulls your site's own layout and theme through your connector first, when
   one is attached, so what it renders is what you will get.
5. Ends the answer with a line saying what was and was not checked.

## What it cannot do

- **Show you the page.** There is no browser and no screenshots in that
  container, and no inbound network. Everything is text.
- **See your live site.** That is what the MCP connector is for. If no
  connector is attached, Claude renders against the starter theme and says so.
- **Read your site's `lazysite.conf`.** It is not something a partner
  credential may read, so anything that depends on a setting in it is reported
  as unverified rather than guessed at.

## Something went wrong

Ask Claude to show you `/root/lazysite-local/server.log` - the engine logs the
things that show up on a page as something subtler than an error.
