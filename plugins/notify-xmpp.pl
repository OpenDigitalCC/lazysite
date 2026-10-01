#!/usr/bin/perl
# notify-xmpp.pl - XMPP notification delivery (SM136) - the descriptor.
#
# When enabled (Plugin Manager) and configured, operator notifications (the
# manager bell: new form submissions, requests awaiting a response) are also
# delivered over XMPP - one client config per site, like SMTP delivery, sending
# to a single recipient: an individual JID or a group chat (MUC) room. Delivery
# itself lives in Lazysite::Notify (based on the xmpp-lite connector,
# Net::XMPP / Debian libnet-xmpp-perl) and is strictly best-effort; the bell
# store remains the record. Per-user recipient addressing is a future feature.

use strict;
use warnings;

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json(
        {
            id          => 'notify-xmpp',
            name        => 'XMPP notifications',
            description => 'Deliver sysop notifications (new form submissions, '
                . 'requests awaiting a response) to an XMPP address or group chat. '
                . 'One client account per site, like SMTP delivery.',
            version       => '1.0',
            config_file   => 'lazysite/notify-xmpp.conf',
            config_keys   => [qw(jid password to muc host port tls nick)],
            config_schema => [
                {
                    key   => 'jid',
                    label => 'Client JID',
                    type  => 'text',
                    note  => 'The account lazysite sends FROM, as user@domain '
                        . '(create a dedicated account for the site).',
                },
                {
                    key   => 'password',
                    label => 'Client password',
                    type  => 'password',
                    note  => 'Stored in the sysop-only notify-xmpp.conf; never '
                        . 'shown again. Leave blank to keep the current one.',
                },
                {
                    key   => 'to',
                    label => 'Recipient JID',
                    type  => 'text',
                    note  => 'Where notifications go: a person\'s JID (user@domain), '
                        . 'or a group chat room\'s full JID (room@conference.domain).',
                },
                {
                    key     => 'muc',
                    label   => 'Recipient is a group chat (MUC) room',
                    type    => 'boolean',
                    default => 'false',
                },
                {
                    # SM925 X2: the note used to say "Defaults to the JID's
                    # domain", which is the precise assumption SRV exists to
                    # correct. Leave BOTH this and the port blank and the engine
                    # asks the domain where its client endpoint is.
                    key   => 'host',
                    label => 'Server host (optional)',
                    type  => 'text',
                    note  => 'Leave BLANK, with the port blank too, to use the '
                        . 'domain\'s SRV record - which is how most servers '
                        . 'publish a client endpoint that is not the JID\'s own '
                        . 'domain. Set it only to override that.',
                },
                {
                    # SM925 X2: NO `default`. The form pre-filled 5222, so an
                    # operator who never touched the field had silently asserted
                    # a port - and asserted it wrongly for every server that
                    # publishes something else. A live account's own domain
                    # answered `10 0 47594 xmpp.project.im.` and the pre-filled
                    # 5222 overruled it. A defaulted value that contradicts a
                    # discoverable fact is worse than no value: it looks like a
                    # decision somebody made, so nobody questions it.
                    key   => 'port',
                    label => 'Server port',
                    type  => 'number',
                    note  => 'Leave BLANK to use the SRV record (with the host '
                        . 'blank too). Setting it means exactly this port, and '
                        . 'nothing is looked up.',
                },
                {
                    key     => 'tls',
                    label   => 'TLS',
                    type    => 'boolean',
                    default => 'true',
                },
                {
                    key   => 'nick',
                    label => 'Sender nickname / resource',
                    type  => 'text',
                    note  => 'Defaults to the site name (sanitised).',
                },
            ],

            # SM925 X1: DECLARE THE MODULE, so the enable path refuses instead of
            # accepting eight fields including a password and then delivering
            # nothing. An operator enabled this on a live site, configured it, and
            # spent an afternoon over four submissions before the cause turned out
            # to be that Net::XMPP was never installed. `_missing_deps` has read
            # this field since ADR 0009 and two sibling plugins use it; the fact
            # was written down nine lines above, in prose, where the machinery
            # could not see it.
            #
            # WHY NO LINT COULD HAVE FOUND THIS. The `require Net::XMPP` is not in
            # this file - delivery lives in Lazysite::Notify (:585) and this plugin
            # is a descriptor. So scanning plugin sources for an undeclared module
            # finds nothing here, which is exactly what tmp/sm925-dep-audit.pl did
            # on its first run. t/lint/201 gates the derivable half instead: a
            # plugin whose own text names a module must declare it.
            owns => {
                # SM925 X2 adds Net::DNS: the SRV lookup that finds a domain's
                # client endpoint needs it, and it is not core. Declared HERE and
                # not after the fact, because X2's own repair landing without its
                # dependency declared would be X1 happening a second time in the
                # same filing.
                deps         => [ 'Net::XMPP', 'Net::DNS' ],
                capabilities => [],
            },
        }
    );
    exit 0;
}

print "usage: notify-xmpp.pl --describe\n";
exit 0;
