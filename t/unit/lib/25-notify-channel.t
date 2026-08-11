#!/usr/bin/perl
# SM231: notify() as a CHANNEL - types, templates, routing and emission control.
#
# t/unit/lib/14-notify.t covers the pre-SM231 behaviour (the bell write, the
# XMPP config gate, the MUC/chat branches) and still passes unchanged, which is
# the compatibility statement: a site that writes no notify.conf and no template
# behaves exactly as it did.
#
# This covers what SM231 added, and it is also the answer to Notify.pm being the
# least-verified module in the tree at 56.7%. The headline is `url`: two of the
# three live callers already passed one and it was stored and dropped, so an
# operator was told that something happened and never where to go.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Notify qw(notify notify_types);

my @SENT;
{
    no warnings 'once';
    $Lazysite::Notify::XMPP_SENDER = sub { push @SENT, $_[1]; 1 };
}

# A docroot with XMPP enabled and configured, so the delivery path is live.
sub fixture {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: My Site\nsite_url: https://example.test/\n"
        . "plugins:\n  - notify-xmpp.pl\n";
    close $cf;
    open my $xf, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
    print {$xf} "jid: bot\@example.test\npassword: pw\nto: ops\@example.test\n";
    close $xf;
    if ( defined $o{notify_conf} ) {
        open my $nf, '>', "$d/lazysite/notify.conf" or die $!;
        print {$nf} $o{notify_conf};
        close $nf;
    }
    if ( $o{template} ) {
        make_path("$d/lazysite/notify-templates");
        open my $tf, '>', "$d/lazysite/notify-templates/$o{template}{name}" or die $!;
        print {$tf} $o{template}{body};
        close $tf;
    }
    @SENT = ();
    return $d;
}

# Returns the parsed notices. Always returns an ARRAY, never a bare (), so
# `scalar notices($d)` is a reliable count - an early `return ()` yields undef in
# scalar context and the zero case would silently read as "not run".
sub notices {
    my ($d) = @_;
    my @n;
    if ( open my $fh, '<', "$d/lazysite/logs/notices.jsonl" ) {
        @n = map { decode_json($_) } grep {/\S/} <$fh>;
        close $fh;
    }
    return @n;
}

