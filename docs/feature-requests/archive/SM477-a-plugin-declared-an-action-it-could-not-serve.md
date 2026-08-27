---
title: "SM477: the Status button showed an operator a usage string"
subtitle: "A plugin's descriptor and its own argument parser disagreed about how the manager would invoke it, and nothing in the contract checked that they agreed"
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED FROM THE MANAGER UI 2026-08-22: clicking the data plugin's Status button returned `usage: --describe | --action status --docroot DIR`. FIXED, and the class fixed with it. THE MECHANISM: Lazysite::Manager::Plugins::action_plugin_action invokes a declared action as `--scan` UNLESS the action declares `run => 'action'`, in which case it sends `--action <id>`. plugins/data.pl declared `{ id => 'status', label => 'Status' }` with no `run`, and implemented only `--action status` - so the button ran the fall-through branch of the plugin's own argument parser and printed its usage line into the UI. Every other plugin in the tree serves `--scan`, which is why this had never happened before: data.pl is the first to implement the newer convention without declaring it. TWO FIXES, and the second is the one that matters: the declaration is corrected, AND run() now serves `--scan` as well, so a future action that forgets the declaration degrades to the status report rather than to a usage string - status being the surface an operator reaches for when something is already wrong. t/integration/61 invokes EVERY plugin the way the manager would, for every action it declares, against an empty docroot, and asserts the invocation was RECOGNISED - not that it succeeded, because most correctly refuse without configuration, and the empty docroot is what makes it safe to run git-sync's push among them. 28 assertions across the plugin set. SABOTAGE, and it reports something worth keeping: removing the declaration ALONE still passes, because the --scan fallback catches it - the test measures whether the plugin can serve what the manager sends, which is the real contract, rather than whether a particular key is present. Removing both reproduces the reported fault and the test fails."
---

# What an operator saw

A button in the Plugin Manager, and a usage string in reply. Nothing about that
message tells an operator what to do: it is addressed to whoever is typing the
command, and nobody typed one.

# Why nothing caught it

ADR 0009 defines what a plugin DECLARES. Nothing checked that the plugin could
serve what it declared, and the two halves live far apart -- the descriptor at
the top of the file, the argument parser at the bottom. Both were internally
consistent; they simply described different plugins.

The gate could not see it because every existing test either called
`--describe` (which is correct) or called the plugin's own entry point directly
with arguments the test chose. **No test had ever invoked a plugin the way the
manager invokes it**, so the one path an operator actually uses was the one
path never exercised.

# The general fix

`t/integration/61` reconstructs the manager's argv rule and applies it to every
declared action of every plugin. It asserts only that the plugin understood --
a refusal is a pass, because a plugin answering "no SMTP configured" has
understood the question and one answering "usage:" has not.

The manager's rule is **restated** in the test rather than imported from
`Lazysite::Manager::Plugins`. A test that shares the code under test cannot
disagree with it, and disagreement is the entire fault being checked for.
