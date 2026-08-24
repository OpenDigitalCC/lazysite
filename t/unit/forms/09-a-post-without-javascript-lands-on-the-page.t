#!/usr/bin/perl
# SM415: a form post without JavaScript lands back on the PAGE, not on raw
# JSON - the login pattern, which the forms were missing. The JS path
# declares Accept: application/json and keeps today's reply byte-for-byte;
# a native browser post is answered 303 back to the page named by the
# _page field the renderer embeds, carrying the outcome for the banner.
#
# The _page field is the whole open-redirect surface, so its guard is held
# here: same-site absolute paths only - no scheme, no protocol-relative,
# no CRLF - and ABSENT means JSON, because a stale cached page without the
# field must never be redirected to nowhere.
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
make_path("$docroot/lazysite/forms");
make_path("$docroot/lazysite/auth");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
open my $ff, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
print {$ff} "rate_limit: 0\n- type: file\n";
close $ff;
open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
print {$fs} 'b' x 64;
close $fs;

sub submit {
    my (%o) = @_;
    my $ts  = time - 10;
    my $tk  = hmac_sha256_hex( $ts, 'b' x 64 );
    my %f   = ( _form => 'contact', name => 'x', _hp => '', _ts => $ts, _tk => $tk,
        %{ $o{fields} || {} } );
    my $body = join '&', map { "$_=$f{$_}" } sort keys %f;
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '203.0.113.9',
        %{ $o{env} || {} },
    );
    return qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null);
}

my $NATIVE = { HTTP_ACCEPT => 'text/html,application/xhtml+xml' };
my $JS     = { HTTP_ACCEPT => 'application/json' };

subtest 'A NATIVE POST LANDS BACK ON THE PAGE' => sub {
    my $out = submit( env => $NATIVE, fields => { _page => '/contact' } );
    like( $out, qr/^Status: 303/m, '303, not a JSON page' );
    like( $out, qr{^Location: /contact\?form=contact&outcome=ok\s*$}m,
        'back to the page, outcome riding the query string' );
    unlike( $out, qr/"ok":/, 'and no JSON body' );
};

subtest 'the JS path is byte-for-byte what it was' => sub {
    my $out = submit( env => $JS, fields => { _page => '/contact' } );
    like( $out, qr/^Status: 200/m, '200' );
    like( $out, qr/"ok":1/,        'JSON, exactly as before' );
    unlike( $out, qr/^Status: 303/m, 'no redirect for a client that asked for JSON' );
};

subtest 'a refusal redirects back too, with the user-safe reason' => sub {
    # An upload to a form with no upload config is a reject_user - shown text.
    my $out = submit( env => $NATIVE,
        fields => { _page => '/contact', _hp => 'bot-filled' } );
    like( $out, qr/^Status: 303/m, 'refused AND redirected - no dead-end JSON' );
    like( $out, qr{^Location: /contact\?form=contact&outcome=(?!ok)}m,
        'the outcome is not ok, and the banner will say why it may' );
};

subtest 'THE OPEN-REDIRECT GUARD: _page is same-site or nothing' => sub {
    for my $evil ( 'https://evil.example/x', '//evil.example/x' ) {
        my $out = submit( env => $NATIVE, fields => { _page => $evil } );
        unlike( $out, qr/evil\.example/, "'$evil' never appears in the answer" );
        like( $out, qr/"ok":/, 'the post degrades to JSON rather than redirecting off-site' );
    }
};

subtest 'a stale page without _page stays JSON, never a redirect to nowhere' => sub {
    my $out = submit( env => $NATIVE );
    like( $out, qr/"ok":1/, 'JSON answer' );
    unlike( $out, qr/^Status: 303/m, 'no location-less redirect' );
};

done_testing();
