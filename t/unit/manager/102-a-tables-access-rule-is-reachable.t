#!/usr/bin/perl
# SM687: the rule that governs a table can actually be read and written.
#
# THE DEFECT THIS PINS. A table's access is an ACL keyed
# `lazysite/db/tables/<table>`, and the manager reached it through the generic
# acl-get / acl-set. Those verbs run `is_blocked_path`, which refuses
# EVERYTHING under `lazysite/` outside two carve-outs. So every call came back
# "Path is blocked": the rule was enforced and unreachable at the same time,
# because the enforcement side reads the store directly and never consults the
# blocklist.
#
# It shipped that way because the panel was tested at the SOURCE level - the
# right key, the right chips, the right markup - and never against the verb. A
# test that reads the page cannot see a refusal that happens in the API.
#
# The blocklist is correct and is asserted here, not worked around: a table
# ACL now has its own verb that knows it is addressing a TABLE rather than a
# path, and the generic file verbs must still refuse the key.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(gate_caps);

BEGIN {
    eval { require YAML::PP; 1 } or plan skip_all => 'YAML::PP not available';
}

use Lazysite::Manager::Common ();
use Lazysite::Data::Access    ();
use Lazysite::Manager::Data   ();
use Lazysite::Manager::Files  ();
use Lazysite::Auth::Acl       ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $c;

$Lazysite::Manager::Data::DOCROOT  = $docroot;
$Lazysite::Manager::Files::DOCROOT = $docroot;
$Lazysite::Auth::Acl::DOCROOT      = $docroot;

my $key = Lazysite::Data::Access::acl_key('paintings');

subtest 'the blocklist still refuses the key to the file editor' => sub {
    ok( Lazysite::Manager::Common::is_blocked_path($key),
        "$key is blocked for the generic file verbs" )
        or diag( 'That blocklist keeps the file editor out of the management '
            . 'tree. Writing a descriptor through it would bypass the data '
            . "plugin's own gates, including SM682's writable_by check." );
};

subtest 'the table verb reaches the same rule the enforcement side reads' => sub {
    my $set = Lazysite::Manager::Data::action_table_acl_set(
        'paintings', 'alice', read => ['bob'], write => ['bob'] );
    ok( $set->{ok}, 'a rule can be set' ) or diag( $set->{error} // '' );
    is( $set->{acl}{owner}, 'alice', 'the setter owns what they created' );

    my $get = Lazysite::Manager::Data::action_table_acl_get( 'paintings', 'alice' );
    ok( $get->{ok}, 'and read back' ) or diag( $get->{error} // '' );
    is_deeply( $get->{acl}{read}, ['bob'], 'with the names it was given' );

    # THE HALF THAT MATTERS: the surface that SETS the rule and the surface
    # that APPLIES it must key it identically, or the panel edits a rule
    # nothing enforces.
    my $store = Lazysite::Auth::Acl::load_acls();
    ok( exists $store->{ Lazysite::Auth::Acl::_acl_norm($key) },
        'the rule is stored under the key the data layer enforces on' )
        or diag( 'A rule written under a different key is a rule nobody '
            . 'applies, which is worse than no rule: it reads as protection.' );
};

subtest 'clearing removes the rule rather than emptying it' => sub {
    my $rm = Lazysite::Manager::Data::action_table_acl_remove( 'paintings', 'alice' );
    ok( $rm->{ok}, 'cleared' );
    is( $rm->{removed}, 1, 'and says it removed something' );
    my $get = Lazysite::Manager::Data::action_table_acl_get( 'paintings', 'alice' );
    ok( !$get->{acl}, 'the rule is gone, not stored empty' )
        or diag( 'An empty list reads as "open" on the read path, so storing '
            . 'one leaves a rule that means the opposite of what it looks like.' );
};

subtest 'a table name cannot be a path' => sub {
    for my $bad ( '../../etc/passwd', 'a/b', '', '.hidden' ) {
        my $r = Lazysite::Manager::Data::action_table_acl_get( $bad, 'alice' );
        ok( !$r->{ok}, "refused: '" . $bad . "'" );
    }
    my $ok = Lazysite::Manager::Data::action_table_acl_get( 'paintings', 'alice' );
    ok( $ok->{ok}, 'while an ordinary name is accepted' );
};

subtest 'the verbs are gated, and on the capability that owns access rules' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-manager-api.pl" or die $!;
        local $/;
        <$fh>;
    };
    # SM662 made the token gate declarative, so the `sub { ... }` this used to
    # match is not written anywhere. The cookie gate is still source text and
    # is still read as such; the token gate is read as data.
    my %caps = gate_caps($src);
    for my $a (qw(data-table-acl-get data-table-acl-set data-table-acl-remove)) {
        like( $src, qr/'\Q$a\E'\s*=>\s*'manage_content'/,
            "$a carries a cookie gate" );
        ok( $caps{$a} && $caps{$a}{manage_content},
            "$a carries a token gate, on the capability that owns access rules" );
    }
};

done_testing();
