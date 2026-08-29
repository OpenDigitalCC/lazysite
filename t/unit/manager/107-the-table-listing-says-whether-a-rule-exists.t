#!/usr/bin/perl
# SM678 remainder: the listing answers "is this table governed?"
#
# The rule was settable over the API and invisible in the manager until SM687
# gave it a panel - and a panel answers only once opened, so an operator with a
# dozen tables opened a dozen panels to learn which of them were governed.
#
# SM635 made this argument for a protected file row and it is the same one: say
# it where the operator is looking. A table holding personal data is exactly the
# object whose access somebody scans a list for.
#
# A BOOLEAN, not the rule. Who may read a table is the rule's own business,
# gated on manage_content; whether one EXISTS is what a listing needs, and it
# discloses nothing a manage_data holder could not learn by opening a panel
# they can already open.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require YAML::PP; 1 } or plan skip_all => 'YAML::PP not available';
}

use Lazysite::Manager::Data ();
use Lazysite::Auth::Acl     ();
use Lazysite::Data::Access  ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
make_path("$docroot/lazysite/auth");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $c;

for my $t (qw(governed open owned_only empty_rule)) {
    open my $f, '>', "$docroot/lazysite/db/tables/$t.yaml" or die $!;
    print {$f} "key: code\nfields:\n  code:\n    type: text\n";
    close $f;
}

$Lazysite::Manager::Data::DOCROOT = $docroot;
$Lazysite::Auth::Acl::DOCROOT     = $docroot;

sub key_for { Lazysite::Auth::Acl::_acl_norm( Lazysite::Data::Access::acl_key( $_[0] ) ) }

my $acls = Lazysite::Auth::Acl::load_acls();
$acls->{ key_for('governed') }   = { owner => 'alice', read => ['alice'] };
$acls->{ key_for('owned_only') } = { owner => 'alice' };
# An entry that names nobody and owns nothing: present in the store, governing
# nothing. SM635's middle state, and it must not read as a rule.
$acls->{ key_for('empty_rule') } = { read => [], write => [] };
Lazysite::Auth::Acl::save_acls($acls);

my %saw = map { $_->{table} => $_ }
    @{ ( Lazysite::Manager::Data::action_data_tables() || {} )->{tables} || [] };

subtest 'a governed table says so' => sub {
    ok( $saw{governed}, 'the table is listed' );
    ok( $saw{governed}{has_acl}, 'has_acl is true when a rule names somebody' );
    ok( $saw{owned_only}{has_acl},
        'and true when it only has an owner' )
        or diag( 'An owner IS a rule: it decides who may change the others.' );
};

subtest 'an ungoverned table says that instead' => sub {
    ok( defined $saw{open}{has_acl}, 'the field is always present' )
        or diag( 'Absent and false are different answers. A listing that omits '
            . 'the key on the common case makes the caller guess.' );
    ok( !$saw{open}{has_acl}, 'has_acl is false with no entry at all' );
    ok( !$saw{empty_rule}{has_acl},
        'and false for an entry naming nobody and owning nothing' )
        or diag( 'SM635: no rule and a rule governing nothing must not read '
            . 'the same. An empty entry protects nothing, so reporting it as a '
            . 'rule would tell an operator their table is governed when it is '
            . 'not - the direction that gets somebody hurt.' );
};

subtest 'the listing keys it the way the enforcement side does' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Data.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /(sub _table_has_acl \{.*?\n\})/s;
    ok( $fn, 'the helper was found' ) or return;
    like( $fn, qr/Lazysite::Data::Access::acl_key/,
        'it asks the same key function the data layer enforces on' )
        or diag( 'A listing keyed differently would report a rule that nothing '
            . 'applies, or miss one that is in force.' );
};

done_testing();
