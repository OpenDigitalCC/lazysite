#!/usr/bin/perl
# SM1068: the processor decodes acls.json in ONE place, and the "governed"
# questions ask by audience.
#
# Before, four readers in lazysite-processor/acl.pm each opened and decoded the
# store themselves, and _acl_is_draft did it on every call with no memo at all,
# so a registry rebuild decoded the store once per page. The next reader to be
# added would copy whichever neighbour it was written beside. This holds the
# decode to _acl_map, which keeps the process-wide copy keyed on the file's
# identity, and holds _acl_governed and _acl_governing_key to the 'see' mode
# the ruling defines ("Read/draft only", 2026-10-13): a read list or a draft.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";
my @files = ( "$root/lazysite-processor.pl", glob("$root/lazysite-processor/*.pm") );
cmp_ok( scalar @files, '>', 10, 'the processor and its parts are found' );

my %subs;    # name => body, across the processor and its parts
for my $f (@files) {
    open my $fh, '<', $f or die "$f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    # A sub ends at the brace indented as its `sub` line is.
    while ( $src =~ /^([ ]*)sub (\w+) \{\n(.*?)^\1\}\n/msg ) {
        $subs{$2} = $3;
    }
}
ok( exists $subs{_acl_map}, 'the shared reader exists' ) or BAIL_OUT('_acl_map not found - rename this lint with it');

my @decoders = sort grep {
    my $b = $subs{$_};
    $b =~ /acls\.json/ && $b =~ /decode_json/
} keys %subs;
is_deeply( \@decoders, ['_acl_map'], 'only _acl_map reads and decodes acls.json' )
    or diag( "A reader of the rule store goes through _acl_map, so a request decodes it at most\n"
        . "once and a persistent worker once per change. Found: @decoders" );

for my $s (qw(_acl_allows_read _acl_is_draft _acl_governed _acl_governing_key)) {
    like( $subs{$s} // '', qr/_acl_map\(/, "$s reads the store through _acl_map" );
}

like( $subs{_acl_map}, qr/\@st\[\s*9,\s*7,\s*1,\s*10\s*\]/,
    'the kept copy is keyed on mtime, size, inode and ctime' );
like( $subs{_acl_map}, qr/\$st\[10\] < time\(\) - 1/,
    'and kept only once the file is more than a second old' );

for my $s (qw(_acl_governed _acl_governing_key)) {
    like( $subs{$s} // '', qr/_acl_entry_for\( \$map, \$rel, 'see' \)/,
        "$s asks by audience - a read list or a draft (SM1068)" );
    unlike( $subs{$s} // '', qr/_acl_entry_for\( \$map, \$rel \)/,
        "$s never asks with no mode, which counts a write-only rule" );
}

done_testing();