# --- the headline: url is DELIVERED, not just recorded ----------------------
{
    my $d = fixture();
    ok( notify( $d, { type => 'reset-request', message => 'Reset for alice',
            target => 'alice', url => '/manager/users?user=alice' } ),
        'a notice with a url is accepted' );

    is( scalar @SENT, 1, 'one delivery' );
    like( $SENT[0], qr{/manager/users\?user=alice},
        'the URL REACHES the operator - the SM231 headline' )
        or diag $SENT[0];
    like( $SENT[0], qr{https://example\.test/manager/users},
        'and is absolute, so it is clickable from a chat client' );
    like( $SENT[0], qr/^My Site: /, 'the site name identifies which site spoke' );

    my ($rec) = notices($d);
    is( $rec->{url}, '/manager/users?user=alice',
        'the record still stores the raw url for the manager bell' );
}

# --- a notice with no url must not render a dangling arrow ------------------
{
    my $d = fixture();
    notify( $d, { type => 'feedback', message => 'Agent feedback' } );
    like( $SENT[0], qr/^My Site: Agent feedback$/,
        'no url means no trailing separator - the IF branch is real' )
        or diag $SENT[0];
}

# --- emission control: 690 events where five were wanted --------------------
{
    my $d = fixture( notify_conf => "emit.submission: off\n" );
    ok( notify( $d, { type => 'submission', message => 'New form submission: a' } ),
        'a silenced type still reports success to its caller' );
    is( scalar @SENT, 0, 'and is not delivered' );
    is( scalar notices($d), 0,
        'nor written to the bell - silenced is silent, not quietly accumulating '
            . 'in a store nobody reads' );

    # Silencing one type must not silence the rest.
    notify( $d, { type => 'feedback', message => 'still speaking' } );
    is( scalar @SENT, 1, 'another type is unaffected' );
}

# --- routing: a type can reach the bell without reaching chat ---------------
{
    my $d = fixture( notify_conf => "route.audit-finding: bell\n" );
    notify( $d, { type => 'audit-finding', message => 'finding' } );
    is( scalar @SENT,     0, 'a bell-only type is not delivered over xmpp' );
    is( scalar notices($d), 1, 'but is recorded' );

    # And the reverse: a type routed to xmpp is BOTH, never xmpp instead of the
    # record. A notice nothing wrote down is not a notice.
    notify( $d, { type => 'submission', message => 'sub' } );
    is( scalar @SENT, 1, 'a routed type is delivered' );
    is( scalar notices($d), 2, 'and the bell keeps the record regardless' );
}

{
    # Even an explicit route that omits the bell keeps it - the bell is the
    # record, not an endpoint an operator can route away by accident.
    my $d = fixture( notify_conf => "route.submission: xmpp\n" );
    notify( $d, { type => 'submission', message => 'sub' } );
    is( scalar notices($d), 1, 'the bell cannot be routed away' );
    is( scalar @SENT,       1, 'and the named endpoint still fires' );
}

# --- default route: a type nobody configured behaves as before --------------
{
    my $d = fixture();    # no notify.conf at all
    notify( $d, { type => 'submission', message => 'sub' } );
    is( scalar @SENT,       1, 'with no config, a type follows its default route' );
    is( scalar notices($d), 1, 'and is recorded' );

    # backup-outcome defaults to bell only - a completed backup should not ping
    # a chat room on every run.
    notify( $d, { type => 'backup-outcome', message => 'backup ok' } );
    is( scalar @SENT, 1, 'a bell-default type does not add a delivery' );
}

# --- an unregistered type is delivered, not lost ----------------------------
{
    my $d = fixture();
    ok( notify( $d, { type => 'something-new', message => 'novel' } ),
        'an unregistered type is accepted' );
    is( scalar notices($d), 1,
        'and recorded - refusing it would lose an event because a caller landed '
            . 'before a registry entry' );
    is( scalar @SENT, 1, 'and delivered on the generic route' );
}

# --- a site template overrides the built-in ---------------------------------
{
    my $d = fixture(
        template => { name => 'submission.xmpp.tt',
            body => '[% type %] on [% site %]: [% target %]' } );
    notify( $d, { type => 'submission', message => 'ignored', target => 'contact' } );
    is( $SENT[0], 'submission on My Site: contact',
        'a per-site template replaces the built-in body' )
        or diag $SENT[0];

    # A template for ANOTHER type must not capture this one.
    @SENT = ();
    notify( $d, { type => 'feedback', message => 'fb' } );
    like( $SENT[0], qr/^My Site: fb$/,
        'and applies only to its own type' )
        or diag $SENT[0];
}

# --- a broken template loses the rendering, never the notice ----------------
{
    my $d = fixture(
        template => { name => 'default.xmpp.tt', body => '[% IF %]' } );
    ok( notify( $d, { type => 'feedback', message => 'survives' } ),
        'a broken template does not fail the call' );
    is( scalar notices($d), 1, 'the notice is still recorded' );
    is( scalar @SENT, 1, 'and still delivered' );
    like( $SENT[0], qr/survives/,
        'falling back to the message - a bad template must not silence an alert' )
        or diag $SENT[0];
}

# --- base_url overrides the site_url for link building ----------------------
{
    my $d = fixture( notify_conf => "base_url: https://admin.example.test\n" );
    notify( $d, { type => 'feedback', message => 'm', url => '/x' } );
    like( $SENT[0], qr{https://admin\.example\.test/x},
        'base_url wins over site_url, for a site whose manager is elsewhere' );
}

# --- the registry is introspectable -----------------------------------------
{
    my $t = notify_types();
    ok( $t->{submission} && $t->{submission}{title},
        'notify_types exposes the registry with titles' );
    ok( $t->{'credential-expiring'},
        'and the seeded types SM231 named, so the vocabulary is declared even '
            . 'where no caller emits one yet' );

    # It must be a copy: a caller poking the returned hash must not reconfigure
    # every later notification in the same process.
    $t->{submission}{default_route} = 'nowhere';
    is( notify_types()->{submission}{default_route}, 'bell,xmpp',
        'and hands out a copy, not the live registry' );
}

# --- the pre-existing guards still hold -------------------------------------
{
    my $d = fixture();
    ok( !notify( $d, { message => '' } ),   'an empty message is refused' );
    ok( !notify( $d, 'not a hashref' ),     'a non-hashref payload is refused' );
    ok( !notify( undef, { message => 'x' } ), 'a missing docroot is refused' );

    notify( $d, { type => 'feedback', message => "two\nlines\r\nhere" } );
    my ($rec) = notices($d);
    unlike( $rec->{message}, qr/[\r\n]/,
        'newlines are flattened so one notice stays one JSONL line' );
}

done_testing();
