---
title: "SM633: a capability titled 'Read and set SAFE site configuration' decides whether anyone can reach the instance at all"
subtitle: "The operator's proposal, made while assessing SM612 and recorded there without a reference of its own"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.3 (2026-08-27) on the operator's ruling. `manage_services` carries the five switches - webdav, mcp, oauth, control_api, token_exchange - and `manage_config` keeps the ordinary settings and says so in its own sentence, pointing at the capability that holds the rest. THE CHECK IS AT THE KEY, not in the %need table, because %need gates the ACTION and this is a rule about one of its keys: config-set is one door onto settings that are not all alike, which is the same shape as SM612's channel check sitting immediately above it. THE TWO LISTS CANNOT DRIFT: the service keys are named once and the gate reads that list, and the test asserts every one of them is also settable at all - a service key absent from the allowlist would make the capability gate unreachable while looking like a working rule. THE MIGRATION IS THE DECISION, and it is the operator's: a FRESH site gives the admin group the capability, because it holds everything else and withholding it would break a working site on nothing but a version change; an EXISTING site OFFERS it through SM496's pending banner. Granting silently would widen a live grant and removing silently would narrow one, and neither is a decision this change is entitled to make. Verified on a simulated upgraded site: manage_services appears in `pending` and the group does not hold it until answered. WHAT THE SENTENCE HAD TO SAY, per SM427: switching a surface off does not narrow a grant - it stops that surface answering for EVERYONE, including partners already connected - and the manager UI is not among them, so the recovery surface stays. Five sabotages, all fail. ORIGINAL PROPOSAL BELOW. FILED 2026-08-26 to give the operator's proposal a quotable reference. It had been recorded inside SM612's status-note, which is SHIPPED - so the open question was buried in a closed filing and could not be cited, scheduled or argued with. THE PROPOSAL: `manage_config` currently governs both ordinary site settings (title, cache lifetime, search defaults) and the SERVICE KILLSWITCHES - webdav_enabled, mcp_enabled, oauth_enabled, control_api_enabled, token_exchange_enabled - which decide whether any remote caller can reach the instance at all. Those are different sizes of decision under one name, and the capability's own title says 'SAFE site configuration'. SM612 closed the sharpest edge - a token can no longer switch off the manager surface that would revoke it - by restricting `manager` and `manager_path` to the cookie channel. That is a fix at the key level; this is the question of whether the LOCK is the right shape. WHAT A SPLIT WOULD LOOK LIKE: `manage_config` keeps the ordinary settings; a new capability - `manage_services`, say - carries the five killswitches, and nothing else. An operator could then hand a partner the ability to tune caching without handing it the ability to turn off WebDAV for everyone. NOT DECIDED, and there is a real argument the other way: another capability is another thing to understand, and the SM623 service grouping already makes the killswitches visibly a group of their own in the UI, which may be enough. WORTH DOING WITH SM427 (a permission should say what it grants, in full), because both are about a capability's title being smaller than its reach."
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
