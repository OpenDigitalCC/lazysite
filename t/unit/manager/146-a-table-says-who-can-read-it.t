#!/usr/bin/perl
# SM678: a data table's permissions were settable over the API and invisible in
# the manager.
#
# Lazysite::Data::Access keys a table's access as `lazysite/db/tables/<table>`,
# so acl-get and acl-set reach it with the same verbs that reach a page's, and
# may_read consults it through the shared _acl_allows. The mechanism was
# complete. The manager's only rights editor is rendered inside a FILE's
# expander, and a table is not a file, so the Data page had nothing.
#
# WHY IT MATTERS MORE THAN A MISSING PANEL: a table is where a site's personal
# data lives, so the object whose access an operator would most want to audit
# was the one the manager could not show. Silence reads as "there is nothing
# here" - and the site agent reported operators assuming a content scope
# confines a table, which it does not.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

subtest 'the page uses the SAME key the data layer enforces on' => sub {
    my $access = do {
        open my $fh, '<', "$root/lib/Lazysite/Data/Access.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($sub) = $access =~ /sub acl_key \{(.*?)\}/s;
    ok( defined $sub, 'the data layer names the key' ) or return;
    like( $sub, qr{lazysite/db/tables/}, 'as lazysite/db/tables/<table>' );

    my $page = do {
        open my $fh, '<', "$root/starter/manager/data.md" or die $!;
        local $/;
        <$fh>;
    };
    like( $page, qr{'lazysite/db/tables/' \+ table},
        'and the page builds the same key' )
        or diag( 'A page reading a DIFFERENT key would show a rule that is not '
            . 'the one being enforced - worse than showing nothing.' );
};

# SM687 moved this from a modal to an expander in the Files page's style, so
# the function that renders it changed name. The PROPERTY is unchanged and is
# what this asserts: three states told apart, and the key shown.
subtest 'no rule and an empty rule do not read the same' => sub {
    my $page = do {
        open my $fh, '<', "$root/starter/manager/data.md" or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $page =~ /(function renderTableAcl\(.*?\n\})/s;
    ok( defined $fn, 'the rule renderer is present' ) or return;

    like( $fn, qr/No rule/, 'a table with no rule says so' );
    like( $fn, qr/nobody named/,
        'and a rule naming nobody says THAT instead' )
        or diag( 'SM635 made the same argument for a protected file row: "no '
            . 'rule" and "a rule nobody has looked at" must not look alike.' );

    # THREE states, not two. The middle one is the one that misleads: a rule
    # that exists and names nobody looks like protection and is not.
    like( $fn, qr/has an owner and nobody named/,
        'and the middle state - an owner, nobody named - is told apart' );

    like( $fn, qr/Rule key:/, 'the panel labels where the key goes' );
    like( $fn, qr/escHtml\(key\)/,
        'and the key is written into it, so an operator can act on it' );
};

subtest 'it reads through the guarded parser' => sub {
    my $page = do {
        open my $fh, '<', "$root/starter/manager/data.md" or die $!;
        local $/;
        <$fh>;
    };
    # SM687: the fetch moved into loadTableAcl when the modal became an
    # expander. Matched on the FUNCTION THAT FETCHES rather than on a name that
    # has already changed once.
    my ($fn) = $page =~ /(function loadTableAcl\(.*?\n\})/s;
    like( $fn // '', qr/window\.mgJson/,
        'mgJson, not a bare r.json()' )
        or diag( 'SM461: any non-JSON body - a 500, a die, a proxy timeout - '
            . 'otherwise reads as malformed data and blames the rule.' );
};

done_testing();
