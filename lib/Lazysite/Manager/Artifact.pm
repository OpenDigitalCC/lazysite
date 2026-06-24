package Lazysite::Manager::Artifact;

# SM079: layout/theme artifact manifest + digest, used for change-detection on
# activation (the base-manifest conflict check). Context: $LAZYSITE_DIR.

use strict;
use warnings;
use JSON::PP ();
use File::Find ();
use Digest::SHA qw(sha256_hex);
use Exporter 'import';

our @EXPORT_OK = qw(_artifact_dir _compute_manifest _artifact_digest);

our $LAZYSITE_DIR;

# === moved from Manager::Themes (SM079 polish) ===

sub _artifact_dir {
    my ($p) = @_;
    my $layout = $p->{layout} // '';
    my $theme  = $p->{theme}  // '';
    return { ok => 0, error => 'invalid or missing layout' }
        unless $layout =~ /^[A-Za-z0-9_-]+$/;
    if ( length $theme ) {
        return { ok => 0, error => 'invalid theme' }
            unless $theme =~ /^[A-Za-z0-9_-]+$/;
        return { ok => 1, layout => $layout, theme => $theme,
                 dir => "$LAZYSITE_DIR/layouts/$layout/themes/$theme" };
    }
    return { ok => 1, layout => $layout, theme => '',
             dir => "$LAZYSITE_DIR/layouts/$layout" };
}

sub _compute_manifest {
    my ($dir) = @_;
    my %m;
    return \%m unless -d $dir;
    File::Find::find( { no_chdir => 1, wanted => sub {
        return unless -f $_;
        ( my $rel = $_ ) =~ s{^\Q$dir\E/}{};
        open my $fh, '<:raw', $_ or return;
        my $sha = Digest::SHA->new(256);
        $sha->addfile($fh);
        close $fh;
        $m{$rel} = { sha256 => $sha->hexdigest, size => ( -s $_ ) + 0 };
    } }, $dir );
    return \%m;
}

sub _artifact_digest {
    my ($dir) = @_;
    return sha256_hex( JSON::PP->new->canonical->encode( _compute_manifest($dir) ) );
}



1;
