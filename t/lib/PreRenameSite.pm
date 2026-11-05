package PreRenameSite;

# SM1142: A SITE AS THE LAST RELEASE BEFORE THE RENAME LEFT IT, for the tests
# of the upgrade that moves it to extensions/ (install.pl, extensions-rename).
#
# Built the honest way: the CURRENT installer provisions a site, and then the
# tree is turned into the shape 0.16.3's installer wrote - its extension copies
# in the old directory beside the docroot, the install state recording them
# there, the two cgi-bin links pointing into it, and lazysite.conf listing the
# enabled ones under the old header as old-directory keys. That is every place
# the old name lived on disk; nothing else of the site differs, so whatever the
# upgrade then changes, it changed because of the rename.
#
# install() runs install.pl as production does (no PERL5LIB - SM767) and as
# t/tools/03 does (the test user's group stands in for the web server's).

use strict;
use warnings;
use Exporter 'import';
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   ();
use TestHelper qw(repo_root);

our @EXPORT_OK = qw(new_site install make_pre_rename slurp spit);

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub spit {
    my ( $p, $s ) = @_;
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $s;
    close $fh;
    return;
}

# ( docroot, cgibin, root ): the docroot and cgi-bin as siblings under a root,
# which is where install.pl puts extensions/, tools/ and lib/.
sub new_site {
    my $dir = tempdir( 'lazysite-rename-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path( "$dir/site", "$dir/cgi-bin" );
    return ( "$dir/site", "$dir/cgi-bin", $dir );
}

sub install {
    my ( $docroot, $cgibin, $mode ) = @_;
    local $ENV{PERL5LIB};
    delete $ENV{PERL5LIB};
    my @cmd = ( $^X, repo_root() . '/install.pl', '--docroot', $docroot, '--cgibin', $cgibin,
        '--mode', $mode, ( $mode eq 'provision' ? '--starter' : () ), '--health-check-by-caller', '--serving-group', ( getgrgid( $) + 0 ) // ( $) + 0 ) ) );
    my $cmd = join ' ', map { quotemeta } @cmd;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

# old-name: begin (SM1142, the fixture builds the layout the rename converts)
our $OLD = 'plugins';

# Turn a provisioned site into the pre-rename layout. @enabled are file names
# to list (as old-directory keys) in addition to what the conf already lists.
sub make_pre_rename {
    my ( $docroot, $cgibin, $root, @enabled ) = @_;
    rename "$root/extensions", "$root/$OLD" or die "move extensions/: $!";

    my $sp    = "$docroot/lazysite/.install-state.json";
    my $state = JSON::PP::decode_json( slurp($sp) );
    my %files;
    for my $k ( keys %{ $state->{files} } ) {
        ( my $o = $k ) =~ s{/extensions/}{/$OLD/};
        $files{$o} = $state->{files}{$k};
    }
    $state->{files}   = \%files;
    $state->{version} = '0.16.3';
    $state->{once}    = [ grep { $_ ne 'extensions-rename' } @{ $state->{once} || [] } ];
    spit( $sp, JSON::PP->new->canonical->pretty->encode($state) );

    my $conf = "$docroot/lazysite/lazysite.conf";
    my $c    = slurp($conf);
    # An upgrade to a build of another channel is refused by a stable site.
    $c =~ s/^update_channel:.*\n//mg;
    $c .= "update_channel: all\n";
    $c =~ s/^extensions:\s*$/$OLD:/m or $c .= "$OLD:\n";
    $c =~ s{^(\s+-\s+)extensions/}{$1$OLD/}mg;
    my $add = join '', map { "  - $OLD/$_\n" } grep { $c !~ m{-\s+\Q$OLD/$_\E\s*$}m } @enabled;
    $c =~ s/^(\Q$OLD\E:\n(?:\s+-\s+.*\n)*)/$1$add/m;
    spit( $conf, $c );

    opendir my $ch, $cgibin or die $!;
    for my $e ( grep { -l "$cgibin/$_" } readdir $ch ) {
        my $t = readlink "$cgibin/$e";
        next unless $t =~ m{/extensions/([^/]+)\z};
        unlink "$cgibin/$e";
        symlink "$root/$OLD/$1", "$cgibin/$e" or die $!;
    }
    closedir $ch;
    return;
}
# old-name: end

1;
