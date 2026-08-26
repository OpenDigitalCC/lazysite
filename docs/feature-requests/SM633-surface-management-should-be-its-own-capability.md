---
title: "SM633: a capability titled 'Read and set SAFE site configuration' decides whether anyone can reach the instance at all"
subtitle: "The operator's proposal, made while assessing SM612 and recorded there without a reference of its own"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-26 to give the operator's proposal a quotable reference. It had been recorded inside SM612's status-note, which is SHIPPED - so the open question was buried in a closed filing and could not be cited, scheduled or argued with. THE PROPOSAL: `manage_config` currently governs both ordinary site settings (title, cache lifetime, search defaults) and the SERVICE KILLSWITCHES - webdav_enabled, mcp_enabled, oauth_enabled, control_api_enabled, token_exchange_enabled - which decide whether any remote caller can reach the instance at all. Those are different sizes of decision under one name, and the capability's own title says 'SAFE site configuration'. SM612 closed the sharpest edge - a token can no longer switch off the manager surface that would revoke it - by restricting `manager` and `manager_path` to the cookie channel. That is a fix at the key level; this is the question of whether the LOCK is the right shape. WHAT A SPLIT WOULD LOOK LIKE: `manage_config` keeps the ordinary settings; a new capability - `manage_services`, say - carries the five killswitches, and nothing else. An operator could then hand a partner the ability to tune caching without handing it the ability to turn off WebDAV for everyone. NOT DECIDED, and there is a real argument the other way: another capability is another thing to understand, and the SM623 service grouping already makes the killswitches visibly a group of their own in the UI, which may be enough. WORTH DOING WITH SM427 (a permission should say what it grants, in full), because both are about a capability's title being smaller than its reach."
---

# The two sizes of decision under one name

| `manage_config` governs | Consequence of a mistake |
|---|---|
| site title, cache lifetime, search defaults | a page looks wrong |
| `webdav_enabled`, `mcp_enabled`, `oauth_enabled`, `control_api_enabled`, `token_exchange_enabled` | **nobody can reach the instance** |

# What SM612 settled, and what it did not

SM612 stopped a token switching off the manager that would revoke it. That
closed the self-protecting case. It did not answer whether one capability
should carry both rows of the table above.
