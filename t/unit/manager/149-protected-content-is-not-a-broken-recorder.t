#!/usr/bin/perl
# SM683: a protected file reported "No versions recorded ... version recording
# may be failing - run lazysite check".
#
# There is no fault. Protecting a folder MOVES its content into the private
# store (SM286), which is a SIBLING of the docroot - and the content
# repository's work tree IS the docroot. So a protected file is not in the
# repository at all: it has never been committed, and will not be however often
# it is edited. `lazysite check` reports the repository healthy, because it is.
#
# The message therefore sent the operator to diagnose something behaving exactly
# as built. That is the SM237 and SM672 class: a message naming the wrong cause
# is worse than none, because it is followed.
#
# Whether protected content SHOULD be versioned is an open decision recorded on
# the filing - history of a protected file is a second copy of protected content
# in a store with its own access rules. This only stops the page blaming the
# recorder either way.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

subtest 'the two facts that make this structural' => sub {
    my $priv = do {
        open my $fh, '<', "$root/lib/Lazysite/Private.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $priv =~ /sub private_root \{(.*?)\n\}/s;
    ok( defined $fn, 'private_root is present' ) or return;
    like( $fn, qr/dirname\(\s*\$docroot\s*\)/,
        'the private store is a SIBLING of the docroot, not inside it' )
        or diag( 'If it moved inside the docroot this filing changes shape - '
            . 'the content would then be in the repository work tree.' );

    my $git = do {
        open my $fh, '<', "$root/lib/Lazysite/Git.pm" or die $!;
        local $/;
        <$fh>;
    };
    unlike( $git, qr/Lazysite::Private|private_root/,
        'and the history module has no concept of the private store' )
        or diag( 'If Git.pm learns about it, protected content may be '
            . 'versionable and this message should change again.' );
};

subtest 'the page explains rather than blames' => sub {
    my $src = do {
        open my $fh, '<', "$root/starter/manager/files.md" or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /function renderHistory\(panel, entries, protectedRow\) \{(.*?)\n  \}/s;
    ok( defined $fn, 'renderHistory takes the protection flag' ) or return;

    like( $fn, qr/Protected content is not versioned/,
        'a protected file is told what is actually true' );
    like( $fn, qr/not a fault/,
        'and told plainly there is nothing to repair' )
        or diag( 'The old text sent them to lazysite check, which reports the '
            . 'repository healthy - because it is.' );

    # THE UNPROTECTED CASE MUST SURVIVE. That message is correct for a file
    # that IS in the repository and has no versions, which is a real fault.
    like( $fn, qr/lazysite check/,
        'an unprotected file still gets the diagnostic message' )
        or diag( 'Removing it would hide a genuine recording failure.' );
};

subtest 'protection is read from what the page rendered' => sub {
    my $src = do {
        open my $fh, '<', "$root/starter/manager/files.md" or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /function isProtectedPath\(path\) \{(.*?)\n\}/s;
    ok( defined $fn, 'isProtectedPath is present' ) or return;
    like( $fn, qr/currentFiles/,
        'it reads the list renderFiles rendered' );
    like( $fn, qr/protectionFor\(/,
        'and asks the same function the padlock asks' )
        or diag( 'A second copy of the rule would let the padlock and this '
            . 'message disagree about the same file.' );
    like( $fn, qr/return false;/,
        'an unknown row is treated as unprotected' )
        or diag( 'Claiming protection for a file that has none is wrong in the '
            . 'more misleading direction.' );
};

done_testing();
