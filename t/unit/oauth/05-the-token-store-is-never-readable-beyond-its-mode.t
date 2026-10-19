#!/usr/bin/perl
# SM1183: Lazysite::Auth::OAuth::save_store wrote the tokens into a file made under
# the umask (0664 in the CGI), THEN chmod'ed it 0660. The window is latent while
# lazysite/auth/ is 02770 (no other-traverse), but a directory mode can drift, and
# the module header claimed 0600 while the code (rightly, SM760: the CGI and the
# operator tool share one write plane) writes 0660. The contract is 0660 and
# never wider, from the first byte. Every secret writer now creates its temp with
# its final mode through Lazysite::Util::write_private_atomic.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_cmd);

# Record what the filesystem looks like at the moments that matter, without
# changing what they do. Installed before any module compiles.
our ( @CHMODS, @RENAMES );
BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::chmod = sub {
        my ( $mode, @files ) = @_;
        for my $f (@files) {
            next if ref $f;
            my @s = stat $f;
            push @CHMODS, { path => $f, size => ( @s ? $s[7] : -1 ), before => ( @s ? $s[2] & 07777 : -1 ), to => $mode };
        }
        return CORE::chmod( $mode, @files );
    };
    *CORE::GLOBAL::rename = sub {
        my @s = stat $_[0];
        push @RENAMES, { from => $_[0], to => $_[1], mode => ( @s ? $s[2] & 07777 : -1 ) };
        return CORE::rename( $_[0], $_[1] );
    };
}

my $root;
BEGIN { $root = repo_root() }    # `use lib` below runs at compile time
use lib "$root/lib";
require Lazysite::Auth::OAuth;
require Lazysite::Util;

my $d = site_tempdir();
make_path("$d/lazysite/auth");
{
    no warnings 'once';    # the module is require'd above, so this is its only mention here
    $Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";
}
my $store = "$d/lazysite/auth/oauth.json";

sub mode_of { return ( stat $_[0] )[2] & 07777 }

for my $um ( 0000, 0002, 0022 ) {
    umask $um;
    unlink $store;
    @CHMODS = @RENAMES = ();
    my $c = Lazysite::Auth::OAuth::register_client( { redirect_uris => ['https://c.example/cb'], client_name => 'x' } );
    my $label = sprintf 'umask %04o', $um;
    ok( -f $store, "$label: the store was written" );
    is( sprintf( '%04o', mode_of($store) ), '0660', "$label: a new store is 0660" );
    my @late = grep { $_->{path} =~ /\.tmp\./ && $_->{size} > 0 } @CHMODS;
    is( scalar @late, 0, "$label: the tokens are never in a file that is chmod'ed afterwards (no window)" )
        or diag explain \@late;
    my @wide = grep { $_->{mode} & ~0660 } @RENAMES;
    is( scalar @wide, 0, "$label: the temp is no wider than 0660 when it is renamed into place" )
        or diag explain \@wide;
}

# An existing 0660 store stays 0660 on the next save, and a store left WIDER
# (0664, a umask or an operator's chmod) is narrowed by it.
umask 0002;
chmod 0664, $store;
Lazysite::Auth::OAuth::register_client( { redirect_uris => ['https://c.example/cb'], client_name => 'y' } );
is( sprintf( '%04o', mode_of($store) ), '0660', 'a 0664 store is 0660 after the next save' );

# --- the helper, for any mode ----------------------------------------------
for my $m ( 0600, 0660 ) {
    umask 0;
    @RENAMES = ();
    my $p = "$d/h-" . sprintf( '%04o', $m );
    my ( $ok, $why ) = Lazysite::Util::write_private_atomic( $p, "secret\n", $m );
    ok( $ok, sprintf( 'write_private_atomic %04o succeeds', $m ) ) or diag $why;
    is( sprintf( '%04o', mode_of($p) ), sprintf( '%04o', $m ), sprintf( '%04o: final mode', $m ) );
    is( scalar( grep { $_->{mode} != $m } @RENAMES ), 0, sprintf( '%04o: the temp had its final mode at the rename, umask 0', $m ) );
    my @leftover = glob("$p.tmp.*");
    is( scalar @leftover, 0, 'no temp left behind' );
}
{
    my ( $ok, $why ) = Lazysite::Util::write_private_atomic( "$d/no-such-dir/x", 'a', 0600 );
    ok( !$ok && length $why, 'a failure says why and returns false' );
}

# --- the class: no secret writer still opens a plain file and chmods it -------
# These modules each wrote a secret as open '>' + chmod; each now goes through
# the helper. A new `open ... '>' ... $tmp` followed by `chmod ... $tmp` in them
# is the shape that came back once already.
for my $rel (
    'lib/Lazysite/Auth/OAuth.pm',      'lib/Lazysite/Manager/Users.pm',
    'lib/Lazysite/Manager/Sessions.pm', 'lib/Lazysite/Auth/Session.pm',
    'lib/Lazysite/Odoo/SiteSignin.pm', 'lib/Lazysite/Manager/AccountImport.pm',
    'lib/Lazysite/Manager/Preview.pm',  'lib/Lazysite/Manager/Plugins.pm',
    ) {
    open my $fh, '<', "$root/$rel" or die "$rel: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    like( $src, qr/write_private_atomic/, "$rel writes its secret through write_private_atomic" );
    unlike( $src, qr{open\s+my\s+\$\w+,\s*'>[:\w]*',\s*\$(?:tmp|path|mpath)\b},
        "$rel does not open a secret with the umask's mode and chmod it afterwards" )
        unless $rel =~ /Plugins/;    # other, non-secret writes live there
}
# --- the header says what the code does ------------------------------------
{
    open my $fh, '<', "$root/lib/Lazysite/Auth/OAuth.pm" or die $!;
    my $head = join '', map { scalar <$fh> } 1 .. 20;
    close $fh;
    unlike( $head, qr/tree, 0600\b/, 'the OAuth header no longer claims the store is 0600' );
    like( $head, qr/0660/, 'the OAuth header says 0660' );
    like( $head, qr/SM760/, 'and names why' );
}

# --- lazysite check: a 0660 store passes, a world-readable one is named --------
{
    my $base = site_tempdir();
    my $doc  = "$base/public_html";
    make_path( "$doc/lazysite/auth", "$base/cgi-bin" );
    chmod 02770, "$doc/lazysite/auth";
    open my $o, '>', "$doc/lazysite/auth/oauth.json" or die $!;
    print {$o} '{}';
    close $o;
    my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];
    my $run = sub {
        return run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $doc, '--cgibin', "$base/cgi-bin", '--group', $gname );
    };
    chmod 0660, "$doc/lazysite/auth/oauth.json";
    like( $run->(), qr{auth/oauth\.json readable by the CGI, not world-accessible}, 'check passes a 0660 OAuth store' );
    chmod 0664, "$doc/lazysite/auth/oauth.json";
    like( $run->(), qr{auth/oauth\.json is world-accessible \(0664\)}, 'check names a world-readable OAuth store' );
}

done_testing;
