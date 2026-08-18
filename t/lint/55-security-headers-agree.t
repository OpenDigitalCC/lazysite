#!/usr/bin/perl
# SM352: the processor's copy of the security header set must match the module.
#
# WHY THE FACT EXISTS TWICE. Lazysite::SecurityHeaders owns the set. The render
# path in lazysite-processor.pl cannot call it - the processor loads no Lazysite
# modules (ADR 0001) - so it carries its own copy, exactly as _acl_allows_read
# copies Auth::Acl and the private-store path is copied into install.pl. This
# pins the pair, in the same treatment t/lint/51 gives that one.
#
# BY VALUE, NOT BY TEXT. The two are written differently - one builds the
# Permissions-Policy from a list, the other spells it out, because a list-and-map
# in the processor would be a second thing to keep in step. So this evaluates
# both and compares the header lines they produce. A copy that drifts in the
# max-age, drops a denied capability or reorders the set fails here.
#
# WHAT IT PROTECTS. The reason SM352 exists at all is a header set maintained by
# repetition: four response paths each wrote their own list, three of them
# shorter, and the field probe that measured the homepage reported all three
# headers correct while every stylesheet and SVG the processor served carried one
# of them. Consolidating fixed today; this is what stops it recurring.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use Digest::SHA               qw(sha256);
use MIME::Base64              qw(encode_base64);
use TestHelper                qw(repo_root);
use Lazysite::SecurityHeaders ();

my $root = repo_root();

my $src = do {
    open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
    local $/;
    <$fh>;
};

# A body with the shapes that actually decide the answer: two distinct inline
# scripts, one REPEAT (which must collapse to a single hash rather than being
# listed twice), one <script src> (covered by 'self', and hashing it would
# produce a hash of the empty string that permits every empty script on the
# page), and a body with the characters a naive copy would trim.
my $FIXTURE = <<'HTML';
<html><head>
<script>var a = 1;  </script>
<script src="/assets/lazysite-chrome.js"></script>
<script>
  (function(){ document.title = "x"; })();
</script>
<script>var a = 1;  </script>
</head><body>hello</body></html>
HTML

subtest 'the processor carries the copy, and it agrees' => sub {
    my $pkg = 'ProcessorHeadersUnderTest';
    for my $name (qw(_security_headers _inline_script_hashes _content_security_policy)) {
        my ($sub) = $src =~ /(\nsub \Q$name\E \{.*?\n\}\n)/s;
        ok( $sub, "lazysite-processor.pl carries its own $name" ) or return;
        eval "package $pkg; use Digest::SHA qw(sha256); "
            . "use MIME::Base64 qw(encode_base64); $sub 1;"
            or do { fail("could not evaluate $name: $@"); return };
    }

    for my $https ( 0, 1 ) {
        for my $html ( undef, $FIXTURE ) {
            local $ENV{HTTPS} = $https ? 'on' : '';
            my @module = Lazysite::SecurityHeaders::security_headers(
                https => $https,
                ( defined $html ? ( html => 1, script_hashes =>
                            [ Lazysite::SecurityHeaders::inline_script_hashes($html) ] ) : () ),
            );
            my @copy = ProcessorHeadersUnderTest::_security_headers(
                ( defined $html ? ( html => $html ) : () ) );
            is_deeply( \@copy, \@module,
                sprintf( '%s, %s',
                    $https        ? 'over TLS'                : 'over plain HTTP',
                    defined $html ? 'HTML with inline script' : 'no body' ) )
                or diag( "module:    @module\n"
                    . "processor: @copy\n"
                    . 'The engine would answer one set on the front door and '
                    . 'another on every page it renders.' );
        }
    }
};

subtest 'the hashes are what a browser would compute' => sub {
    # Computed here from first principles rather than by calling the thing under
    # test, because a hash that is wrong in both copies agrees with itself
    # perfectly and blocks the script in every browser while every test passes.
    my @want = map { "'sha256-" . encode_base64( sha256($_), '' ) . "'" }
        ( 'var a = 1;  ', "\n  (function(){ document.title = \"x\"; })();\n" );

    my @got = Lazysite::SecurityHeaders::inline_script_hashes($FIXTURE);
    is_deeply( \@got, \@want, 'both inline bodies, hashed over their exact bytes' )
        or diag( 'A hash computed over trimmed or normalised source matches '
            . 'nothing, and fails silently in the browser on a page that '
            . 'renders blank.' );
    is( scalar @got, 2, 'the repeat collapsed and the <script src> was skipped' );
};

subtest 'HSTS is short, unqualified, and secure-only' => sub {
    # The value is the whole risk. A browser that has seen this refuses plain
    # HTTP to the host for max-age seconds and there is no way to reach a
    # visitor who has already been told, so a default that ships wrong cannot be
    # withdrawn - only waited out.
    cmp_ok( $Lazysite::SecurityHeaders::HSTS_MAX_AGE, '<=', 86_400,
        'max-age is a short starting value, not a ramped one' )
        or diag( 'Raising it is an operator decision against a running fleet. '
            . 'Shipping it raised is a decision made blind on their behalf.' );

    my ($hsts) = grep { /^Strict-Transport-Security:/ }
        Lazysite::SecurityHeaders::security_headers( https => 1 );
    ok( $hsts, 'HSTS is emitted over TLS' );
    unlike( $hsts, qr/includeSubDomains/,
        'without includeSubDomains - it binds hosts this instance may not serve' );
    unlike( $hsts, qr/preload/,
        'and without preload, which is effectively irreversible and is the '
            . "domain owner's decision rather than the engine's" );

    my @plain = Lazysite::SecurityHeaders::security_headers( https => 0 );
    is( scalar( grep { /^Strict-Transport-Security:/ } @plain ),
        0, 'and none at all over plain HTTP' );
};

subtest 'every response path emits the set' => sub {
    # The defect this replaces was three paths writing a shorter list. Anything
    # printing the first header by hand is a path that has started its own.
    my @stray;
    for my $file (qw(lazysite-processor.pl lazysite-front.pl)) {
        open my $fh, '<', "$root/$file" or die $!;
        my ( $n, $in_def ) = ( 0, 0 );
        while ( my $l = <$fh> ) {
            $n++;

            # The definition names all four headers, so without this the check
            # flags its own subject - a mistake worth leaving a note about,
            # since it looked exactly like a real finding.
            $in_def = 1 if $l =~ /^sub _security_headers \{/;
            if ($in_def) { $in_def = 0 if $l =~ /^\}/; next }

            next if $l     =~ /^\s*#/;
            next unless $l =~ /X-Content-Type-Options|X-Frame-Options|Referrer-Policy/;
            next if $l     =~ /_security_headers|security_headers\(/;
            push @stray, "$file:$n";
        }
        close $fh;
    }
    is_deeply( \@stray, [],
        'no response path spells a security header out for itself' )
        or diag( "Hand-written at: @stray\n"
            . 'That is how three of four paths ended up shorter than the '
            . 'fourth, invisibly to anyone probing the homepage.' );
};

done_testing();
