#!/usr/bin/perl
# SM1375: the shipped 403.md named the groups a page needs as "- reviewers" lines
# inside one paragraph, not as a list. Markdown runs before Template Toolkit, so the
# FOREACH directive line sat against the items and the list never started. The
# template now writes the list as HTML, so both refusals that render it - a
# front-matter group gate and an acls.json read list - show a <ul> of <li>.
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

spit( "$d/gated.md", "---\ntitle: Gated\nauth_groups: [reviewers, leads]\n---\nGATED-BODY\n" );
spit( "$d/panel/index.md", "---\ntitle: Panel\n---\nPANEL-INDEX\n" );
spit( "$d/lazysite/auth/acls.json", encode_json( { panel => { read => [ '@reviewers', '@leads' ] } } ) );

my %OUTSIDER = (
    LAZYSITE_AUTH_TRUSTED => '1',
    HTTP_X_REMOTE_USER    => 'bob',
    HTTP_X_REMOTE_GROUPS  => 'visitors',
    HTTP_ACCEPT           => 'text/html,application/xhtml+xml,*/*;q=0.8',
);

for my $case ( [ '/gated', 'a front-matter group gate' ], [ '/panel/', 'an acls.json read list' ] ) {
    my ( $uri, $what ) = @$case;
    subtest "$what lists its groups" => sub {
        unlink "$d/403.html", glob("$d/panel/*.html"), "$d/gated.html";
        my $out = run_processor( $d, $uri, %OUTSIDER );
        my ($st) = $out =~ /^Status:\s*(\d+)/m;
        is( $st, 403, "$uri is refused" );
        my ($ul) = $out =~ m{(<ul\b[^>]*>.*?</ul>)}s;
        ok( defined $ul, '  the groups are a <ul>' ) or diag $out;
        $ul //= '';
        like( $ul, qr{<li>\s*reviewers\s*</li>}, '  reviewers is a list item' );
        like( $ul, qr{<li>\s*leads\s*</li>},     '  leads is a list item' );
        unlike( $out, qr/^\s*-\s+(?:reviewers|leads)\s*$/m, '  no "- name" line is left' );
    };
}

done_testing();
