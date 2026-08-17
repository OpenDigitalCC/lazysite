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
use TestHelper                qw(repo_root);
use Lazysite::SecurityHeaders ();

my $root = repo_root();

my $src = do {
    open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
    local $/;
    <$fh>;
};

subtest 'the processor carries the copy, and it agrees' => sub {
    my ($sub) = $src =~ /(\nsub _security_headers \{.*?\n\}\n)/s;
    ok( $sub, 'lazysite-processor.pl carries its own _security_headers' )
        or return;

    my $pkg = 'ProcessorHeadersUnderTest';
    eval "package $pkg; $sub 1;"
        or do { fail("could not evaluate it: $@"); return };

    for my $https ( 0, 1 ) {
        local $ENV{HTTPS} = $https ? 'on' : '';
        my @module = Lazysite::SecurityHeaders::security_headers( https => $https );
        my @copy   = ProcessorHeadersUnderTest::_security_headers();
        is_deeply( \@copy, \@module,
            $https ? 'over TLS' : 'over plain HTTP' )
            or diag( "module:    @module\n"
                . "processor: @copy\n"
                . 'The engine would answer one set on the front door and '
                . 'another on every page it renders.' );
    }
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
