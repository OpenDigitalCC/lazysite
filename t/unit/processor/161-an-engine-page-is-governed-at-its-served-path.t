#!/usr/bin/perl
# SM1284, SM1285: AN ENGINE PAGE IS GOVERNED BY THE PATH IT IS SERVED AT.
#
# The /docs manual (SM1284) and the minimal home page (SM1285) are the engine's
# files, under lazysite/templates/, served at /docs/... and /. An access rule is
# keyed on the content path, and the engine's files have none of their own -
# inside the docroot they are lazysite/templates/..., beside it (SM293) they are
# outside every content path. So a site that keeps /docs/ to its members, or
# keeps the whole site private with a rule at /, would have served the engine's
# pages to anyone. They are named by the path they serve at, so the rule that
# would govern the site's own copy governs them - on both layouts.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor);

delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED)};

sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub status { return ( ( $_[0] // '' ) =~ /^Status: (\d+)/m )[0] // '200' }

sub site {
    my ($acls) = @_;
    my $d = site_tempdir();
    setup_minimal_site($d);
    unlink "$d/index.md";    # the engine's home serves
    spit( "$d/lazysite/templates/docs/guide.md", "---\ntitle: Guide\n---\nENGINE-GUIDE\n" );
    spit( "$d/lazysite/templates/system/home.md", "---\ntitle: Welcome\n---\nENGINE-HOME\n" );
    spit( "$d/lazysite/auth/acls.json", $acls ) if defined $acls;
    return $d;
}

for my $layout (qw(inside beside)) {
    my $move = sub {
        my ($d) = @_;
        return $d if $layout eq 'inside';
        rename "$d/lazysite", "$d-lazysite" or die "move the engine tree: $!";
        return $d;
    };

    subtest "$layout the docroot: no rule, both serve" => sub {
        my $d = $move->( site() );
        like( run_processor( $d, '/docs/guide' ), qr/ENGINE-GUIDE/, '/docs/guide serves' );
        like( run_processor( $d, '/' ),           qr/ENGINE-HOME/,  '/ serves the engine home' );
    };

    subtest "$layout the docroot: a rule over docs/ governs the manual" => sub {
        my $d   = $move->( site(qq({ "docs": { "read": ["alice"] } })) );
        my $out = run_processor( $d, '/docs/guide' );
        isnt( status($out), '200', 'an anonymous visitor is not served it' );
        unlike( $out, qr/ENGINE-GUIDE/, 'and does not see it' );
        like( run_processor( $d, '/' ), qr/ENGINE-HOME/, 'the home page, outside the rule, still serves' );
    };

    subtest "$layout the docroot: a rule at / governs both" => sub {
        my $d = $move->( site(qq({ "/": { "read": ["alice"] } })) );
        for my $uri (qw(/docs/guide /)) {
            my $out = run_processor( $d, $uri );
            isnt( status($out), '200', "$uri is not served to an anonymous visitor" );
            unlike( $out, qr/ENGINE-(?:GUIDE|HOME)/, '...nor shown' );
        }
    };
}

done_testing();
