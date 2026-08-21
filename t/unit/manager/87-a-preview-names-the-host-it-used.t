#!/usr/bin/perl
# SM436, diagnostics half: a preview must name the Host it rendered under, and
# an unmatched Host must leave a trace.
#
# The validation half of SM436 prevents NEW instances of the fault. This is the
# half that would have made the existing one findable, and that is where the
# afternoon actually went: all three diagnostics agreed the configuration was
# fine. domain-preview rendered the site perfectly, domains-list showed a
# complete record, and domain-check blamed DNS.
#
# domain_preview feeds the STORED key back in as the Host, so it agrees with
# the configuration BY CONSTRUCTION - it cannot detect a name no real request
# carries, which is precisely the fault. Naming the Host does not fix the blind
# spot; nothing at preview scope can. It stops the answer being read as one it
# did not give.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();

subtest 'preview_public reports the host it rendered under' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite", "$d/sites/one" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: P\nalias_hosts: one.example\n"
        . "alias.one.example.content_root: sites/one\n";
    close $c;
    $Lazysite::Manager::Domains::DOCROOT = $d;

    # The derivation is what the caller stakes the render on, so assert it
    # directly - the render itself needs a processor and is covered elsewhere.
    my ($owner) = Lazysite::Manager::Domains::host_for_path('sites/one/x.md');
    is( $owner, 'one.example',
        'the owning host is resolved, and is what preview_public reports' );

    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Domains.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/rendered_as_host\s*=>\s*\$rendered_as/,
        'preview_public returns the host in its result' );
};

subtest 'domain_preview says the Host was SUPPLIED, not observed' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Domains.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/rendered_as_host => \$host/,
        'it names the host it used' );
    like( $src, qr/cannot show whether visitors arrive under it/,
        'and says what it therefore cannot tell you' )
        or diag( 'Without this, "it previews fine" reads as "it will serve" - '
            . 'which is exactly how a domain nobody could reach passed every '
            . 'check an operator ran.' );
};

subtest 'the processor logs a Host that matches no configured domain' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/host matched no configured domain - serving the default site/,
        'the silent fallthrough now leaves one greppable line' )
        or diag( 'A configured domain that never matches is served as the '
            . 'primary, and the engine could not know it was disappointing '
            . 'anyone. One line turns that into something findable.' );
    like( $src, qr/if \( defined \$defs\{alias_hosts\} \)/,
        'and only where aliases are configured, so single-site installs are quiet' );
};

done_testing();
