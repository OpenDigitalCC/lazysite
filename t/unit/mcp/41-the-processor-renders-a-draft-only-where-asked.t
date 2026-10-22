#!/usr/bin/perl
# SM1030: the processor's half of a draft preview. The MCP server hands it a
# draft on STDIN with LAZYSITE_DRAFT_PATH naming the page; it renders the draft
# in that page's place, or answers 422 marked X-Lazysite-Draft: refused - and
# in either case writes nothing.
#
# Held here, where test 40 cannot reach (its caller never sends these):
#   - a draft is read only on a single-shot GET (a POST's STDIN is a visitor's);
#   - it renders only where the request resolves to the page it was given for;
#   - its bytes are strict UTF-8 and no more than 512 KiB;
#   - the path is a docroot-relative page;
#   - without the variable, STDIN is ignored and the saved page renders.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use File::Find  ();
use Digest::SHA qw(sha256_hex);
use IPC::Open3  qw(open3);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

my $root = repo_root();
my $d    = site_tempdir();
( my $site = $d ) =~ s{/[^/]+\z}{};

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/about.md",               "---\ntitle: About\n---\nSAVED-ABOUT\n" );
spit( "$d/404.md",                 "---\ntitle: NF\n---\nNot found.\n" );

# The processor as the MCP server runs it: CGI env, the draft on STDIN.
sub render {
    my (%o) = @_;
    local %ENV = ( env_passthrough(),
        PATH             => $ENV{PATH},
        DOCUMENT_ROOT    => $d,
        REDIRECT_URL     => $o{url}    // '/about',
        REQUEST_URI      => $o{url}    // '/about',
        REQUEST_METHOD   => $o{method} // 'GET',
        QUERY_STRING     => '',
        LAZYSITE_NOCACHE => '1',
        ( defined $o{draft_path} ? ( LAZYSITE_DRAFT_PATH => $o{draft_path} ) : () ),
    );
    my $resp = run_child( [ $^X, "$root/lazysite-processor.pl" ],
        stdin => $o{stdin}, stderr => 'merge' )->{out};
    my ( $head, $body ) = split /\r?\n\r?\n/, ( $resp // '' ), 2;
    my ($status) = ( $head // '' ) =~ /Status:\s*(\d+)/i;
    return { status => $status // 200, head => $head // '', body => $body // '' };
}

sub refused {
    my ( $r, $why, $label ) = @_;
    is( $r->{status}, 422, "$label: 422" );
    like( $r->{head}, qr/^X-Lazysite-Draft:\s*refused/mi, "$label: marked as a refused draft" );
    like( $r->{body}, $why,                               "$label: says why" );
    return;
}

sub snapshot {
    my %s;
    File::Find::find( { no_chdir => 1, wanted => sub {
                my $p = $File::Find::name;
                if ( -d $p ) { $s{$p} = 'dir'; return }
                open my $fh, '<:raw', $p or return;
                my $c = do { local $/; <$fh> };
                $s{$p} = ( stat $p )[9] . ':' . sha256_hex($c);
    } }, $site );
    return \%s;
}
my $before = snapshot();

my $draft = "---\ntitle: Draft\n---\nDRAFT-ABOUT caf\xC3\xA9\n";

subtest 'a draft renders in the page\'s place' => sub {
    my $r = render( draft_path => 'about.md', stdin => $draft );
    is( $r->{status}, 200, 'status 200' );
    like( $r->{body}, qr/DRAFT-ABOUT/, 'the draft' );
    unlike( $r->{body}, qr/SAVED-ABOUT/, 'not the saved page' );
    like( $r->{head}, qr/^Cache-Control:\s*no-store/mi, 'and is not to be stored by anything downstream' );

    my $new = render( url => '/fresh/page', draft_path => 'fresh/page.md', stdin => $draft );
    is( $new->{status}, 200, 'a page and folder that do not exist yet' );
    like( $new->{body}, qr/DRAFT-ABOUT/, 'render the draft' );
};

subtest 'refused where it was not asked for' => sub {
    refused( render( method => 'POST', draft_path => 'about.md', stdin => $draft ),
        qr/single-shot CGI GET/, 'a POST' );
    refused( render( url => '/about', draft_path => 'other.md', stdin => $draft ),
        qr/does not resolve to the page/, 'a request that resolves to another page' );
    refused( render( draft_path => '../about.md', stdin => $draft ), qr/not a docroot-relative page/, 'a climbing path' );
    refused( render( draft_path => '/about.md', stdin => $draft ), qr/not a docroot-relative page/, 'an absolute path' );
    refused( render( draft_path => 'about.txt', stdin => $draft ), qr/not a docroot-relative page/, 'not a page' );
};

subtest 'refused for what it carries' => sub {
    refused( render( draft_path => 'about.md', stdin => "---\ntitle: X\n---\nbad \xED\xA0\x80\n" ),
        qr/not valid UTF-8/, 'a surrogate' );
    refused( render( draft_path => 'about.md', stdin => "bad \xFF\n" ), qr/not valid UTF-8/, 'a stray byte' );
    refused( render( draft_path => 'about.md', stdin => 'x' x ( 512 * 1024 + 1 ) ),
        qr/larger than 524288 bytes/, 'one byte over 512 KiB' );
    my $at = render( draft_path => 'about.md', stdin => "---\ntitle: X\n---\n" . ( 'y' x ( 512 * 1024 - 18 ) ) );
    is( $at->{status}, 200, 'exactly 512 KiB renders' );
};

subtest 'nothing was written' => sub {
    is_deeply( snapshot(), $before, 'every file under the site is as it was' );
};

# Last: an ordinary render records a visit, which is not a draft's to make.
subtest 'without the variable, STDIN is not a draft' => sub {
    my $r = render( stdin => $draft );
    like( $r->{body}, qr/SAVED-ABOUT/, 'the saved page renders' );
    unlike( $r->{body}, qr/DRAFT-ABOUT/, 'and STDIN is ignored' );
};

done_testing;
