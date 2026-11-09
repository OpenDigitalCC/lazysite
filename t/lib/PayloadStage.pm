package PayloadStage;

# SM1369 X7 / SM1361 (n788): A PAYLOAD STAGE, the shape a package or an image
# carries: install.pl, VERSION, the release manifest built from this checkout,
# and every file the manifest lists, copied from the checkout. `without` leaves
# out every file the manifest marks as an extension's (`extension: <id>`),
# which is a host where that extension's package is not installed.
#
# The manifest is the checkout's own, built under repo_manifest_guard by the
# caller, so the stage installs exactly this tree.

use strict;
use warnings;
use Exporter 'import';
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Find ();
use Digest::SHA ();
use JSON::PP ();
use TestHelper qw(repo_root);

our @EXPORT_OK = qw(make_stage make_writable tree_digest run_install);

sub make_stage {
    my ( $manifest_path, %o ) = @_;
    my $root  = repo_root();
    my $stage = tempdir( 'lazysite-stage-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $m     = do {
        open my $fh, '<:raw', $manifest_path or die "$manifest_path: $!";
        local $/;
        JSON::PP::decode_json(<$fh>);
    };
    my %skip = map { $_ => 1 } @{ $o{without} || [] };
    for my $e ( @{ $m->{files} } ) {
        next if defined $e->{extension} && $skip{ $e->{extension} };
        my $to = "$stage/$e->{path}";
        make_path( dirname($to) );
        copy( "$root/$e->{path}", $to ) or die "copy $e->{path}: $!";
        chmod( ( stat "$root/$e->{path}" )[2] & 07777, $to );
    }
    for my $f (qw(install.pl VERSION)) {
        copy( "$root/$f", "$stage/$f" ) or die "copy $f: $!";
    }
    copy( $manifest_path, "$stage/release-manifest.json" ) or die "copy manifest: $!";
    if ( $o{image} ) {
        # As the image has it (installers/docker/Dockerfile): the CGIs and the
        # extension scripts executable, the endpoint links made, and the whole
        # tree read-only. make_writable undoes it for the tempdir's cleanup.
        chmod 0755, glob("$stage/lazysite-*.pl"), glob("$stage/extensions/*.pl");
        open my $mk, '>', "$stage/SHARED-ENGINE" or die "marker: $!";
        print {$mk} "this engine is shared and read-only\n";
        close $mk;
        for my $e (@{ $o{links} || [] }) {
            symlink "extensions/$e.pl", "$stage/$e.pl" or die "link $e: $!";
        }
        File::Find::find( { no_chdir => 1, wanted => sub {
            return if -l $_;
            chmod( ( ( stat $_ )[2] & 07777 ) & ~0222, $_ );
        } }, $stage );
    }
    return $stage;
}

sub make_writable {
    my ($dir) = @_;
    File::Find::find( { no_chdir => 1, wanted => sub {
        return if -l $_;
        chmod( ( ( stat $_ )[2] & 07777 ) | 0200, $_ );
    } }, $dir );
    return;
}

# A digest of everything under each directory: path, type, mode and content.
sub tree_digest {
    my (@dirs) = @_;
    my $sha = Digest::SHA->new(256);
    for my $d (@dirs) {
        my @p;
        File::Find::find( { no_chdir => 1, wanted => sub { push @p, $_ } }, $d );
        for my $p ( sort @p ) {
            my @st = lstat $p;
            $sha->add( "$p\0" . ( $st[2] // 0 ) . "\0" );
            $sha->addfile($p) if -f $p && !-l $p;
            $sha->add( readlink $p ) if -l $p;
        }
    }
    return $sha->hexdigest;
}

# install.pl from $stage, as a child: ( exit code, output ). The health check
# is left to the caller unless $HEALTH is set, when install.pl runs it and its
# verdict is the exit code.
our $HEALTH = 0;

sub run_install {
    my ( $stage, @args ) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my $g   = getgrgid( $) + 0 ) // ( $) + 0 );
    my @cmd = ( $^X, "$stage/install.pl", @args, ( $HEALTH ? () : '--health-check-by-caller' ),
        '--serving-group', $g );
    my $cmd = join ' ', map {quotemeta} @cmd;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

1;
