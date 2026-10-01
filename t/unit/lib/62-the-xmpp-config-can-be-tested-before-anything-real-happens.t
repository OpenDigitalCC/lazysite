#!/usr/bin/perl
# SM927: form-smtp declares a `validate` action and the config page shows a
# "Validate SMTP connection" button. notify-xmpp declared no actions at all, so an
# operator who had just typed eight fields including a password had no way to learn
# whether any of it worked until a real event fired - and this plugin's whole failure
# mode is that when one does fire, nothing tells them: an XMPP notice that never
# arrives looks exactly like a site where nothing has happened.
#
# WHAT THIS ASSERTS IS THE STAGING, because the step-by-step is the point. A bare
# failure sends an operator back through all eight fields; a named stage sends them
# to one of them. Three defects filed on 2026-09-30 are each a stage here: X1 as
# `library`, X2 as `endpoint` (which says WHERE the endpoint came from), and SM926
# because the rendered body is shown rather than summarised.
#
# NO NETWORK AND NO DNS. The stub Net::XMPP is the one t/unit/lib/26 uses, injected
# into %INC, so what is exercised is the REAL _xmpp_send - the staging asserted below
# is the delivery path's own, not a parallel imitation of it. $SRV_RESOLVER answers
# nothing by default; the SRV case swaps in an answer deliberately.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

require Lazysite::Notify;

our @CALLS;
our %BEHAVIOUR;

{
    package Net::XMPP::Client;
    sub new { bless {}, shift }
    sub Connect {
        my ( $self, %a ) = @_;
        push @CALLS, [ 'Connect', $a{hostname}, $a{port} ];
        return $BEHAVIOUR{connect_fails} ? undef : 1;
    }
    sub AuthSend {
        push @CALLS, ['AuthSend'];
        return $BEHAVIOUR{auth_fails} ? ('not-authorized') : ('ok');
    }
    sub Send { push @CALLS, ['Send']; 1 }
    sub MessageSend {
        my ( $self, %a ) = @_;
        push @CALLS, [ 'MessageSend', $a{to}, $a{type}, $a{body} ];
        die "the server closed the stream\n" if $BEHAVIOUR{send_dies};
        return 1;
    }
    sub Disconnect { push @CALLS, ['Disconnect']; 1 }

    package Net::XMPP::Presence;
    sub new          { bless {}, shift }
    sub SetTo        { 1 }
    sub InsertRawXML { 1 }

    package Net::XMPP;
}
$INC{'Net/XMPP.pm'} = 'stubbed-by-test';
$Lazysite::Notify::SRV_RESOLVER = sub { return () };

# A site with the extension enabled unless told otherwise, an optional
# notify-xmpp.conf, and a site_url that is a literal by default.
sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: Test Site\n";
    print {$cf} 'site_url: ' . ( $o{site_url} // 'https://test.example' ) . "\n";
    print {$cf} "extensions:\n  - plugins/notify-xmpp.pl\n" unless $o{disabled};
    close $cf;
    if ( defined $o{conf} ) {
        open my $xf, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
        print {$xf} $o{conf};
        close $xf;
    }
    return $d;
}

my $GOOD = "jid: bot\@chat.example\npassword: pw\nto: ops\@chat.example\n";

# Run the test action against a site, with STDERR captured so the log lines the
# delivery path writes do not litter the suite's output.
sub test_on {
    my ( $d, %b ) = @_;
    @CALLS     = ();
    %BEHAVIOUR = %b;
    my ( $err, $res );
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $res = Lazysite::Notify::test_xmpp($d);
    }
    return $res;
}

