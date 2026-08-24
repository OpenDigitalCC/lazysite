#!/usr/bin/perl
# SM425 item 1: a SIGNED-IN member bypasses the anonymous submission rate
# limit; anonymous traffic keeps it unchanged; a forged cookie buys nothing.
#
# The gate needs a verified identity, which the handler deliberately does not
# read from headers (SM402) and now CAN obtain (SM411's shared session
# verifier). The identity is a BOOLEAN here: the fourth subtest holds the
# SM402 line - even a signed-in submission records no actor anywhere.
use strict;
use warnings;
use Test::More;
use File::Temp  qw(tempdir);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $handler = "$root/plugins/form-handler.pl";
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/lazysite/forms");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
# The form: file target, rate limit of 2, spam controls off so the limiter is
# the only gate under test.
open my $ff, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print {$ff} "rate_limit: 2\nspam_dwell: off\n- type: file\n";
close $ff;
open my $sf, '>', "$docroot/lazysite/auth/.secret" or die $!;
print {$sf} 'a' x 64;
close $sf;
# The FORMS secret is separate from the auth secret, and the handler refuses
# without it ("render a form page first") - the rig writes it and mints the
# timing token pair the way the renderer does.
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} 'b' x 64;
close $fs;
# A real account through the real writer, so the cookie verifies against a
# store the verifier actually consults (registry + account checks).
qx($^X \Q$root/tools/lazysite-users.pl\E --docroot \Q$docroot\E add zz9member pw123456789 2>/dev/null);

sub mint_cookie {
    my ($user) = @_;
    my $pay = "$user:" . time . ':';
    return "lazysite_auth=$pay:" . hmac_sha256_hex( $pay, 'a' x 64 );
}

sub submit {
    my (%extra) = @_;
    my $ts      = time - 10;    # past the too-fast floor, inside the window
    my $tk      = hmac_sha256_hex( $ts, 'b' x 64 );
    my $body    = "_form=contact&name=x&_hp=&_ts=$ts&_tk=$tk";
    my $bf      = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        # env_passthrough drops PERL5OPT; the resilience subtest needs its
        # @INC hook to reach the CHILD, or the blocker blocks nothing.
        ( $ENV{PERL5OPT} ? ( PERL5OPT => $ENV{PERL5OPT} ) : () ),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        %extra,
    );
    return qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
}

subtest 'anonymous traffic keeps the limit, unchanged' => sub {
    submit() for 1 .. 2;
    # The spam-family refusal is DELIBERATELY uninformative to the client
    # (the reason goes to the log only) - so the observable is ok:0 against
    # the accepted posts' ok:1, not the reason text.
    my $third = submit();
    like( $third, qr/"ok":0/, 'the third anonymous post refuses' );
};

subtest 'A SIGNED-IN MEMBER IS EXEMPT' => sub {
    my $out;
    $out = submit( HTTP_COOKIE => mint_cookie('zz9member') ) for 1 .. 3;
    like( $out, qr/"ok":1/,
        'the same address, over the limit, posts freely with a verified session' )
        or diag( 'A member filling in a long form repeatedly is the case the '
            . 'limit is not aimed at; refusing them reads as a broken site.' );
};

subtest 'a forged cookie buys nothing' => sub {
    my $pay = 'zz9member:' . time . ':';
    my $out = submit(
        HTTP_COOKIE => "lazysite_auth=$pay:" . ( 'f' x 64 ) );
    like( $out, qr/"ok":0/,
        'a bad signature is anonymous traffic, and the address is over its limit' );
};

subtest 'THE SM402 LINE HOLDS: no actor recorded, signed in or not' => sub {
    # The identity is a boolean for the limiter. The stored submission and the
    # audit trail must carry no username - that is the invariant t/unit/forms/07
    # pins in the source, held here against the behaviour.
    my @subs = glob "$docroot/lazysite/forms/submissions/*";
    ok( @subs, 'submissions stored' );
    my $blob = '';
    for my $f (@subs) {
        open my $fh, '<', $f or next;
        local $/;
        $blob .= <$fh>;
        close $fh;
    }
    unlike( $blob, qr/zz9member/, 'no stored submission names the account' );
    # The users tool's own add legitimately audits the TARGET name; the line
    # under guard is the submission's. So: no form-submission audit entry may
    # carry the account.
    my @form_lines;
    if ( open my $ah, '<', "$docroot/lazysite/logs/audit.log" ) {
        @form_lines = grep { /form/ } <$ah>;
        close $ah;
    }
    ok( !( grep { /zz9member/ } @form_lines ),
        'no form-submission audit entry names the account' )
        or diag( join '', @form_lines );
};

subtest 'A BROKEN EXEMPTION COSTS A MEMBER A RATE LIMIT, NEVER ANYBODY A FORM' => sub {
    # The field shape that bit this branch twice before landing: on a real
    # install nothing puts lib/ on @INC the way prove -l does, and a bare
    # require would have killed EVERY submission with a generic error. An
    # @INC hook (SM495's pattern) makes this host into that host.
    my $hookdir = tempdir( CLEANUP => 1 );
    open my $bh, '>', "$hookdir/BlockSession.pm" or die $!;
    print {$bh} <<'PM';
package BlockSession;
# Pre-claim the module in %INC: require becomes a no-op into an EMPTY
# package, so the handler's call dies at runtime - inside its eval. An @INC
# die-hook is defeated by the handler's own bootstrap, which unshifts the
# real lib directory AHEAD of any hook; poisoning %INC survives that, and
# "loaded but broken" is the truer field shape anyway.
$INC{'Lazysite/Auth/Session.pm'} = __FILE__;
1;
PM
    close $bh;
    local $ENV{PERL5OPT} = "-I$hookdir -MBlockSession";
    my $ok = submit( REMOTE_ADDR => '198.51.100.7' );
    like( $ok, qr/"ok":1/, 'with Session unloadable, an anonymous submission still WORKS' )
        or diag( 'If this is the generic error, the exemption died and took '
            . 'every form on the site with it.' );
    submit( REMOTE_ADDR => '198.51.100.7' );
    my $third = submit( REMOTE_ADDR => '198.51.100.7' );
    like( $third, qr/"ok":0/, 'and the anonymous limit still applies' );
    my $cookie = submit( REMOTE_ADDR => '198.51.100.7', HTTP_COOKIE => mint_cookie('zz9member') );
    like( $cookie, qr/"ok":0/,
        'a signed-in member degrades to anonymous rather than to a dead form' );
};

done_testing();
