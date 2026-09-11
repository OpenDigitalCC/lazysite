#!/usr/bin/perl
# N13-43: every Hestia template says which revision it is, and a changed
# template says so by changing it.
#
# A template change reaches a site only when Hestia rebuilds that site's vhost,
# and nothing said which sites had been: SM797's re-render was an instruction in
# UPGRADE.md that an operator had to apply by memory. The rollout table now
# reports VHOST per site - current, or rebuild - by comparing the revision in
# the vhost Hestia rendered with the revision of the template this release ships
# (`# lazysite-template-rev: X`, carried through Hestia's substitution as a
# comment). That comparison is only as good as the revision:
#
#   - every Hestia template carries it, and all carry the SAME value, because a
#     site renders from two of them (web and proxy) and one release is one
#     revision;
#   - when any template's content changed since the last release tag, the
#     revision is not the one that tag carried - or every site reads "current"
#     while rendering the old rules, which is the report being wrong in the
#     direction that costs something.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my @files = sort map { s{\A\Q$root/\E}{}r }
    ( glob("$root/installers/hestia/*.tpl"), glob("$root/installers/hestia/*.stpl") );
cmp_ok( scalar @files, '>=', 10, 'the canary: found the Hestia templates' );

sub rev_of {
    my ($text) = @_;
    return ( $text // '' ) =~ /^[ \t]*#[ \t]*lazysite-template-rev:[ \t]*(\S+)/m ? $1 : undef;
}
sub without_rev { my ($t) = @_; $t =~ s/^[ \t]*#[ \t]*lazysite-template-rev:.*\n//mg; return $t }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

my %rev     = map  { $_ => rev_of( slurp("$root/$_") ) } @files;
my @missing = grep { !defined $rev{$_} } @files;
is_deeply( \@missing, [], 'every Hestia template carries its revision' );
my %values = map { $_ => 1 } grep { defined } values %rev;
is( scalar keys %values, 1, 'and they all carry the same one' ) or diag explain \%rev;
my ($current) = keys %values;

SKIP: {
    skip 'no git here (a release tarball)', 1 unless -e "$root/.git";
    my $tag = `git -C \Q$root\E describe --tags --abbrev=0 2>/dev/null`;
    chomp $tag;
    skip 'no release tag to compare with', 1 unless length $tag;

    my ( @changed, $tag_rev );
    for my $rel (@files) {
        my $then = `git -C \Q$root\E show \Q$tag:$rel\E 2>/dev/null`;
        $tag_rev //= rev_of($then);
        push @changed, $rel if without_rev($then) ne without_rev( slurp("$root/$rel") );
    }
    if (@changed) {
        isnt( $current // '', $tag_rev // '',
            "templates changed since $tag, and the revision changed with them" )
            or diag( "Changed: @changed. Bump `# lazysite-template-rev:` in every Hestia template, "
                . 'or the rollout reports every site current while it renders the old rules.' );
    }
    else {
        pass("no template changed since $tag");
    }
}

done_testing();
