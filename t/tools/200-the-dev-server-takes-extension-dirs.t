#!/usr/bin/perl
# SM1222 (ruled 2026-10-20, "an extensions dir, yes, that allows multiple"):
# tools/lazysite-server.pl --extensions DIR, repeatable. The OOM Lab (L-6) could
# not run extensions from the tree: they were found only in plugins/ beside the
# docroot. Held here:
#   - two directories both load, the first named wins a shared name, and the
#     startup lines say so
#   - a symlinked directory is refused at start, a symlinked script is skipped
#   - without the dev server's variables the lookup is the installed engine's,
#     and a hand-set list of directories alone widens nothing
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir reap_child);

my $root = repo_root();
require "$root/tools/lazysite-server.pl";
require Lazysite::Manager::Plugins;
no warnings "once";

my $site = site_tempdir();    # <t>/site/public_html
( my $base = $site ) =~ s{/public_html\z}{};
my $ext = "$base/ext";
my ( $d1, $d2 ) = ( "$ext/one", "$ext/two" );
make_path( $d1, $d2, "$base/plugins", "$ext/elsewhere" );

sub put {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $body;
    close $fh;
    chmod 0755, $path;
}
put( "$d1/alpha.pl",    "#!/usr/bin/perl\nprint 'one';\n" );
put( "$d1/shared.pl",   "#!/usr/bin/perl\nprint 'one';\n" );
put( "$d2/beta.pl",     "#!/usr/bin/perl\nprint 'two';\n" );
put( "$d2/shared.pl",   "#!/usr/bin/perl\nprint 'two';\n" );
put( "$ext/elsewhere/hidden.pl", "#!/usr/bin/perl\n" );
symlink( "$ext/elsewhere/hidden.pl", "$d2/linked.pl" ) or die $!;
put( "$base/plugins/native.pl", "#!/usr/bin/perl\n" );
symlink( $d1, "$ext/linkdir" ) or die $!;

sub registry {
    my (%env) = @_;
    local @ENV{qw(LAZYSITE_DEV_SERVER LAZYSITE_EXTENSION_DIRS)};
    delete @ENV{qw(LAZYSITE_DEV_SERVER LAZYSITE_EXTENSION_DIRS)};
    @ENV{ keys %env } = values %env;
    local $Lazysite::Manager::Plugins::DOCROOT = $site;
    return Lazysite::Manager::Plugins::plugin_registry();
}

subtest 'two directories both load, and the first named wins a shared name' => sub {
    my $r = registry( LAZYSITE_DEV_SERVER => 1, LAZYSITE_EXTENSION_DIRS => "$d1:$d2" );
    is( $r->{'plugins/alpha.pl'}, "$d1/alpha.pl", 'a script of the first directory loads' );
    is( $r->{'plugins/beta.pl'},  "$d2/beta.pl",  'a script of the second directory loads' );
    is( $r->{'plugins/shared.pl'}, "$d1/shared.pl", 'a name in both is the first directory\'s' );
    is( $r->{'plugins/native.pl'}, "$base/plugins/native.pl", 'the docroot\'s own plugins/ still loads, searched last' );
    my $swapped = registry( LAZYSITE_DEV_SERVER => 1, LAZYSITE_EXTENSION_DIRS => "$d2:$d1" );
    is( $swapped->{'plugins/shared.pl'}, "$d2/shared.pl", 'and the order given decides it' );
};

