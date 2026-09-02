#!/usr/bin/perl
# SM729: the page-parse guard is shared, so both write stacks enforce it.
#
# SM708 built the check as a private sub in lazysite-mcp.pl, so the WebDAV PUT
# path never saw it. Measured in the field on 0.11.10: a deliberately
# unparseable body was ACCEPTED over WebDAV on an auth-enabled site that
# interpolates auth variables - where such a page renders with every [% %] dead.
#
# Nobody had decided WebDAV should be exempt. SM189 had already settled the
# pattern one function above in the same module: a content refusal lives in
# Lazysite::Manager::Common, both write paths call it, and DAV refuses BEFORE
# the rename so nothing lands on disk.
#
# THIS TEST IS ABOUT REACH, not about the parse rule itself - t/unit/manager/140
# owns that. What is asserted here is that the fact lives in ONE place and that
# both callers consult it, which is the property that broke.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Manager::Common ();

my $root = repo_root();

subtest 'the guard lives in the shared module, beside its sibling' => sub {
    ok( Lazysite::Manager::Common->can('page_parse_refusal'),
        'page_parse_refusal is in Lazysite::Manager::Common' );
    ok( Lazysite::Manager::Common->can('raw_html_page_refusal'),
        'and so is the SM189 sibling whose pattern it follows' );

    my $src = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Common.pm" or die $!;
        local $/; <$fh>;
    };
    like( $src, qr/EXPORT_OK.*page_parse_refusal/s,
        'it is exported, so a caller need not reach into the package' );
};

subtest 'it refuses what it should and accepts what it should' => sub {
    my $bad  = "---\ntitle: X\n---\n<script>u = /\\[%/.test(u);</script>\n[% auth_user %]\n";
    my $good = "---\ntitle: X\n---\nHello [% auth_user %]\n";
    my $none = "---\ntitle: X\n---\nJust prose.\n";

    ok( Lazysite::Manager::Common::page_parse_refusal( '/p.md', $bad ),
        'an unparseable body is refused' );
    ok( !Lazysite::Manager::Common::page_parse_refusal( '/p.md', $good ),
        'a page using template variables normally is accepted' );
    ok( !Lazysite::Manager::Common::page_parse_refusal( '/p.md', $none ),
        'a page with no template syntax is accepted' );
    ok( !Lazysite::Manager::Common::page_parse_refusal( '/p.txt', $bad ),
        'a non-markdown path is not a page and is not checked' );
};

subtest 'both write stacks consult it' => sub {
    my %src;
    for my $f (qw(lazysite-dav.pl lazysite-mcp.pl)) {
        open my $fh, '<', "$root/$f" or die "$f: $!";
        $src{$f} = do { local $/; <$fh> };
        close $fh;
    }

    like( $src{'lazysite-mcp.pl'}, qr/Lazysite::Manager::Common::page_parse_refusal/,
        'the MCP write path calls the shared guard' );
    like( $src{'lazysite-dav.pl'}, qr/Lazysite::Manager::Common::page_parse_refusal/,
        'the WebDAV PUT path calls the shared guard' );

    # The MCP script must not carry its own copy any more, or the two could
    # disagree - which is the whole defect, one level down.
    unlike( $src{'lazysite-mcp.pl'}, qr/sub _check_template_parses/,
        'the MCP script no longer carries its own copy of the check' );
};

subtest 'the DAV path refuses before anything lands on disk' => sub {
    my $dav = do {
        open my $fh, '<', "$root/lazysite-dav.pl" or die $!;
        local $/; <$fh>;
    };
    # The refusal must unlink the temp file and answer 415, and it must do so
    # BEFORE the rename that publishes it - the ordering SM189 established.
    my $guard  = index( $dav, 'page_parse_refusal' );
    my $rename = index( $dav, 'rename $tmp, $r->{abs}' );
    cmp_ok( $guard, '>', -1, 'the guard is present on the PUT path' );
    cmp_ok( $rename, '>', -1, 'the publishing rename is present' );
    cmp_ok( $guard, '<', $rename,
        'the guard runs BEFORE the rename, so a refused page never lands' );

    my ($block) = $dav =~ /(page_parse_refusal.{0,400})/s;
    like( $block, qr/unlink \$tmp/, 'a refusal removes the temp file' );
    like( $block, qr/send_status\(\s*415/,
        '415 - the request was well formed, its content cannot be served' );
};

done_testing();
