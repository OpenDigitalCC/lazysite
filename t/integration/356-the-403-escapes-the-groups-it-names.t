#!/usr/bin/perl
# Ruling 141: the 403 page lists the groups a page needs (SM1375) from a page's
# front matter or an acls.json read list, neither of which is checked for shape.
# The names reached the page as markup: auth_required_groups was not among the
# auth values the stash escapes (SM709). They are escaped now, on both refusals.
use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor site_tempdir);

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $d = site_tempdir();
setup_test_site($d);
spit( "$d/lazysite/layouts/test/layout.tt",
    '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
        . '<body>[% content %]</body></html>' );
copy( "$FindBin::Bin/../../starter/lazysite/templates/system/403.md", "$d/403.md" ) or die "copy: $!";

spit( "$d/gated.md", "---\ntitle: Gated\nauth_groups: [reviewers, <i>bad</i>]\n---\nGATED-BODY\n" );
spit( "$d/panel/index.md", "---\ntitle: Panel\n---\nPANEL-INDEX\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( { panel => { read => [ '@reviewers', '@<i>bad</i>' ] } } ) );

my %OUTSIDER = (
    LAZYSITE_AUTH_TRUSTED => '1',
    HTTP_X_REMOTE_USER    => 'bob',
    HTTP_X_REMOTE_GROUPS  => 'visitors',
    HTTP_ACCEPT           => 'text/html,application/xhtml+xml,*/*;q=0.8',
);

# A front-matter gate's names are read by Lazysite::Validate's shape
# ([A-Za-z0-9_.-]); one with markup makes the rule unreadable, refused with a
# sentence that names no group. Held here so the escape below is not the only
# thing between a front-matter name and the page.
subtest 'a front-matter group gate naming markup refuses and names no group' => sub {
    unlink "$d/403.html", "$d/gated.html";
    my $out = run_processor( $d, '/gated', %OUTSIDER );
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    is( $st, 403, '/gated is refused' );
    unlike( $out, qr{<i>bad</i>},          '  the markup never reaches the page' );
    unlike( $out, qr{auth-required-groups}, '  no group list is shown' );
};

spit( "$d/gated2.md", "---\ntitle: Gated\nauth_groups: [reviewers, leads]\n---\nGATED-BODY\n" );

for my $case ( [ '/gated2', 'a front-matter group gate' ], [ '/panel/', 'an acls.json read list' ] ) {
    my ( $uri, $what ) = @$case;
    subtest "$what lists its groups escaped" => sub {
        unlink "$d/403.html", glob("$d/panel/*.html"), "$d/gated.html";
        my $out = run_processor( $d, $uri, %OUTSIDER );
        my ($st) = $out =~ /^Status:\s*(\d+)/m;
        is( $st, 403, "$uri is refused" );
        my ($ul) = $out =~ m{(<ul\b[^>]*>.*?</ul>)}s;
        ok( defined $ul, '  the groups are a <ul>' ) or diag $out;
        $ul //= '';
        like( $ul, qr{<li>\s*reviewers\s*</li>}, '  a plain name is listed' );
        if ( $uri eq '/panel/' ) {
            like( $ul, qr{<li>\s*&lt;i&gt;bad&lt;/i&gt;\s*</li>}, '  a name with markup is escaped' );
        }
        unlike( $out, qr{<i>bad</i>}, '  the markup never reaches the page' );
    };
}

done_testing();
