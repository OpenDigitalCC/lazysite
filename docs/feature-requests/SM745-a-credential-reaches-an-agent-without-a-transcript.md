---
id: SM745
title: "SM745: a credential reaches an agent without passing through a transcript"
subtitle: "The brief says a key that appears in any transcript is spent. The only easy way to give one to an agent is to paste it into the conversation. So the rule is broken every time it is followed, and the fix is to make the secure path the easy one."
brand: plain
standard-margins: true
status: open
---

# The moment this fills

Getting a single-use pairing key from a sysop to an implementation agent is
fiddly over files, so in practice it is pasted into the chat. The brief's own
rule then applies:

> A key that has appeared in any transcript should be treated as spent -
> regenerate it.

So every delivery costs a regeneration, and the secret sits in a transcript in
between. This is not hypothetical drift: the `cc2` and `cc3` pairing keys and
the `ai-ui-tester` password have gone through chat repeatedly, and each time the
correct response has been to rotate them.

**A rule that is broken by the only convenient path is not a rule, it is a
tax.** The field agent filed three ways out, cheapest first.

# What needs no engine change

Two of the three are available today and want nothing from us.

**A no-echo drop.** The operator runs a small local helper that reads the key
with `read -rsp` - which does not echo - and writes the exchange-config file the
agent already consumes. The key never becomes a chat message. Simpler still: the
operator performs the exchange themselves and drops only the resulting
short-lived `lzs_` token, so the pairing key never leaves their machine.

This belongs in `lazysite-sites/bin/` as a local wrapper, not here, and the
field agent can add it. **Recording it because it is the answer for now**, and
anything built under this task should be measured against "is it actually better
than the helper".

**The connector token in settings.** For an assistant that publishes through an
MCP connector, the brief already prescribes pasting a generated token into the
connector's settings, out of band. Nothing travels through the conversation.
This is the cleanest channel that exists - and it is undermined by the connector
dropping mid-session, which is **SM746** and is the more urgent of the two.

# The feature, if it recurs across partners

A sysop UI action - "issue a token to a waiting agent" - that writes the token
to a per-agent, agent-readable, one-time location, or hands back a claim code
the agent redeems once.

The properties that would make it worth building over the helper script:

- **One-time.** Reading it consumes it, so a leaked path is not a leaked
  credential.
- **Addressed.** Issued to a named grant, so it is auditable as an issuance
  rather than appearing as an unexplained token.
- **Short-lived by construction**, so an unclaimed drop expires rather than
  waiting.

# Priority, stated plainly

**Lower than SM746.** A connector that stays mounted removes most of the demand
for this; a credential-drop affordance built while the connector still drops
would be solving the second problem first.

# Provenance

Filed by the edge testing agent at the operator's request, 2026-09-02. The
operator action it names - regenerate `cc2`/`cc3`, rotate `ai-ui-tester` -
stands regardless of whether this is ever built.
