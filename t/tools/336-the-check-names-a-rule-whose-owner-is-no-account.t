#!/usr/bin/perl
# SM1401 (triage T-91): `lazysite check` names every stored rule whose owner is no
# account - removed, or never one - as a WARN naming the path, the owner and the
# remedy (the operator removes it from the manager's Permissions or re-owns it;
# a token cannot). A rule owned by an account that exists, or by `local`, is not
# named. It changes nothing, with or without --fix.
#
# With the check removed, no such WARN is printed (the first assertions fail).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd site_tempdir);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
my $doc    = site_tempdir();
my $cgi    = "$doc/../cgi-bin";
make_path( "$doc/lazysite/auth", "$doc/lazysite/cache", $cgi, "$doc/content/area" );
my $gname = getgrgid( ( stat $doc )[5] ) // ( stat $doc )[5];

sub put {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $c = <$f>; close $f; return $c }
sub users { run_cmd( $^X, "$root/tools/lazysite-users.pl", '--docroot', $doc, @_ ) }
sub check { run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi, '--group', $gname, @_ ) }

put( "$doc/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\n" );
users( 'setup-sysop', '--user', 'admin', 'pw-long-enough-123' );
users( 'add', 'boss', 'pw-long-enough-123' );

my $acls = "$doc/lazysite/auth/acls.json";
put( $acls, encode_json( {
    'content/area'        => { owner => 'boss',  read => ['@intranet'] },
    'content/area/orphan' => { owner => 'ghost', read => ['boss'] },
    'content/area/host'   => { owner => 'local', read => ['boss'] },
    'content/area/none'   => { read => ['boss'] },
} ) );
my $before = slurp($acls);

my $out  = check();
my @warn = grep { /which is no account/ } split /\n/, $out;
is( scalar @warn, 1, 'one stored rule is named' ) or diag $out;
like( $warn[0] // '', qr/\[ warn \]/,                     'as a WARN' );
like( $warn[0] // '', qr{the rule on 'content/area/orphan'}, 'naming its path' );
like( $warn[0] // '', qr/owned by 'ghost'/,                  'and its owner' );
like( $out, qr{remove it from the manager's Permissions \(Files page\) as the operator}, 'the remedy' );
like( $out, qr{lazysite acl set 'content/area/orphan' --owner ACCOUNT --actor local}, 'or re-owning it' );
like( $out, qr/A token cannot/, 'and that a token cannot' );
ok( !( grep { m{'content/area'|area/host|area/none} } @warn ),
    'a rule owned by an account, by local, or by nobody is not named' );

is( slurp($acls), $before, 'the check changed nothing' );
check('--fix');
is( slurp($acls), $before, 'and --fix changes nothing either' );

subtest 'after an account is removed, its rule is named too' => sub {
    users( 'remove', 'boss' );
    my @w = grep { /which is no account/ } split /\n/, check();
    is( scalar @w, 2, 'two now' ) or diag explain \@w;
    ok( ( grep { m{the rule on 'content/area' is owned by 'boss'} } @w ), 'the removed account\'s rule' );
};

done_testing;
