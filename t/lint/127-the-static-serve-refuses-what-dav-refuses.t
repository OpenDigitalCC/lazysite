#!/usr/bin/perl
# SM797: a type too dangerous to accept as an upload is too dangerous to hand out.
#
# Two lists answer two questions. @DANGEROUS_EXT (Manager::Common, and its copy
# in lazysite-dav.pl) refuses executable and server-config types on WRITE.
# %STATIC_DENY in the processor refuses disclosure-prone types on the anonymous
# static SERVE. They are not the same list and must not become one - the serve
# list also refuses backups, keys, and the engine's own page sources, none of
# which is dangerous to upload. But one relation between them always holds: the
# serve list contains every type the write list refuses.
#
# Before SM797 the anonymous surface refused nothing while the authenticated one
# refused these. This pins the relation so a type added to the write list is
# refused on the serve as well, by the next gate rather than the next review.
#
# Read from source because the processor is module-free (ADR 0001) and its hash
# is a lexical; the lists are literal qw() blocks, so reading them is exact.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { my ($p) = @_; open my $fh, '<:utf8', $p or die "$p: $!"; local $/; return <$fh> }

sub qw_after {
    my ( $src, $anchor, $what ) = @_;
    my ($body) = $src =~ /\Q$anchor\E\s*(?:=\s*)?(?:map\s*\{[^}]*\}\s*(?:grep\s*\{[^}]*\}\s*)?)?qw\(([^)]*)\)/s;
    ok( defined $body, "found the $what list" ) or return ();
    return grep { length } split /\s+/, $body;
}

my @serve = qw_after( slurp("$root/lazysite-processor.pl"), 'BEGIN { %STATIC_DENY', 'static-serve deny' );
my %serve = map { $_ => 1 } @serve;
cmp_ok( scalar @serve, '>', 10, 'the serve list is not empty - a denylist that refuses nothing passes every subset check' );

for my $src ( [ 'lib/Lazysite/Manager/Common.pm', 'our @DANGEROUS_EXT' ],
              [ 'lazysite-dav.pl',                'our @DANGEROUS_EXT' ] ) {
    my ( $file, $anchor ) = @$src;
    my @write = qw_after( slurp("$root/$file"), $anchor, "$file write-refusal" );
    my @missing = grep { !$serve{$_} } @write;
    is_deeply( \@missing, [], "every type $file refuses to accept, the static serve refuses to hand out" )
        or diag "served anonymously but refused on upload: @missing";
}

done_testing();
