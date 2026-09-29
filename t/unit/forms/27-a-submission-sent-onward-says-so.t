#!/usr/bin/perl
# SM579: WHAT THE VISITOR IS TOLD WHEN THE SUBMISSION WENT TO A SERVICE.
#
# Before this there was one success sentence - "your message has been sent" - and
# a form whose only target is a connector does not send a message to anybody. It
# hands the submission to a service to be processed. The sentence was false on
# every such form, and the only alternative the code had was form-status-error
# with role="alert", which would have shown a working submission as a failure.
#
# RULED 2026-09-29: an engine-authored second success state, not author copy. The
# wording is fixed and the query string carries a TOKEN, because `?outcome=` is
# attacker-writable by construction - a sentence travelling in the URL would let a
# crafted link put any text on the page in the success style.
#
# THE CONNECTOR HERE IS REAL. It is a live HTTP::Daemon on 127.0.0.1, which the
# connector layer permits (`http://` to loopback only), driven through the real
# `call` - so the `type` the CGI reads comes from a delivery that actually
# happened. t/unit/forms/20's T7 note is why: a mock more permissive than the
# thing it stands for certifies the mock. The discriminator is worth nothing if
# the delivery it classifies is imaginary.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough);

BEGIN {
    eval { require HTTP::Daemon; require LWP::UserAgent; require YAML::PP; 1 }
        or plan skip_all => 'HTTP::Daemon/LWP/YAML::PP not available';
}
use Lazysite::Manager::Connectors ();

my $root    = repo_root();
my $cgi     = "$root/plugins/form-handler.pl";
my $docroot = site_tempdir();
make_path( "$docroot/lazysite/forms", "$docroot/lazysite/auth",
    "$docroot/lazysite/connectors", "$docroot/lazysite/logs", "$docroot/subs" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} 'c' x 64;
close $fs;

# --- the service at the far end, which answers and records nothing we assert on
my $srv = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 )
    or plan skip_all => "no loopback listener: $!";
my $base = $srv->url;
my $pid  = fork;
die "fork: $!" unless defined $pid;
if ( !$pid ) {
    while ( my $conn = $srv->accept ) {
        while ( my $req = $conn->get_request ) {
            my $res = HTTP::Response->new(200);
            $res->header( 'Content-Type' => 'application/json' );
            $res->content('{"ok":true}');
            $conn->send_response($res);
        }
        $conn->close;
    }
    exit 0;
}
END { kill 'TERM', $pid if $pid }

$Lazysite::Manager::Connectors::DOCROOT = $docroot;
my $saved = Lazysite::Manager::Connectors::action_connector_save( 'crm',
    { name => 'CRM', url => "${base}intake", modes => { public => 1 }, timeout => 5 } );
ok( $saved->{ok}, 'a connector the public may invoke is saved' ) or diag $saved->{error};

open my $hcf, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
print {$hcf} "handlers:\n"
    . "  - id: store\n    type: file\n    name: Store\n    path: $docroot/subs\n"
    . "  - id: onward\n    type: connector\n    name: Onward\n    connector: crm\n";
close $hcf;

sub form_conf {
    my ( $name, @targets ) = @_;
    open my $ff, '>', "$docroot/lazysite/forms/$name.conf" or die $!;
    print {$ff} "rate_limit: 0\ntargets:\n" . join( '', map {"  - handler: $_\n"} @targets );
    close $ff;
}
form_conf( 'tostore',  'store' );
form_conf( 'toservice', 'onward' );
form_conf( 'toboth',   'store', 'onward' );

my $IP = 0;

sub submit {
    my ( $name, %o ) = @_;
    my $ts = time - 10;
    my $tk = hmac_sha256_hex( $ts, 'c' x 64 );
    my %f  = ( _form => $name, name => 'Ada', _hp => '', _ts => $ts, _tk => $tk,
        _page => "/$name" );
    my $body = join '&', map { "$_=$f{$_}" } sort keys %f;
    my $bf = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '198.51.100.' . ( ++$IP ),
        %{ $o{env} || {} },
    );
    return qx($^X \Q$cgi\E < \Q$bf\E 2>/dev/null);
}

my $NATIVE = { HTTP_ACCEPT => 'text/html,application/xhtml+xml' };
my $JS     = { HTTP_ACCEPT => 'application/json' };

subtest 'A FORM WHOSE TARGET IS A SERVICE SAYS SO' => sub {
    my $out = submit( 'toservice', env => $NATIVE );
    like( $out, qr/^Status: 303/m, 'the submission was accepted' )
        or diag "the connector did not deliver, so nothing below means anything:\n$out";
    like( $out, qr{outcome=ok-processing}, 'and the token says it went for processing' )
        or diag( 'A connector delivery is the one case where "your message has been '
            . 'sent" is false, which is the whole of SM579.' );
};

subtest 'and a form whose target is a store keeps the sentence it had' => sub {
    # THE DISCRIMINATOR. Without this the test above passes on a CGI that says
    # ok-processing for everything, which would make the new sentence wrong
    # everywhere instead of right in one place.
    my $out = submit( 'tostore', env => $NATIVE );
    like( $out, qr{outcome=ok(?:&|\s*$)}m, 'outcome=ok, exactly as before' )
        or diag "a stored submission must not claim to have been sent onward:\n$out";
    unlike( $out, qr/ok-processing/, 'not the processing token' );
};

subtest 'a store AND a service is still onward - it did leave the site' => sub {
    my $out = submit( 'toboth', env => $NATIVE );
    like( $out, qr{outcome=ok-processing},
        'the stronger claim wins, because both things are true and one is news' );
};

subtest 'THE JS PATH IS TOLD THE SAME THING, in the sentence it carries' => sub {
    # The two paths cannot share code (ADR 0001 keeps the render path module-free),
    # so the JS reply carries the sentence and the redirect carries the token.
    # t/lint/156 holds the two maps equal; this proves the handler PICKS the same
    # entry on both paths rather than only on the one the lint can read.
    my $out = submit( 'toservice', env => $JS );
    like( $out, qr/"ok":1/, 'JSON success' );
    like( $out, qr/received and sent for processing/, 'with the processing sentence' );
    unlike( $out, qr/message has been sent/, 'and not the one that was untrue' );

    my $store = submit( 'tostore', env => $JS );
    like( $store, qr/message has been sent/, 'a stored submission still says sent' );
};

subtest 'AN OUTCOME THE MAP DOES NOT HOLD IS NOT A SUCCESS SENTENCE' => sub {
    # respond_ok falls back to `ok` for an unknown token rather than emitting it.
    # This is the guard that keeps the closed map closed from the inside: a future
    # caller passing a token nobody added cannot put its own text on the page.
    my $src = do {
        open my $fh, '<', $cgi or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/\$outcome\s*=\s*'ok'\s+unless\s+defined\s+\$outcome\s*&&\s*exists\s+\$OUTCOME_SAID\{\$outcome\}/,
        'an unknown token becomes `ok`, never travels' );
};

done_testing();
