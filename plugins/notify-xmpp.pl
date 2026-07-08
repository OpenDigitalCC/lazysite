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
            description => 'Deliver operator notifications (new form submissions, '
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
                    note  => 'Stored in the operator-only notify-xmpp.conf; never '
                        . 'shown again. Leave blank to keep the current one.',
                },
                {
                    key   => 'to',
                    label => 'Send notifications to',
                    type  => 'text',
                    note  => 'The recipient: a person\'s JID (user@domain), or a '
                        . 'group chat room\'s full JID (room@conference.domain).',
                },
                {
                    key     => 'muc',
                    label   => 'Recipient is a group chat (MUC) room',
                    type    => 'boolean',
                    default => 'false',
                },
                {
                    key   => 'host',
                    label => 'Server host (optional)',
                    type  => 'text',
                    note  => 'Defaults to the JID\'s domain.',
                },
                {
                    key     => 'port',
                    label   => 'Server port',
                    type    => 'number',
                    default => '5222',
                },
                {
                    key     => 'tls',
                    label   => 'TLS',
                    type    => 'boolean',
                    default => 'true',
                },
                {
                    key     => 'nick',
                    label   => 'Sender nickname / resource',
                    type    => 'text',
                    default => 'lazysite',
                },
            ],
        }
    );
    exit 0;
}

print "usage: notify-xmpp.pl --describe\n";
exit 0;