subtest 'a symlink is still refused' => sub {
    my $r = registry( LAZYSITE_DEV_SERVER => 1, LAZYSITE_EXTENSION_DIRS => "$d1:$d2" );
    ok( !exists $r->{'plugins/linked.pl'}, 'a symlinked script in a directory is not registered' );
    my $l = registry( LAZYSITE_DEV_SERVER => 1, LAZYSITE_EXTENSION_DIRS => "$ext/linkdir" );
    ok( !exists $l->{'plugins/alpha.pl'}, 'a symlinked directory in the list loads nothing' );
    my ( $abs, $err ) = main::check_extension_dir("$ext/linkdir");
    ok( !defined $abs && $err =~ /symlink/, 'and the server refuses it at start' ) or diag( $err // '' );
    ( $abs, $err ) = main::check_extension_dir("$ext/none");
    ok( !defined $abs && $err =~ /not found/, 'a missing directory is refused' );
    ( $abs, $err ) = main::check_extension_dir("$d1/");
    is( $abs, $d1, 'a real directory is accepted, trailing slash trimmed' );
};

subtest 'the installed engine\'s lookup is unchanged' => sub {
    my $none = registry();
    ok( !grep( { m{^plugins/(?:alpha|beta|shared)\.pl\z} } keys %{$none} ), 'no variables: no extra directory is read' );
    is( $none->{'plugins/native.pl'}, "$base/plugins/native.pl", 'and plugins/ beside the docroot is the one lookup' );
    my $listed = registry( LAZYSITE_EXTENSION_DIRS => $d1 );
    ok( !exists $listed->{'plugins/alpha.pl'}, 'a directory list without the dev server\'s flag widens nothing' );
    is_deeply( [ do { local $ENV{LAZYSITE_EXTENSION_DIRS} = $d1; Lazysite::Paths::dev_extension_dirs() } ], [], 'dev_extension_dirs is empty without the flag' );
    require Lazysite::Handlers;
    local $Lazysite::Handlers::DOCROOT = $site;
    local @ENV{qw(LAZYSITE_DEV_SERVER LAZYSITE_EXTENSION_DIRS)};
    delete @ENV{qw(LAZYSITE_DEV_SERVER LAZYSITE_EXTENSION_DIRS)};
    ok( !defined Lazysite::Handlers::find_script('alpha.pl'), 'the script finder does not look in them either' );
    @ENV{qw(LAZYSITE_DEV_SERVER LAZYSITE_EXTENSION_DIRS)} = ( 1, $d1 );
    is( Lazysite::Handlers::find_script('alpha.pl'), "$d1/alpha.pl", 'under the dev server it does' );
};

subtest 'the dev server routes the form handler to a directory that holds it' => sub {
    put( "$d1/form-handler.pl", "#!/usr/bin/perl\n" );
    local @ENV{qw(LAZYSITE_DEV_SERVER LAZYSITE_EXTENSION_DIRS)} = ( 1, $d1 );
    my @r = main::cgi_target_for( '/cgi-bin/form-handler.pl', "$root/tools", "$root/lazysite-processor.pl" );
    is( $r[0], "$d1/form-handler.pl", 'the --extensions copy is the target' );
    ok( $r[2], 'run direct, as an installed one' );
};

# The server itself: start it, read its startup lines, stop it.
# It drives the child itself (SM1245): the read is under an alarm, the wait bounded.
sub start_lines {
    my (@args) = @_;
    my $err = gensym;
    my $pid = open3( my $in, my $out, $err, $^X, "$root/tools/lazysite-server.pl",
        '--no-seed', '--port', 0, '--docroot', $site, @args );
    close $in;
    my ( $text, $stop ) = ( '', 0 );
    my $fh = $out;
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 20;
    eval {
        while ( my $l = <$fh> ) {
            $text .= $l;
            last if $l =~ /Ctrl\+C/;
        }
    };
    alarm 0;
    kill 'TERM', $pid;
    my $errtext = do { local $/; local $SIG{ALRM} = sub { }; alarm 2; my $e = eval { <$err> }; alarm 0; $e // '' };
    reap_child( $pid, label => 'lazysite-server.pl' );
    return ( $text, $errtext, $? >> 8 );
}

subtest 'the startup lines name each directory, a skipped symlink and the winner' => sub {
    my ( $out, undef, undef ) = start_lines( '--extensions', $d1, '--extensions', $d2 );
    like( $out, qr/extensions: \Q$d1\E: alpha\.pl, .*shared\.pl/, 'the first directory is listed' );
    like( $out, qr/extensions: \Q$d2\E: beta\.pl, shared\.pl/,  'the second is listed' );
    like( $out, qr/extensions: \Q$d2\E: skipped, a symlink: linked\.pl/, 'a symlinked script is named as skipped' );
    like( $out, qr/extensions: shared\.pl is in \Q$d1\E and \Q$d2\E: \Q$d1\E wins/, 'a shared name says which wins' );
};

subtest 'the server will not start on a symlinked directory' => sub {
    my ( undef, $err, $code ) = start_lines( '--extensions', "$ext/linkdir" );
    is( $code, 1, 'it exits 1' );
    like( $err, qr/--extensions .*linkdir: is a symlink/, 'and says why' );
};

done_testing;
