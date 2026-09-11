---
title: "SM838: a line break in an extension setting added lines to lazysite.conf"
subtitle: "Found while building SM802, reproduced before it was fixed: one plugin-save wrote a domain's allowed_groups into lazysite.conf through the Logging extension's log_level - crossing the SM647 boundary from manage_config to manage_domains AND manage_users"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11: plugin-save refuses any value containing a carriage return or a newline, naming the setting, before anything is written - refused rather than stripped, because a value that cannot be stored as sent is an error the caller has to see. t/unit/manager/174 drives a real shipped extension in an isolated tree and fails six ways with the guard removed."
---

# What happened

`action_plugin_save` checked each submitted **key** against the extension's
schema, and never the **value**. Every value is then written as `key: value` on
a line of its own - into the extension's own config file, or, for an extension
that declares `config_keys`, into **`lazysite.conf`**. A line break in a value
became a line of its own in the file, and that line had not been through the
key allowlist at all.

Reproduced on an isolated tree with the shipped Logging extension:

    log_level => "INFO\nalias.victim.example.allowed_groups: attackers"

`lazysite.conf` afterwards:

    site_name: T
    log_level: INFO
    alias.victim.example.allowed_groups: attackers

# Why it matters

`plugin-save` needs **manage_config**. `allowed_groups` decides who may reach a
domain's content, and the SM647 ruling put writing it behind **manage_domains
and manage_users**. This crossed that boundary - and the same line break injects
any key at all: a service switch, the `extensions:` list, a content root.

The manager's form never sends a line break. The API accepts any string, which
is where this would be used. Four shipped extensions write `lazysite.conf` this
way: bad-url-blocker, git-sync, log and notify-xmpp.

# The fix

Refused, not stripped: stripping stores something other than what was sent and
reports success. The refusal names the setting and happens before either write
branch, so a save with one bad value writes nothing at all.

# How it was found

Building SM802, rules were considered for a `textarea` config field, which the
Extension Config page can render. Reading how a saved value is written - to
decide whether a multi-line value could be stored - showed it could not be
stored correctly, and could not be refused either.

# Related

[[SM647]] (the boundary this crossed), [[SM802]] (where it was found).
