#!/usr/bin/perl
# SM1035 (found by SM1012's characterisation of render_content, 2026-10-12):
# when the TT compile directory cannot be made, the umask the renderer widened
# for it (_cache_umask, 0002) was left in place.
#
# render.pm built the content pass's Template object as
#
#     my $tt = Template->new(...) or do { umask $old_umask; die ... };
#
# and Template->new does not return false there: Template::Provider's mkdir DIES
# inside it, so the `or do` never ran and the umask stayed 0002. Under CGI the
# process ends with the request; a persistent worker - or the next render in
# the same process, as here - writes what comes next group-writable. The
# registries' engine (registries.pm) had the same shape, with an unguarded
# make_path ahead of it.
#
# Each now restores the umask on every path and still fails as it did: the
# same die, the same message.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

no warnings 'once';    # the processor's globals are named here once each

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $docroot = site_tempdir();
setup_minimal_site($docroot);
make_path("$docroot/lazysite/templates/registries");
spit( "$docroot/lazysite/templates/registries/sitemap.xml.tt", "[% FOREACH p IN pages %][% p.url %]\n[% END %]" );
spit( "$docroot/blocker", "a file where a directory is wanted\n" );
load_processor($docroot);

# A compile directory below a regular file: neither make_path nor Template's
# Provider can create it.
my $UNMAKEABLE = "$docroot/blocker/tt";

# Runs $code under a known umask and returns ( died?, message, umask left ).
sub under_umask {
    my ($code) = @_;
    my $before = umask 027;
    my $ok     = eval { $code->(); 1 };
    my $err    = $@;
    my $after  = umask $before;
    return ( $ok ? 0 : 1, $err, sprintf( '%04o', $after ) );
}

subtest 'render_content: a compile directory that cannot be made' => sub {
    local $main::TT_COMPILE_DIR = $UNMAKEABLE;
    my ( $died, $err, $left ) = under_umask( sub { main::render_content( { title => 'A page' }, '[% site_name %]' ) } );
    ok( $died, 'it still fails, as before' );
    like( $err, qr/mkdir \Q$docroot\E\/blocker: File exists/, '...with the same message' );
    is( $left, '0027', 'and leaves the umask it found, not 0002' );
};

subtest 'render_content: the control' => sub {
    my ( $died, $err, $left ) = under_umask( sub { main::render_content( { title => 'A page' }, '[% site_name %]' ) } );
    ok( !$died, 'a render with a compile directory succeeds' ) or diag($err);
    is( $left, '0027', 'and leaves the umask it found' );
};

subtest 'update_registries: a compile directory that cannot be made' => sub {
    local $main::TT_COMPILE_DIR = $UNMAKEABLE;
    # Loading the processor rendered once and wrote the registry; remove it so
    # it is stale and the regeneration runs.
    my $cached = main::_registry_cache_path( $docroot, 'sitemap.xml' );
    unlink $cached;
    ok( !-e $cached, 'the registry is due to be regenerated' );
    my ( $died, $err, $left ) = under_umask( sub { main::update_registries() } );
    ok( $died, 'it still fails, as before' );
    like( $err, qr/blocker/, '...naming the path it could not make' );
    is( $left, '0027', 'and leaves the umask it found, not 0002' );
};

done_testing();