sub step_named {
    my ( $res, $name ) = @_;
    my ($s) = grep { $_->{step} eq $name } @{ $res->{steps} // [] };
    return $s;
}

# --- the states that never reach a socket -----------------------------------
#
# Each is one of X3's four, and the TEST ACTION has to carry the reason to the
# operator: the log line it writes is addressed to whoever reads the error log
# afterwards, which is exactly the person who is not standing at the config page.

subtest 'the extension is off - said plainly, and nothing is attempted' => sub {
    my $res = test_on( site( disabled => 1, conf => $GOOD ) );
    ok( !$res->{ok}, 'the test does not report success' );
    is( $res->{stage}, 'config', 'and stops at config' );
    like( $res->{error}, qr/switched off/, 'naming the state' );
    is( scalar @CALLS, 0, 'with no connection attempted' );
};

subtest 'enabled and never configured - names what to do, not just what is wrong' => sub {
    my $res = test_on( site() );
    ok( !$res->{ok}, 'the test does not report success' );
    is( $res->{stage}, 'config', 'it stops at config' );
    like( $res->{error}, qr/no XMPP configuration yet/, 'the state is named' );
    like( $res->{error}, qr/Save/,                      'and so is the next step' );
};

subtest 'enabled and incomplete - names the missing key' => sub {
    my $res = test_on( site( conf => "jid: bot\@chat.example\nto: ops\@chat.example\n" ) );
    ok( !$res->{ok}, 'the test does not report success' );
    like( $res->{error}, qr/incomplete: no password/,
        'the key is named - "incomplete" alone sends the operator back through all of them' );
    is( scalar @CALLS, 0, 'and nothing is sent' );
};

# --- the whole way through --------------------------------------------------

subtest 'a configured site: every stage reported, in order' => sub {
    my $res = test_on( site( conf => $GOOD ) );
    ok( $res->{ok}, 'the test succeeds' ) or diag explain $res;
    is( $res->{stage}, 'ok', 'and says so' );

    my @names = map { $_->{step} } @{ $res->{steps} };
    is_deeply( \@names, [qw(config library endpoint connect auth send)],
        'config, library, endpoint, connect, auth, send' )
        or diag explain \@names;
    ok( ( !grep { !$_->{ok} } @{ $res->{steps} } ), 'every stage passed' );

    like( step_named( $res, 'config' )->{detail}, qr/bot\@chat\.example/,
        'the config stage names the account it will sign in as' );
    like( step_named( $res, 'endpoint' )->{detail}, qr/chat\.example:5222/,
        'the endpoint stage names the host and port' );
    like( step_named( $res, 'auth' )->{detail}, qr/\bbot\b/,
        'the auth stage names the user, not just "ok"' );

    like( $res->{message}, qr/ops\@chat\.example/, 'the verdict names the recipient' );
    like( $res->{message}, qr/Check that it arrived/,
        'and does not claim delivery, which is not something a sender can know' );
};

subtest 'the rendered body is returned, and reads as a test' => sub {
    my $res = test_on( site( conf => $GOOD ) );
    my $sent = $res->{sent} // '';
    like( $sent, qr/\bTEST\b/,
        'it announces itself as a test - a room is often shared, and a test that '
            . 'reads like an alert teaches people to ignore alerts' );
    like( $sent, qr/Test Site/,     'it carries the site name, as a real notice does' );
    like( $sent, qr/Nothing needs doing/, 'and tells the reader not to act' );
    like( $sent, qr{https://test\.example/manager/plugins},
        'and the link a real notice would carry on this site' );

    my ($msg) = grep { $_->[0] eq 'MessageSend' } @CALLS;
    is( $msg->[3], $sent, 'what is reported is what was handed to the server' );
    is( $msg->[2], 'chat', 'sent as a chat message' );
};

# SM926 is the reason `sent` is shown rather than summarised: a site_url that is a
# TEMPLATE and no request to interpolate it against produced `://` in the body of
# every notification for an afternoon. The degradation to an absolute path is
# correct, and an operator reading the payload can see which one they have.
subtest 'no request context: the body degrades to a path, and shows it' => sub {
    my $res = test_on(
        site( conf => $GOOD, site_url => '${REQUEST_SCHEME}://${SERVER_NAME}' ) );
    ok( $res->{ok}, 'the test still succeeds' );
    unlike( $res->{sent}, qr{://},
        'the body carries no half-built URL - that is SM926, and it was invisible '
            . 'until somebody read a payload' );
    like( $res->{sent}, qr{/manager/plugins},
        'the path survives, which a reader can still use against the host they are on' );
};

# --- X2 at config time ------------------------------------------------------

subtest 'the endpoint stage says WHERE the endpoint came from' => sub {
    {
        local $Lazysite::Notify::SRV_RESOLVER
            = sub { return ( 'xmpp.relay.example', 47594 ) };
        my $res = test_on( site( conf => $GOOD ) );
        my $d   = step_named( $res, 'endpoint' )->{detail};
        like( $d, qr/xmpp\.relay\.example:47594/, 'the resolved endpoint is named' );
        like( $d, qr/SRV record/,
            'and that it was resolved - "47594" without that is a number the '
                . 'operator cannot account for' );
    }

    my $res = test_on( site( conf => $GOOD . "port: 5269\n" ) );
    like( step_named( $res, 'endpoint' )->{detail}, qr/5269 - as configured/,
        'a named port is reported as the operator\'s own, with nothing looked up' );

    $res = test_on( site( conf => $GOOD ) );
    like( step_named( $res, 'endpoint' )->{detail}, qr/nothing else was published/,
        'and 5222 by default says so - which is the distinction X2 cost an '
            . 'afternoon for the want of' );
};

# --- the failures, each named at its own stage ------------------------------

subtest 'nothing answers: reported at connect, with the address tried' => sub {
    my $res = test_on( site( conf => $GOOD ), connect_fails => 1 );
    ok( !$res->{ok}, 'the test fails' );
    is( $res->{stage}, 'connect', 'at the connect stage' );
    like( $res->{error}, qr/chat\.example:5222/, 'naming what it tried to reach' );
    ok( !step_named( $res, 'auth' ),
        'and no auth stage is reported, because none was attempted' );
};

subtest 'the account is refused: reported at auth, not as a connection fault' => sub {
    my $res = test_on( site( conf => $GOOD ), auth_fails => 1 );
    ok( !$res->{ok}, 'the test fails' );
    is( $res->{stage}, 'auth', 'at the auth stage' );
    ok( step_named( $res, 'connect' )->{ok},
        'with connect still reported as having SUCCEEDED - the pair is the whole '
            . 'value of staging' );
    like( $res->{error}, qr/not-authorized/, 'and the server\'s own refusal' );
};

subtest 'a stage that dies is still named' => sub {
    my $res = test_on( site( conf => $GOOD ), send_dies => 1 );
    ok( !$res->{ok}, 'the test fails' );
    is( $res->{stage}, 'send',
        'at send - a death records nothing by itself, so the result would '
            . 'otherwise report the last stage that WORKED as where it stopped' );
    like( $res->{error}, qr/closed the stream/, 'carrying the underlying error' );
    ok( step_named( $res, 'auth' )->{ok}, 'and auth stays reported as passed' );
};

# --- the room ---------------------------------------------------------------

subtest 'a MUC recipient: the join is reported, and NOT claimed as confirmed' => sub {
    my $res = test_on( site( conf => $GOOD . "muc: 1\n" ) );
    ok( $res->{ok}, 'the test succeeds' );
    my $join = step_named( $res, 'join' );
    ok( $join, 'the join is a stage of its own' );
    ok( $join->{unconfirmed},
        'marked unconfirmed, because this path sends a presence and reads nothing '
            . 'back - a room that refuses the join answers nowhere this code looks, '
            . 'and calling that success is the four-state fault in miniature' );
    like( $join->{detail}, qr/never arriving/, 'and the consequence is spelt out' );

    my ($msg) = grep { $_->[0] eq 'MessageSend' } @CALLS;
    is( $msg->[2], 'groupchat', 'the message itself is groupchat' );
    like( step_named( $res, 'config' )->{detail}, qr/group chat room/,
        'and the config stage says the recipient is a room' );
};

# --- X1 ---------------------------------------------------------------------

subtest 'the client library is missing: its own stage, naming the package' => sub {
    my $d = site( conf => $GOOD );
    my $res;
    {
        local %INC = %INC;
        delete $INC{'Net/XMPP.pm'};
        local @INC = (
            sub {
                die "Can't locate Net/XMPP.pm in \@INC\n"
                    if $_[1] eq 'Net/XMPP.pm';
                return;
            },
            @INC
        );
        $res = test_on($d);
    }
    ok( !$res->{ok}, 'the test fails' );
    is( $res->{stage}, 'library', 'at the library stage' );
    like( $res->{error}, qr/libnet-xmpp-perl/,
        'naming the Debian package - X1 was an afternoon spent over four '
            . 'submissions on exactly this, and the answer is one line' );
    ok( !step_named( $res, 'endpoint' ),
        'and nothing further is reported, because nothing further ran' );
};

# --- what a test must NOT do -----------------------------------------------

subtest 'a test leaves no notice behind' => sub {
    my $d   = site( conf => $GOOD );
    my $res = test_on($d);
    ok( $res->{ok}, 'the test succeeded' );
    ok( !-e "$d/lazysite/logs/notices.jsonl",
        'and wrote no bell row. The reporter\'s only way to test this was a real '
            . 'form submission, which left a stored row only a person can delete '
            . '(SM924) - a test that leaves evidence behind is not a test' );
};

# --- the wiring, end to end through the plugin -----------------------------
#
# The staging above all runs in-process. This runs the plugin the way the manager
# does, as a subprocess, which is the only thing that proves the descriptor's
# action, the --scan mode and the @INC search actually meet. The case chosen is one
# that stops at config, so no network is involved in a child this file cannot stub.

subtest 'the plugin answers --scan with the same result' => sub {
    my $d     = site();    # enabled, not configured
    my $pl    = "$FindBin::Bin/../../../plugins/notify-xmpp.pl";
    my $out   = qx{$^X "$pl" --scan --docroot "$d" 2>/dev/null};
    my $res   = eval { decode_json($out) };
    ok( $res, 'it answers JSON' ) or diag "output was: $out";
    ok( !$res->{ok},     'reporting the failure' );
    is( $res->{stage},   'config', 'with the same stage as the module reports' );
    like( $res->{error}, qr/no XMPP configuration yet/, 'and the same sentence' );
};

subtest 'the action is declared, gated on the account' => sub {
    my $pl   = "$FindBin::Bin/../../../plugins/notify-xmpp.pl";
    my $desc = decode_json( scalar qx{$^X "$pl" --describe} );
    my ($action) = grep { $_->{id} eq 'test' } @{ $desc->{actions} // [] };
    ok( $action, 'notify-xmpp declares a test action' );
    like( $action->{label}, qr/test/i, 'with a label that says what it does' );
    is( $action->{needs}, 'jid',
        'gated on the client JID, so the button is never a test against nothing' );
};

done_testing();
