#!/usr/bin/perl

# SM1396 (ruling 53, X8 of SM1369): THE OFFLINE KIT IS AN ENGINE EXTENSION.
#
# A site installed as an app (SM1155, SM1197) opens its kept pages with no
# signal; this gives such a page what it needs to WORK with none: a connection
# banner, the last good answer for a read, a guard that sends a queued change
# once, the queue itself, the install and update status, and a sign-out. All of
# it is one script in this extension's payload (assets/kit.js), served by the
# engine as an asset the extension declares (SM1369 X5, owns.hooks.assets), and
# one layout variable, [% app_offline_kit %], that renders the script tag while
# the extension is on and nothing otherwise. No layout ships a script.
#
# BUILT ON ODOO'S HELPER (requires: odoo). The kit wraps /assets/lazysite-odoo.js:
# a read goes through it and its answer is kept; a queued write goes through it
# with the Idempotency-Key that makes a resend safe (SM1223). Nothing Odoo-specific
# is in core: what the kit needs of the engine is the hooks any extension may
# declare.
#
# WHAT IS KEPT IS OWNED BY LOGIN (ruling 53): the endpoint's ?csrf=1 names the
# signed-in person by `owner`, a label of the login (never the login), and a kept
# read or a queued write belongs to that owner, is shown to and sent for no
# other login on the same browser, and one made with no owner is dropped.
#
# The slot contract a layout may carry (the layouts briefing names it):
#   data-ls-app-banner     shown while the browser is offline
#   data-ls-app-show-out   shown while nobody is signed in
#   data-ls-app-show-in    shown while somebody is
#   data-ls-app-status     the install state, and a waiting update to apply

use strict;
use warnings;

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json(
        {
            id          => 'app-offline',
            name        => 'Offline kit for an installed app',
            description => 'For a site installed as an app: a page kept for offline gets a '
                . 'connection banner, the last good answer for each read, a queue that sends a '
                . 'change made offline once the signal is back (once, never twice), the install '
                . 'and update status, and a sign-out. One script, served by the engine; a layout '
                . 'renders [% app_offline_kit %] and carries the data-ls-app-* slots. What the '
                . 'browser keeps belongs to the signed-in login and is shown to no other. Needs '
                . 'the Odoo extension.',
            version  => '0.1',
            contract => 1,

            owns => {
                requires => ['odoo'],
                hooks    => {
                    assets => [ { file => 'kit.js' } ],
                    template_vars => [ { name => 'app_offline_kit', render => 'Lazysite::Ext::AppOffline::kit_tag' } ],
                },
            },
        }
    );
    exit 0;
}

print "usage: app-offline.pl --describe\n";
exit 1;
