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

subtest 'no rule and an empty rule do not read the same' => sub {
    my $page = do {
        open my $fh, '<', "$root/starter/manager/data.md" or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $page =~ /function openTableAcl\(table\) \{(.*?)\n\}/s;
    ok( defined $fn, 'openTableAcl is present' ) or return;

    like( $fn, qr/No rule/, 'a table with no rule says so' );
    like( $fn, qr/nobody named/,
        'and a rule naming nobody says THAT instead' )
        or diag( 'SM635 made the same argument for a protected file row: "no '
            . 'rule" and "a rule nobody has looked at" must not look alike.' );
    # SM678: the key is still shown, but the panel that replaced the alert box
    # carries the label in its markup and fills it from here. Assert BOTH
    # halves - a label with nothing written into it, or a write with no label,
    # would each leave the operator without the key.
    like( $page, qr/Rule key:.*id="table-acl-key"/s,
        'the panel labels where the key goes' );
    like( $fn, qr/getElementById\('table-acl-key'\)\.textContent = key/,
        'and the key is written into it, so an operator can act on it' );
};

subtest 'it reads through the guarded parser' => sub {
    my $page = do {
        open my $fh, '<', "$root/starter/manager/data.md" or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $page =~ /function openTableAcl\(table\) \{(.*?)\n\}/s;
    like( $fn // '', qr/window\.mgJson/,
        'mgJson, not a bare r.json()' )
        or diag( 'SM461: any non-JSON body - a 500, a die, a proxy timeout - '
            . 'otherwise reads as malformed data and blames the rule.' );
};

done_testing();
