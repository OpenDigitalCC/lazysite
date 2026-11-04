#!/usr/bin/perl
# SM1313 (ruling 61): `lazysite check` names every stored rule wider than the rule
# enclosing it, of the kind 0.16.3 refuses to write (SM1309): a WARN naming the
# path, the enclosing rule and whom it admits beyond it, telling the operator to
# review it. It changes nothing, with or without --fix. A carve-out the
# enclosing rule's owner or an operator owns is the kind 0.16.3 still allows,
# and is not named; nor is a rule that narrows.
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

put( "$doc/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\n" );
users( 'setup-sysop', '--user', 'admin', 'pw-long-enough-123' );
users( 'add', $_, 'pw-long-enough-123' ) for qw(boss memberai outsider);
users( 'group-add', 'memberai', 'intranet' );

my $acls = "$doc/lazysite/auth/acls.json";
put( $acls, encode_json( {
    'content/area'           => { owner => 'boss',     read => ['@intranet'] },
    'content/area/wide'      => { owner => 'memberai', read => [ '@intranet', 'outsider' ] },
    'content/area/bosscarve' => { owner => 'boss',     read => ['outsider'] },
    'content/area/opcarve'   => { owner => 'admin',    read => ['outsider'] },
    'content/area/narrow'    => { owner => 'memberai', read => ['memberai'] },
} ) );
my $before = slurp($acls);

my $out = run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi, '--group', $gname );
my @warn = grep { /a rule inside another that widens it/ } split /\n/, $out;

is( scalar @warn, 1, 'one stored rule is named' ) or diag $out;
like( $warn[0] // '', qr/\[ warn \]/,                        'as a WARN' );
like( $warn[0] // '', qr{the rule on 'content/area/wide'}, 'naming its path' );
like( $warn[0] // '', qr{the rule on 'content/area' does not}, 'and the enclosing rule' );
like( $warn[0] // '', qr/lets outsider read it/,           'and whom it admits beyond it' );
like( $out, qr{review it: .*lazysite acl remove 'content/area/wide'}, 'telling the operator to review it' );
ok( !( grep { m{bosscarve|opcarve|narrow} } @warn ),
    'a carve-out by the enclosing owner or an operator, and a narrowing rule, are not named' );

is( slurp($acls), $before, 'the check changed nothing' );
run_cmd( $^X, $script, '--docroot', $doc, '--cgibin', $cgi, '--group', $gname, '--fix' );
is( slurp($acls), $before, 'and --fix changes nothing either' );

done_testing;
