#!/usr/bin/perl
# Ruling 203: THE FASTCGI POOL RUNS THE SITE'S OWN ENGINE.
#
# The pool launcher used to exec the processor beside itself, the package's. On
# a Hestia or deb host whose package was upgraded before a site ran its own
# `upgrade`, the pool then rendered with the package's engine while the manager,
# auth and DAV CGIs ran the site's copy: one site, two engine versions (n788).
#
# The launcher is run here as the unit runs it, from a package tree, against a
# site laid as install.pl lays one (<dom>/public_html, <dom>/cgi-bin, <dom>/lib).
# The package's processor is a stand-in that answers "PACKAGE ENGINE A" and
# leaves a mark when it runs; the site's is a real copy of the engine. So:
#
#   - with the site's tree in place, a pool request renders the page (the
#     site's engine) and the package's never runs;
#   - with the site's processor gone, the request gets 503, the package's
#     engine never runs, the log names the missing file, and `lazysite check`
#     names the fault (ruling 206).
use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Basename qw(dirname);
use TestHelper qw(repo_root env_passthrough run_cmd site_tempdir);
use MiniFcgi   qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the pool needs it)' unless eval { require FCGI; 1 };

my $root = repo_root();
# site_tempdir lays <tmp>/site/public_html, the Hestia shape install.pl lays too.
my $doc  = site_tempdir();
my $dom  = dirname($doc);
my $base = dirname($dom);
my $me   = getpwuid($>);

sub spew {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh or die "$path: $!";
}

# --- the package tree: the launcher, and an engine at "version A" ---------------
my $pkg  = "$base/pkg";
my $mark = "$base/package-engine-ran";
make_path("$pkg/tools");
copy( "$root/tools/lazysite-pool.pl", "$pkg/tools/lazysite-pool.pl" ) or die "copy: $!";
spew( "$pkg/lazysite-processor.pl", <<"PKG" );
#!/usr/bin/perl
open my \$m, '>', '$mark' or die; close \$m;
require FCGI;
my \$r = FCGI::Request();
while ( \$r->Accept() >= 0 ) { print "Content-Type: text/plain\\r\\n\\r\\nPACKAGE ENGINE A\\n" }
PKG

# --- the site: its docroot, its own engine copy at "version B", its lib ---------
make_path( "$doc/lazysite", "$dom/cgi-bin/lazysite-processor" );
spew( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
spew( "$doc/index.md",               "---\ntitle: Home\n---\nSITE ENGINE B BODY\n" );
copy( "$root/lazysite-processor.pl", "$dom/cgi-bin/lazysite-processor.pl" ) or die "copy: $!";
opendir my $pd, "$root/lazysite-processor" or die $!;
for my $f ( grep { /\.pm\z/ } readdir $pd ) {
    copy( "$root/lazysite-processor/$f", "$dom/cgi-bin/lazysite-processor/$f" ) or die "copy $f: $!";
}
closedir $pd;
symlink( "$root/lib", "$dom/lib" ) or die "symlink lib: $!";

# Start the launcher from the package tree, as the unit does, ask one page, stop.
sub pool_request {
    my ($tag) = @_;
    my $sock = "$base/$tag.sock";
    my $log  = "$base/$tag.log";
    my $pid  = fork() // die "fork: $!";
    if ( !$pid ) {
        %ENV = ( env_passthrough(), PATH => $ENV{PATH}, DOCROOT => $doc, USER => $me,
            WORKERS => 0, SOCKET => $sock );
        open STDERR, '>', $log or die $!;
        exec $^X, "$pkg/tools/lazysite-pool.pl", '--instance', "t-$tag";
        die "exec: $!";
    }
    my $res;
    for ( 1 .. 100 ) {
        $res = eval {
            fcgi_request( $sock,
                { REQUEST_METHOD => 'GET', REDIRECT_URL => '/', REMOTE_ADDR => '198.51.100.1',
                    DOCUMENT_ROOT => $doc } );
        };
        last if $res;
        select( undef, undef, undef, 0.1 );
    }
    kill 'TERM', $pid;
    waitpid $pid, 0;
    my $err = do { open my $fh, '<', $log or die $!; local $/; <$fh> } // '';
    return ( $res ? $res->{stdout} : '', $err );
}

my $pools = "$base/pools";
make_path($pools);
spew( "$pools/t.conf", "DOCROOT=$doc\nUSER=$me\n" );

sub check {
    local $ENV{LAZYSITE_POOLS_DIR} = $pools;
    return run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $doc );
}

# --- the site's tree is in place: the site's engine renders ---------------------
my ( $out, $err ) = pool_request('own');
like( $out, qr/Status: 200 OK/,      'the pool answered the page' ) or diag($err);
like( $out, qr/SITE ENGINE B BODY/,  "and rendered it with the site's own engine" );
unlike( $out, qr/PACKAGE ENGINE A/,  "not the package's" );
ok( !-e $mark,                       "the package's engine never ran" );
like( check(), qr/pool engine: the site's own/, 'lazysite check says the pool runs the site\'s own engine' );

# --- the site's processor is gone: 503, and still never the package's -----------
unlink "$dom/cgi-bin/lazysite-processor.pl" or die $!;
( $out, $err ) = pool_request('gone');
like( $out, qr/Status: 503/,        'a site whose engine is missing is refused with 503' );
unlike( $out, qr/PACKAGE ENGINE A/, "the package's engine is not used in its place" );
ok( !-e $mark,                      "and never ran" );
like( $err, qr{\Q$dom\E/cgi-bin/lazysite-processor\.pl}, 'the log names the missing file' );
my $chk = check();
like( $chk, qr/pool engine: the site's own engine is missing: \Q$dom\E\/cgi-bin\/lazysite-processor\.pl/,
    'lazysite check names the fault' );
like( $chk, qr/lazysite reinstall --docroot/, 'and the remedy' );

done_testing();
