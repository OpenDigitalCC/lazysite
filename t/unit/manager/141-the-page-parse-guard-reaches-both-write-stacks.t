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

subtest 'the guard is called from the CHOKE POINT, and nowhere else but DAV' => sub {

    # SM748 REWROTE THIS SUBTEST, and the reason is the point of it.
    #
    # It used to open two named files - lazysite-dav.pl and lazysite-mcp.pl -
    # and assert each called the guard. Both did, so it passed, for two
    # releases, while `action=save` accepted unparseable bodies. THREE callers
    # write pages; it read two of them, and neither was the one at fault.
    #
    # A hand-written list of filenames can only ever be as complete as the day
    # somebody wrote it. So this walks the TREE instead and asserts a property
    # that a new caller cannot quietly fail: the guard lives at the shared
    # choke point every manager, control-API and MCP write passes through, and
    # the only other call site is the separate WebDAV stack.
    #
    # If a fourth surface appears, it either routes through action_save and
    # inherits the guard, or it adds a third call site and fails here - which
    # is the conversation we want to have.

    my @sites;
    my $walk;
    $walk = sub {
        my ($dir) = @_;
        opendir my $dh, $dir or return;
        for my $e ( sort readdir $dh ) {
            next if $e =~ /\A\.\.?\z/;
            next if $e eq '.git' or $e eq 't' or $e eq 'tmp' or $e eq 'dist';
            my $p = "$dir/$e";
            if ( -d $p ) { $walk->($p); next }
            next unless $e =~ /\.(?:pl|pm)\z/;
            next if $p =~ m{lib/Lazysite/Manager/Common\.pm\z};    # the definition
            open my $fh, '<', $p or next;
            my $s = do { local $/; <$fh> };
            close $fh;
            ( my $rel = $p ) =~ s{^\Q$root\E/}{};
            push @sites, $rel if $s =~ /page_parse_refusal\s*\(/;
        }
        closedir $dh;
    };
    $walk->($root);

    is_deeply(
        [ sort @sites ],
        [ 'lazysite-dav.pl', 'lib/Lazysite/Manager/Files.pm' ],
        'exactly two call sites: the shared choke point, and the separate DAV stack'
    ) or diag( "found: " . join( ', ', sort @sites ) );

    # The choke point is action_save specifically - the function the manager
    # UI, the control API and MCP all write through.
    my $files = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Files.pm" or die $!;
        local $/; <$fh>;
    };
    my ($body) = $files =~ /sub action_save \{(.*?)\n\}/s;
    ok( defined $body, 'action_save is present in the shared module' );
    like( $body, qr/page_parse_refusal/,
        'and it consults the guard itself, so its callers inherit it' );

    # Ordering: the refusal must precede the write, or the page is already on
    # disk when we complain about it - SM708's own reasoning.
    my $guard = index( $body, 'page_parse_refusal' );
    my $write = index( $body, 'write_file_checked' );
    cmp_ok( $guard, '>', -1, 'the guard is in action_save' );
    cmp_ok( $write, '>', -1, 'and so is the write' );
    cmp_ok( $guard, '<', $write, 'the guard runs BEFORE the write' );
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
